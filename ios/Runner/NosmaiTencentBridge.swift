import Flutter
import Foundation
import CoreVideo
import TXLiteAVSDK_Professional

/// Sends Nosmai's already-processed iOS CVPixelBuffers into the same TRTC
/// singleton used by the Flutter tencent_rtc_sdk plugin.
/// Nosmai continues to own camera capture and its Flutter preview.
final class NosmaiTencentBridge: NSObject {
  private static let channelName = "com.vativeapps.tencent_flutter_live/nosmai_tencent"

  private var channel: FlutterMethodChannel?
  private let sdkQueue = DispatchQueue(label: "com.vativeapps.nosmai.trtc.frames", qos: .userInteractive)
  private let lock = NSLock()
  private let inFlight = DispatchSemaphore(value: 1)
  private var cloud: TRTCCloud?
  private var active = false
  private var publishing = false
  private var frames = 0
  private var sent = 0
  private var dropped = 0
  private var errors = 0
  private var lastError = ""
  // Limit frames sent to TRTC without altering Nosmai capture or effects.
  private var previousCallbackTime = 0.0 // next eligible monotonic uptime
  private var pacedOut = 0
  private var fpsLimit = 15
  private var thermalLabel = "nominal"

  static func register(messenger: FlutterBinaryMessenger) -> NosmaiTencentBridge {
    let bridge = NosmaiTencentBridge()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    bridge.channel = channel
    channel.setMethodCallHandler { [weak bridge] call, reply in
      guard let bridge = bridge else {
        reply(FlutterError(code: "BRIDGE_RELEASED", message: "iOS bridge released", details: nil))
        return
      }
      bridge.handle(call: call, reply: reply)
    }
    return bridge
  }

  private func handle(call: FlutterMethodCall, reply: FlutterResult) {
    switch call.method {
    case "start":
      start()
      reply(snapshot())
    case "publish":
      guard getActive() else {
        reply(FlutterError(code: "NOT_ARMED", message: "Call start before publish", details: nil))
        return
      }
      publish()
      reply(snapshot())
    case "status":
      reply(snapshot())
    case "stop":
      stop()
      reply(nil)
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  private func start() {
    if getActive() { return }
    let instance = TRTCCloud.sharedInstance()
    // Must be armed BEFORE the Flutter LiveSession enters its room.
    instance.enableCustomVideoCapture(.big, enable: true)
    lock.lock()
    cloud = instance
    active = true
    publishing = false
    frames = 0
    sent = 0
    dropped = 0
    errors = 0
    lastError = "Waiting for Tencent room join"
    previousCallbackTime = 0
    pacedOut = 0
    fpsLimit = 15
    thermalLabel = "nominal"
    lock.unlock()
  }

  private func publish() {
    lock.lock()
    publishing = true
    lastError = "Waiting for processed Nosmai iOS frames"
    lock.unlock()

    // The Flutter NosmaiCameraPreview owns capture/processing. Use Core's
    // live fan-out rather than overriding NosmaiSDK's internal callback.
    NosmaiCore.shared().liveFrameStreamCallback = { [weak self] pixelBuffer, timestamp in
      self?.enqueue(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }
  }

  private func enqueue(pixelBuffer: CVPixelBuffer, timestamp: Double) {
    // This only reduces work *after* Nosmai produces the processed pixel buffer.
    // No extra pixel copies, resizing, or modifications to preview/capture.
    let thermal = ProcessInfo.processInfo.thermalState
    let maxFps: Int
    let state: String
    switch thermal {
    case .nominal:
      maxFps = 15; state = "nominal"
    case .fair:
      maxFps = 12; state = "fair"
    case .serious:
      maxFps = 8; state = "serious"
    case .critical:
      maxFps = 5; state = "critical"
    @unknown default:
      maxFps = 10; state = "unknown"
    }
    let now = ProcessInfo.processInfo.systemUptime
    let frameInterval = 1.0 / Double(maxFps)

    lock.lock()
    guard active && publishing else { lock.unlock(); return }
    frames += 1
    fpsLimit = maxFps
    thermalLabel = state
    // Pace with monotonic uptime, not an unknown-unit SDK timestamp.
    // Advance the nominal deadline to avoid unnecessary 20->10 FPS halving.
    if previousCallbackTime > 0 && now + 0.001 < previousCallbackTime {
      pacedOut += 1 // Intentional skip; NOT a packet/encoder drop.
      lock.unlock()
      return
    }
    // No queue buildup: if Tencent is busy, drop this frame, not a future one.
    guard inFlight.wait(timeout: .now()) == .success else {
      dropped += 1
      lock.unlock()
      return
    }
    if previousCallbackTime == 0 || now - previousCallbackTime > 0.20 {
      previousCallbackTime = now + frameInterval
    } else {
      previousCallbackTime += frameInterval
    }
    lock.unlock()

    // Swift ARC keeps the captured CVPixelBuffer alive until this work finishes.
    // Capture self strongly so the in-flight semaphore is always released.
    sdkQueue.async { [self, pixelBuffer] in
      defer { inFlight.signal() }
      submit(pixelBuffer: pixelBuffer)
    }
  }

  private func submit(pixelBuffer: CVPixelBuffer) {
    lock.lock()
    let canSend = active && publishing
    let instance = cloud
    lock.unlock()
    guard canSend, let instance = instance else { return }

    let pixelType = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let pixelFormat: TRTCVideoPixelFormat
    switch pixelType {
    case kCVPixelFormatType_32BGRA:
      pixelFormat = ._32BGRA
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      pixelFormat = ._NV12
    default:
      lock.lock()
      dropped += 1
      errors += 1
      lastError = String(format: "Unsupported CVPixelBuffer fourCC: 0x%08X", pixelType)
      lock.unlock()
      return
    }

    let frame = TRTCVideoFrame()
    frame.pixelFormat = pixelFormat
    frame.bufferType = .pixelBuffer
    frame.pixelBuffer = pixelBuffer
    frame.timestamp = TRTCCloud.generateCustomPTS()
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let formatHex = String(format: "0x%08X", pixelType)

    // This installed TRTC iOS Swift API returns Void, NOT a status code.
    // Invocation count is not proof of encoding, delivery or remote decoding.
    instance.sendCustomVideoData(.big, frame: frame)
    lock.lock()
    sent += 1
    let shouldLog = sent == 1 || sent % 90 == 0
    let callbacks = frames
    let attempts = sent
    let droppedCount = dropped
    let errorCount = errors
    let pacedCount = pacedOut
    let maxFps = fpsLimit
    let heat = thermalLabel
    lastError = "TRTC submit; thermal=\(heat) cap=\(maxFps)fps paced=\(pacedCount) \(formatHex) \(width)x\(height)"
    lock.unlock()

    if shouldLog {
      print("[NosmaiTencentIOS] submitCalled=\(attempts) callback=\(callbacks) paced=\(pacedCount) dropped=\(droppedCount) error=\(errorCount) thermal=\(heat) cap=\(maxFps)fps fourCC=\(formatHex) size=\(width)x\(height) result=void")
    }
  }

  private func stop() {
    lock.lock()
    let wasActive = active
    active = false
    publishing = false
    lock.unlock()

    // Remove producer before draining the consumer queue. Do not interrupt the
    // Nosmai camera preview; Flutter owns that lifecycle.
    NosmaiCore.shared().liveFrameStreamCallback = nil
    sdkQueue.sync {}
    if wasActive { cloud?.enableCustomVideoCapture(.big, enable: false) }
    lock.lock()
    cloud = nil
    lastError = "Stopped"
    lock.unlock()
  }

  private func getActive() -> Bool {
    lock.lock(); defer { lock.unlock() }
    return active
  }

  private func snapshot() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return [
      "active": active,
      "publishing": publishing,
      "mode": "ios-cvpixelbuffer",
      "frames": frames,
      "sent": sent,
      "dropped": dropped,
      "errors": errors,
      "paced": pacedOut,
      "thermalState": thermalLabel,
      "fpsLimit": fpsLimit,
      "lastError": lastError
    ]
  }
}
