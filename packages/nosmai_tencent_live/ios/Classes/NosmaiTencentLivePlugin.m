#import "NosmaiTencentLivePlugin.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <TXLiteAVSDK_Professional/TRTCCloud.h>
#import <nosmai_effects_sdk/NosmaiFlutterPlugin.h>

static NSString *const kChannelName = @"nosmai_tencent_live";
static const CFTimeInterval kPacingTolerance = 0.002;
static const CFTimeInterval kResyncAfter = 0.2;

/// Forwards Nosmai's processed CVPixelBuffers into Tencent custom video input.
///
/// Nosmai owns the camera and renders the Flutter preview; this class only
/// subscribes to Nosmai's documented live-stream output while a broadcast is
/// publishing. At most one frame is in flight, so a busy encoder drops the
/// current frame instead of building a queue.
@implementation NosmaiTencentLivePlugin {
  NSLock *_lock;
  dispatch_queue_t _sendQueue;
  dispatch_semaphore_t _inFlight;
  BOOL _armed;
  BOOL _publishing;
  BOOL _adaptToThermalState;
  NSInteger _maxFps;
  CFTimeInterval _nextDeadline;
  uint64_t _frames;
  uint64_t _sent;
  uint64_t _dropped;
  uint64_t _paced;
  uint64_t _errors;
  size_t _lastWidth;
  size_t _lastHeight;
  NSString *_lastError;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:kChannelName
                                  binaryMessenger:[registrar messenger]];
  NosmaiTencentLivePlugin *instance = [[NosmaiTencentLivePlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
  [registrar publish:instance];
}

- (instancetype)init {
  if ((self = [super init])) {
    _lock = [[NSLock alloc] init];
    _sendQueue = dispatch_queue_create("com.nosmai.tencent_live.send", DISPATCH_QUEUE_SERIAL);
    _inFlight = dispatch_semaphore_create(1);
    _maxFps = 30;
    _adaptToThermalState = YES;
    _lastError = @"";
  }
  return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [self stop];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  @try {
    if ([call.method isEqualToString:@"prepare"]) {
      // iOS needs no shared GPU context; Nosmai hands over CVPixelBuffers.
      result(@{@"sharedContext" : @NO, @"nosmaiAlreadyInitialized" : @NO});
    } else if ([call.method isEqualToString:@"requestPermissions"]) {
      [self requestPermissions:result];
    } else if ([call.method isEqualToString:@"arm"]) {
      [self armWithFps:[self fpsFrom:args] adaptToThermalState:[args[@"adaptToThermalState"] boolValue]];
      result([self stats]);
    } else if ([call.method isEqualToString:@"publish"]) {
      [self publish];
      result([self stats]);
    } else if ([call.method isEqualToString:@"setMaxFps"]) {
      [_lock lock];
      _maxFps = [self fpsFrom:args];
      [_lock unlock];
      result([self stats]);
    } else if ([call.method isEqualToString:@"stats"]) {
      result([self stats]);
    } else if ([call.method isEqualToString:@"stop"]) {
      // Draining waits for an in-flight submit; keep it off the main thread.
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self stop];
        dispatch_async(dispatch_get_main_queue(), ^{ result(nil); });
      });
    } else {
      result(FlutterMethodNotImplemented);
    }
  } @catch (NSException *exception) {
    result([FlutterError
        errorWithCode:[NSString stringWithFormat:@"NATIVE_%@_FAILED", call.method.uppercaseString]
              message:exception.reason
              details:nil]);
  }
}

- (NSInteger)fpsFrom:(NSDictionary *)args {
  NSNumber *fps = [args[@"fps"] isKindOfClass:[NSNumber class]] ? args[@"fps"] : @30;
  return MAX(1, MIN(60, fps.integerValue));
}

#pragma mark - Lifecycle

- (void)armWithFps:(NSInteger)fps adaptToThermalState:(BOOL)adapt {
  // A Dart hot restart can leave a previous session armed.
  if ([self isArmed]) [self stop];
  [_lock lock];
  _maxFps = fps;
  _adaptToThermalState = adapt;
  _nextDeadline = 0;
  _frames = _sent = _dropped = _paced = _errors = 0;
  _lastWidth = _lastHeight = 0;
  _lastError = @"";
  [_lock unlock];
  // Must be enabled before entering the room, or TRTC opens its own camera.
  [[TRTCCloud sharedInstance] enableCustomVideoCapture:TRTCVideoStreamTypeBig enable:YES];
  [_lock lock];
  _armed = YES;
  [_lock unlock];
}

- (void)publish {
  [_lock lock];
  if (!_armed) {
    [_lock unlock];
    [NSException raise:NSInternalInconsistencyException format:@"Call arm before publish"];
  }
  BOOL alreadyPublishing = _publishing;
  _publishing = YES;
  [_lock unlock];
  if (alreadyPublishing) return;

  __weak NosmaiTencentLivePlugin *weakSelf = self;
  [NosmaiFlutterPlugin setLiveStreamFrameCallback:^(CVPixelBufferRef pixelBuffer, double timestamp) {
    [weakSelf onFrame:pixelBuffer];
  }];
}

- (void)stop {
  [_lock lock];
  BOOL wasArmed = _armed;
  _publishing = NO;
  _armed = NO;
  [_lock unlock];
  // Remove the producer first, then drain the consumer queue.
  [NosmaiFlutterPlugin clearLiveStreamFrameCallback];
  dispatch_sync(_sendQueue, ^{});
  if (wasArmed) {
    [[TRTCCloud sharedInstance] enableCustomVideoCapture:TRTCVideoStreamTypeBig enable:NO];
  }
}

- (BOOL)isArmed {
  [_lock lock];
  BOOL armed = _armed;
  [_lock unlock];
  return armed;
}

#pragma mark - Frames

/// Called on Nosmai's processing thread for every processed frame.
- (void)onFrame:(CVPixelBufferRef)pixelBuffer {
  if (pixelBuffer == NULL) return;
  CFTimeInterval now = CACurrentMediaTime();
  NSInteger fps = [self effectiveFps];
  [_lock lock];
  _frames++;
  if (!_publishing) {
    [_lock unlock];
    return;
  }
  // Even spacing at the target rate; TRTC's encoder expects a steady cadence.
  if (_nextDeadline > 0 && now + kPacingTolerance < _nextDeadline) {
    _paced++;
    [_lock unlock];
    return;
  }
  if (dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_NOW) != 0) {
    _dropped++;
    [_lock unlock];
    return;
  }
  CFTimeInterval interval = 1.0 / (double)fps;
  _nextDeadline = (_nextDeadline == 0 || now - _nextDeadline > kResyncAfter)
                      ? now + interval
                      : _nextDeadline + interval;
  [_lock unlock];

  CVPixelBufferRetain(pixelBuffer);
  dispatch_async(_sendQueue, ^{
    [self submit:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
    dispatch_semaphore_signal(self->_inFlight);
  });
}

- (void)submit:(CVPixelBufferRef)pixelBuffer {
  [_lock lock];
  BOOL publishing = _publishing;
  [_lock unlock];
  if (!publishing) return;

  OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
  TRTCVideoPixelFormat format;
  switch (type) {
    case kCVPixelFormatType_32BGRA:
      format = TRTCVideoPixelFormat_32BGRA;
      break;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      format = TRTCVideoPixelFormat_NV12;
      break;
    default: {
      [_lock lock];
      _dropped++;
      _errors++;
      _lastError = [NSString stringWithFormat:@"Unsupported pixel format 0x%08X", (unsigned)type];
      [_lock unlock];
      return;
    }
  }

  TRTCVideoFrame *frame = [[TRTCVideoFrame alloc] init];
  frame.pixelFormat = format;
  frame.bufferType = TRTCVideoBufferType_PixelBuffer;
  frame.pixelBuffer = pixelBuffer;
  frame.timestamp = [TRTCCloud generateCustomPTS];
  [[TRTCCloud sharedInstance] sendCustomVideoData:TRTCVideoStreamTypeBig frame:frame];

  [_lock lock];
  _sent++;
  _lastWidth = CVPixelBufferGetWidth(pixelBuffer);
  _lastHeight = CVPixelBufferGetHeight(pixelBuffer);
  [_lock unlock];
}

- (NSInteger)effectiveFps {
  [_lock lock];
  NSInteger fps = _maxFps;
  BOOL adapt = _adaptToThermalState;
  [_lock unlock];
  if (!adapt) return fps;
  switch ([NSProcessInfo processInfo].thermalState) {
    case NSProcessInfoThermalStateCritical:
      return MIN(fps, 10);
    case NSProcessInfoThermalStateSerious:
      return MIN(fps, 15);
    default:
      return fps;
  }
}

- (NSDictionary *)stats {
  NSInteger fps = [self effectiveFps];
  [_lock lock];
  NSDictionary *stats = @{
    @"armed" : @(_armed),
    @"publishing" : @(_publishing),
    @"transport" : @"pixelBuffer",
    @"frames" : @(_frames),
    @"sent" : @(_sent),
    @"dropped" : @(_dropped),
    @"paced" : @(_paced),
    @"errors" : @(_errors),
    @"width" : @(_lastWidth),
    @"height" : @(_lastHeight),
    @"maxFps" : @(fps),
    @"lastError" : _lastError ?: @"",
  };
  [_lock unlock];
  return stats;
}

#pragma mark - Permissions

- (void)requestPermissions:(FlutterResult)result {
  [self requestAccessFor:AVMediaTypeVideo
              completion:^(BOOL camera) {
                [self requestAccessFor:AVMediaTypeAudio
                            completion:^(BOOL microphone) {
                              result(@{@"camera" : @(camera), @"microphone" : @(microphone)});
                            }];
              }];
}

- (void)requestAccessFor:(AVMediaType)type completion:(void (^)(BOOL))completion {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
  if (status != AVAuthorizationStatusNotDetermined) {
    completion(status == AVAuthorizationStatusAuthorized);
    return;
  }
  [AVCaptureDevice requestAccessForMediaType:type
                           completionHandler:^(BOOL granted) {
                             dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
                           }];
}

@end
