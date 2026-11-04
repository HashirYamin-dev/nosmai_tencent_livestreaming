package com.nosmai.tencent_live;

import android.content.Context;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.os.Build;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;
import com.nosmai.effect.api.NosmaiSDK;
import com.tencent.trtc.TRTCCloud;
import com.tencent.trtc.TRTCCloudDef;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Moves Nosmai's processed camera frames into Tencent's custom video input.
 *
 * <p>TEXTURE: Nosmai shares textures with {@link SharedGlContext}. Each frame follows Nosmai's
 * documented consumer protocol (waitStreamFrame, GPU copy, completeStreamFrame) and the app-owned
 * copy is handed to TRTC as a 2D texture. Pixels never leave the GPU.
 *
 * <p>I420: used when the share context could not be registered before Nosmai initialized, or when
 * shared textures turn out to be unreadable. Nosmai's frame callback delivers pooled I420 bytes,
 * which TRTC copies synchronously.
 */
final class FrameForwarder {
  enum Transport {
    TEXTURE,
    I420
  }

  private static final class Slot {
    final int texture;
    final int width;
    final int height;

    Slot(int texture, int width, int height) {
      this.texture = texture;
      this.width = width;
      this.height = height;
    }
  }

  private static final class TextureUnavailable extends Exception {
    TextureUnavailable(String message) {
      super(message);
    }
  }

  private static final String TAG = "NosmaiTencentLive";
  private static final int STREAM = TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG;
  private static final int DEFAULT_FPS = 30;
  private static final int SLOT_COUNT = 4;
  private static final int MAX_DIMENSION = 4096;
  private static final int NOSMAI_FORMAT_I420 = 1;
  private static final int TEXTURE_FAILURES_BEFORE_FALLBACK = 3;
  private static final long DRAIN_TIMEOUT_MS = 2_000L;
  private static final long GPU_WAIT_NS = 50_000_000L;
  private static final long PACING_TOLERANCE_NS = 2_000_000L;
  private static final long RESYNC_AFTER_NS = 200_000_000L;

  private final Context appContext;
  private final SharedGlContext gl;

  private final AtomicBoolean armed = new AtomicBoolean(false);
  private final AtomicBoolean publishing = new AtomicBoolean(false);
  private final AtomicBoolean copyPending = new AtomicBoolean(false);

  private volatile Transport transport = Transport.I420;
  private volatile int maxFps = DEFAULT_FPS;
  private volatile int thermalCapFps = Integer.MAX_VALUE;
  private volatile String lastError = "";
  private volatile int lastWidth;
  private volatile int lastHeight;
  private long nextDeadlineNs; // Nosmai render thread only.

  private final AtomicLong frames = new AtomicLong();
  private final AtomicLong sent = new AtomicLong();
  private final AtomicLong dropped = new AtomicLong();
  private final AtomicLong paced = new AtomicLong();
  private final AtomicLong errors = new AtomicLong();

  // GL thread only.
  private final Slot[] slots = new Slot[SLOT_COUNT];
  private int nextSlot;
  private int readFramebuffer;
  private int textureFailures;

  // Nosmai's JNI layer may hold weak references; these fields keep both callbacks strongly
  // reachable for the forwarder's (process) lifetime.
  private final NosmaiSDK.TextureFrameCallback textureCallback =
      (texture, width, height, timestampNs, fence) -> onTexture(texture, width, height);
  private final NosmaiSDK.FrameCallback frameCallback = this::onPixels;
  private final Object thermalListener;

  FrameForwarder(Context appContext, SharedGlContext gl) {
    this.appContext = appContext;
    this.gl = gl;
    this.thermalListener =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            ? (PowerManager.OnThermalStatusChangedListener) status -> thermalCapFps = capFor(status)
            : null;
  }

  void arm(int fps, boolean adaptToThermalState) {
    // A Dart hot restart can leave a previous session armed.
    if (armed.get() || publishing.get()) stop();
    maxFps = clampFps(fps);
    nextDeadlineNs = 0L;
    thermalCapFps = Integer.MAX_VALUE;
    for (AtomicLong counter : new AtomicLong[] {frames, sent, dropped, paced, errors}) {
      counter.set(0);
    }
    lastWidth = 0;
    lastHeight = 0;
    transport = canShareTextures() ? Transport.TEXTURE : Transport.I420;
    lastError =
        transport == Transport.TEXTURE ? "" : "Shared GPU context unavailable; using CPU frames";
    if (adaptToThermalState) registerThermalListener();
    trtc().enableCustomVideoCapture(STREAM, true);
    armed.set(true);
  }

  void publish() {
    if (!armed.get()) throw new IllegalStateException("Call arm before publish");
    if (!publishing.compareAndSet(false, true)) return;
    NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.DUAL_OUTPUT);
    installCallback(transport);
  }

  void setMaxFps(int fps) {
    maxFps = clampFps(fps);
  }

  void stop() {
    publishing.set(false);
    try {
      NosmaiSDK.setTextureFrameCallback(null);
      NosmaiSDK.setFrameCallback(null);
      NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.PREVIEW_ONLY);
    } catch (Throwable t) {
      Log.w(TAG, "Removing Nosmai callbacks failed", t);
    }
    // Queued copies observe publishing=false and return their Nosmai slot.
    if (gl != null) gl.runAndWait(DRAIN_TIMEOUT_MS, () -> {});
    unregisterThermalListener();
    if (armed.getAndSet(false)) {
      try {
        trtc().enableCustomVideoCapture(STREAM, false);
      } catch (Throwable t) {
        Log.w(TAG, "Disabling custom capture failed", t);
      }
    }
  }

  Map<String, Object> stats() {
    Map<String, Object> stats = new HashMap<>();
    stats.put("armed", armed.get());
    stats.put("publishing", publishing.get());
    stats.put("transport", transport.name().toLowerCase(Locale.ROOT));
    stats.put("frames", frames.get());
    stats.put("sent", sent.get());
    stats.put("dropped", dropped.get());
    stats.put("paced", paced.get());
    stats.put("errors", errors.get());
    stats.put("width", lastWidth);
    stats.put("height", lastHeight);
    stats.put("maxFps", effectiveFps());
    stats.put("lastError", lastError);
    return stats;
  }

  private boolean canShareTextures() {
    if (gl == null) return false;
    try {
      return NosmaiSDK.isAgoraShareContext(gl.nativeHandle());
    } catch (Throwable t) {
      return false;
    }
  }

  private void installCallback(Transport selected) {
    if (selected == Transport.TEXTURE) {
      NosmaiSDK.setFrameCallback(null);
      NosmaiSDK.setTextureFrameCallback(textureCallback);
    } else {
      NosmaiSDK.setTextureFrameCallback(null);
      NosmaiSDK.setFrameCallback(frameCallback);
    }
  }

  // ---- Texture transport ----------------------------------------------------------------------

  private void onTexture(int texture, int width, int height) {
    frames.incrementAndGet();
    SharedGlContext context = gl;
    if (!publishing.get() || transport != Transport.TEXTURE || context == null) {
      NosmaiSDK.releaseStreamSlot(texture);
      return;
    }
    if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
      dropped.incrementAndGet();
      NosmaiSDK.releaseStreamSlot(texture);
      return;
    }
    if (!admitFrame()) {
      paced.incrementAndGet();
      NosmaiSDK.releaseStreamSlot(texture);
      return;
    }
    // One copy in flight: a slow GPU drops frames instead of queueing them.
    if (!copyPending.compareAndSet(false, true)) {
      dropped.incrementAndGet();
      NosmaiSDK.releaseStreamSlot(texture);
      return;
    }
    if (!context.post(() -> copyAndSend(context, texture, width, height))) {
      copyPending.set(false);
      dropped.incrementAndGet();
      NosmaiSDK.releaseStreamSlot(texture);
    }
  }

  private void copyAndSend(SharedGlContext context, int texture, int width, int height) {
    boolean returned = false;
    try {
      if (!publishing.get()) return;
      Slot slot = acquireSlot(width, height);
      if (!NosmaiSDK.waitStreamFrame(texture)) {
        dropped.incrementAndGet();
        return;
      }
      try {
        copyTexture(texture, slot);
      } finally {
        // Records a fence after our reads; Nosmai reuses the texture after it.
        NosmaiSDK.completeStreamFrame(texture);
        returned = true;
      }
      // TRTC samples the copy from its own shared context, so the copy must have finished on
      // the GPU before the handoff.
      if (!awaitGpu(context)) {
        dropped.incrementAndGet();
        return;
      }
      if (!publishing.get()) return;
      TRTCCloudDef.TRTCTexture handoff = new TRTCCloudDef.TRTCTexture();
      handoff.textureId = slot.texture;
      handoff.eglContext14 = context.context;
      TRTCCloudDef.TRTCVideoFrame frame = new TRTCCloudDef.TRTCVideoFrame();
      frame.pixelFormat = TRTCCloudDef.TRTC_VIDEO_PIXEL_FORMAT_Texture_2D;
      frame.bufferType = TRTCCloudDef.TRTC_VIDEO_BUFFER_TYPE_TEXTURE;
      frame.width = width;
      frame.height = height;
      frame.timestamp = 0L; // TRTC stamps the frame on arrival.
      frame.texture = handoff;
      trtc().sendCustomVideoData(STREAM, frame);
      sent.incrementAndGet();
      lastWidth = width;
      lastHeight = height;
      textureFailures = 0;
    } catch (TextureUnavailable error) {
      dropped.incrementAndGet();
      onTextureFailure(error.getMessage());
    } catch (Throwable error) {
      dropped.incrementAndGet();
      report("Texture frame failed: " + describe(error));
    } finally {
      if (!returned) NosmaiSDK.releaseStreamSlot(texture);
      copyPending.set(false);
    }
  }

  private Slot acquireSlot(int width, int height) {
    int index = nextSlot;
    nextSlot = (nextSlot + 1) % SLOT_COUNT;
    Slot existing = slots[index];
    if (existing != null && existing.width == width && existing.height == height) return existing;
    if (existing != null) GLES20.glDeleteTextures(1, new int[] {existing.texture}, 0);
    int[] ids = new int[1];
    GLES20.glGenTextures(1, ids, 0);
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0]);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
    GLES20.glTexImage2D(
        GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0, GLES20.GL_RGBA,
        GLES20.GL_UNSIGNED_BYTE, null);
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
    Slot slot = new Slot(ids[0], width, height);
    slots[index] = slot;
    return slot;
  }

  private void copyTexture(int source, Slot slot) throws TextureUnavailable {
    if (!GLES20.glIsTexture(source)) {
      throw new TextureUnavailable("Nosmai texture is not visible in the shared GL context");
    }
    if (readFramebuffer == 0) {
      int[] ids = new int[1];
      GLES20.glGenFramebuffers(1, ids, 0);
      readFramebuffer = ids[0];
    }
    try {
      GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, readFramebuffer);
      GLES20.glFramebufferTexture2D(
          GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, source, 0);
      int status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER);
      if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
        throw new TextureUnavailable(
            "Nosmai texture is not readable (framebuffer 0x" + Integer.toHexString(status) + ")");
      }
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, slot.texture);
      GLES20.glCopyTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, 0, 0, slot.width, slot.height);
    } finally {
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
      GLES20.glFramebufferTexture2D(
          GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, 0, 0);
      GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
    }
    int error = GLES20.glGetError();
    if (error != GLES20.GL_NO_ERROR) {
      throw new IllegalStateException("GL error 0x" + Integer.toHexString(error));
    }
  }

  private static boolean awaitGpu(SharedGlContext context) {
    if (context.glesMajorVersion < 3) {
      GLES20.glFinish();
      return true;
    }
    long fence = GLES30.glFenceSync(GLES30.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (fence == 0L) {
      GLES20.glFinish();
      return true;
    }
    int status = GLES30.glClientWaitSync(fence, GLES30.GL_SYNC_FLUSH_COMMANDS_BIT, GPU_WAIT_NS);
    GLES30.glDeleteSync(fence);
    return status == GLES30.GL_ALREADY_SIGNALED || status == GLES30.GL_CONDITION_SATISFIED;
  }

  private void onTextureFailure(String message) {
    textureFailures++;
    if (textureFailures < TEXTURE_FAILURES_BEFORE_FALLBACK) return;
    // Sharing did not take effect on this device; continue with CPU frames.
    Log.w(TAG, message + "; switching to I420 frames");
    lastError = message + "; switched to CPU frames";
    transport = Transport.I420;
    if (publishing.get()) installCallback(Transport.I420);
  }

  // ---- I420 transport -------------------------------------------------------------------------

  private void onPixels(NosmaiSDK.FrameData frame) {
    frames.incrementAndGet();
    if (frame == null || !publishing.get() || transport != Transport.I420) return;
    byte[] data = frame.pixelBuffer;
    int width = frame.width;
    int height = frame.height;
    if (data == null || width <= 0 || height <= 0 || width > MAX_DIMENSION
        || height > MAX_DIMENSION) {
      dropped.incrementAndGet();
      return;
    }
    if (frame.format != NOSMAI_FORMAT_I420) {
      dropped.incrementAndGet();
      report("Unsupported Nosmai frame format " + frame.format);
      return;
    }
    if (data.length < width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)) {
      dropped.incrementAndGet();
      return;
    }
    if (!admitFrame()) {
      paced.incrementAndGet();
      return;
    }
    try {
      // Nosmai pools this array; TRTC copies it before returning.
      TRTCCloudDef.TRTCVideoFrame out = new TRTCCloudDef.TRTCVideoFrame();
      out.pixelFormat = TRTCCloudDef.TRTC_VIDEO_PIXEL_FORMAT_I420;
      out.bufferType = TRTCCloudDef.TRTC_VIDEO_BUFFER_TYPE_BYTE_ARRAY;
      out.data = data;
      out.width = width;
      out.height = height;
      out.timestamp = 0L;
      trtc().sendCustomVideoData(STREAM, out);
      sent.incrementAndGet();
      lastWidth = width;
      lastHeight = height;
    } catch (Throwable error) {
      dropped.incrementAndGet();
      report("I420 frame failed: " + describe(error));
    }
  }

  // ---- Shared helpers -------------------------------------------------------------------------

  /** Even spacing at the target rate; TRTC's encoder expects a steady cadence. */
  private boolean admitFrame() {
    long now = SystemClock.elapsedRealtimeNanos();
    long interval = 1_000_000_000L / effectiveFps();
    long deadline = nextDeadlineNs;
    if (deadline != 0L && now + PACING_TOLERANCE_NS < deadline) return false;
    nextDeadlineNs =
        deadline == 0L || now - deadline > RESYNC_AFTER_NS ? now + interval : deadline + interval;
    return true;
  }

  private int effectiveFps() {
    return Math.min(maxFps, thermalCapFps);
  }

  private static int clampFps(int fps) {
    return Math.max(1, Math.min(60, fps));
  }

  private void registerThermalListener() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return;
    PowerManager power = appContext.getSystemService(PowerManager.class);
    if (power == null) return;
    try {
      thermalCapFps = capFor(power.getCurrentThermalStatus());
      power.addThermalStatusListener((PowerManager.OnThermalStatusChangedListener) thermalListener);
    } catch (Throwable t) {
      Log.w(TAG, "Thermal status unavailable", t);
    }
  }

  private void unregisterThermalListener() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return;
    PowerManager power = appContext.getSystemService(PowerManager.class);
    if (power != null) {
      try {
        power.removeThermalStatusListener(
            (PowerManager.OnThermalStatusChangedListener) thermalListener);
      } catch (Throwable ignored) {
        // Never registered.
      }
    }
    thermalCapFps = Integer.MAX_VALUE;
  }

  private static int capFor(int status) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return Integer.MAX_VALUE;
    if (status >= PowerManager.THERMAL_STATUS_CRITICAL) return 10;
    if (status >= PowerManager.THERMAL_STATUS_SEVERE) return 15;
    return Integer.MAX_VALUE;
  }

  private TRTCCloud trtc() {
    return TRTCCloud.sharedInstance(appContext);
  }

  private void report(String message) {
    lastError = message;
    if (errors.incrementAndGet() <= 5) Log.e(TAG, message);
  }

  private static String describe(Throwable error) {
    return error.getMessage() != null ? error.getMessage() : error.getClass().getSimpleName();
  }
}
