package com.vativeapps.tencent_flutter_live

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.GLES20
import android.os.SystemClock
import android.util.Log
import com.nosmai.effect.api.NosmaiSDK
import com.tencent.trtc.TRTCCloud
import com.tencent.trtc.TRTCCloudDef
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * NOSMAI_TRTC_GPU_V12: isolated Tencent GPU transport + Nosmai texture trial.
 *
 * STAGE 1 ('pattern'): create GPU-only moving test frames in the current EGL context,
 * publish as TRTC Texture_2D. No Nosmai texture is sampled; callback stream slots are
 * always released. This verifies Tencent's GPU input and remote viewer independently.
 *
 * STAGE 2 ('nosmai'): copy Nosmai's GL_TEXTURE_2D processed output into app-owned
 * GL textures and submit to Tencent. No CPU readback, no I420/ByteArray path.
 * This experimental mode does NOT decode or wait on the opaque fifth callback value;
 * its synchronization contract is undocumented for TRTC. glFinish only synchronizes
 * work on the CURRENT EGL context, not unrelated contexts. DO NOT label production
 * safe or claim successful remote filtered video without actual device proof.
 *
 * Never interpret fifth argument as an EGLContext, GLsync, or fence solely by value.
 * Requires full app restart after stopping GPU trial (textures are GL-thread owned).
 */
internal class NosmaiTencentBridge(context: Context) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val stream = TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG
    private val active = AtomicBoolean(false)
    private val publishing = AtomicBoolean(false)
    private val registered = AtomicBoolean(false)
    private val frames = AtomicLong()
    private val sent = AtomicLong()
    private val dropped = AtomicLong()
    private val errors = AtomicLong()
    private val noEgl = AtomicLong()
    private val unsignalledFence = AtomicLong()
    private var lastSentNs: Long = 0L
    @Volatile private var lastError = ""
    @Volatile private var lastTexture = 0
    @Volatile private var lastWidth = 0
    @Volatile private var lastHeight = 0
    @Volatile private var lastFence = 0L
    @Volatile private var eglPresent = false

    // Diagnostic only: publishing mode is written by installer. Never enable
    // direct texture publishing in an ordinary build by accident.
    private val inputMode = "nosmai" // pattern or nosmai
    private val experimentalNoFenceWait = true
    private val fpsLimit = 10
    private val frameIntervalNs = 1_000_000_000L / fpsLimit
    private val lock = Any()
    private var bufferFbo = 0
    private var bufferWidth = 0
    private var bufferHeight = 0
    private var bufferOwnerContext: EGLContext? = null
    // A conservative GPU ring. Never recycle a texture immediately after a
    // TRTC submit; its SDK-side consumption callback is not exposed here.
    // This is a time heuristic, NOT definitive proof of consumer completion.
    private val ownedTextures = IntArray(24)
    private val ownedLastSubmittedNs = LongArray(24)
    private val minimumHoldNs = 1_000_000_000L
    private var ownedNext = 0
    private val nativeContextMatches = AtomicLong()
    private val nativeContextMismatches = AtomicLong()
    private val textureCopyErrors = AtomicLong()
    private val sourceVisible = AtomicLong()
    private val sourceInvisible = AtomicLong()
    private val fboIncomplete = AtomicLong()

    companion object {
        private const val TAG = "NosmaiTrtcGpuV12"
        // Native callbacks can use weak JNI refs. Keep the Java callback strongly
        // referenced for the lifetime of this test process, even after stop.
        private val retained = mutableListOf<NosmaiSDK.TextureFrameCallback>()
    }

    private val callback = object : NosmaiSDK.TextureFrameCallback {
        override fun onTextureFrame(
            textureId: Int, width: Int, height: Int, timestampNs: Long, fence: Long
        ) {
            onTexture(textureId, width, height, timestampNs, fence)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> try {
                arm()
                result.success(status())
            } catch (t: Throwable) {
                stopInternal()
                result.error("GPU_ARM_FAILED", message(t), null)
            }
            "publish" -> try {
                check(active.get()) { "GPU bridge is not armed" }
                // Called from Flutter ONLY AFTER onEnterRoom confirmation.
                publishing.set(false)
                NosmaiSDK.setTexturePoolEnabled(true)
                synchronized(retained) { retained.add(callback) }
                // Keep preview running. The camera is always owned by Nosmai.
                NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.DUAL_OUTPUT)
                NosmaiSDK.setTextureFrameCallback(callback)
                registered.set(true)
                publishing.set(true)
                lastError = "GPU V12 $inputMode: awaiting GPU frames"
                result.success(status())
            } catch (t: Throwable) {
                stopInternal()
                result.error("GPU_PUBLISH_FAILED", message(t), null)
            }
            "status" -> result.success(status())
            "stop" -> { stopInternal(); result.success(status()) }
            else -> result.notImplemented()
        }
    }

    private fun arm() {
        if (!active.compareAndSet(false, true)) return
        frames.set(0); sent.set(0); dropped.set(0); errors.set(0)
        noEgl.set(0); unsignalledFence.set(0)
        nativeContextMatches.set(0); nativeContextMismatches.set(0); textureCopyErrors.set(0)
        sourceVisible.set(0); sourceInvisible.set(0); fboIncomplete.set(0)
        lastError = "GPU bridge armed"; lastSentNs = 0L
        // Native TRTC singleton, UserSig, microphone and room join remain unchanged.
        TRTCCloud.sharedInstance(appContext).enableCustomVideoCapture(stream, true)
    }

    private fun onTexture(id: Int, w: Int, h: Int, timestampNs: Long, fence: Long) {
        val n = frames.incrementAndGet()
        lastTexture = id; lastWidth = w; lastHeight = h; lastFence = fence
        val context = EGL14.eglGetCurrentContext()
        eglPresent = context != null && context != EGL14.EGL_NO_CONTEXT
        // Read the native handle of the CURRENT EGL context without dereferencing
        // the opaque fifth callback argument. This is a value comparison only.
        val currentNativeHandle = if (eglPresent) {
            runCatching { context.nativeHandle }.getOrDefault(0L)
        } else 0L
        val fifthIsContext = currentNativeHandle != 0L && fence == currentNativeHandle
        if (n <= 5 || n % 60L == 0L) {
            Log.i(TAG, "GPU frame=$n id=$id ${w}x$h arg5=0x${java.lang.Long.toHexString(fence)} " +
                "eglContext=0x${java.lang.Long.toHexString(currentNativeHandle)} " +
                "arg5IsContext=$fifthIsContext egl=$eglPresent mode=$inputMode " +
                "sourceVisible=${sourceVisible.get()} sourceInvisible=${sourceInvisible.get()} " +
                "fboBad=${fboIncomplete.get()} sent=${sent.get()} dropped=${dropped.get()} err=$lastError")
        }
        try {
            if (!active.get() || !publishing.get()) { dropped.incrementAndGet(); return }
            if (id <= 0 || w <= 0 || h <= 0 || w.toLong() * h.toLong() > 1920L * 1080L) {
                report("Invalid texture metadata: id=$id ${w}x$h")
                dropped.incrementAndGet(); return
            }
            if (!eglPresent) {
                noEgl.incrementAndGet(); dropped.incrementAndGet()
                lastError = "No producer EGL context on Nosmai callback thread"
                return
            }
            // Callback's fifth Long is opaque. A mismatch with current EGLContext
            // is NOT proof that this texture cannot be sampled. This is diagnostic only.
            if (fifthIsContext) nativeContextMatches.incrementAndGet()
            else nativeContextMismatches.incrementAndGet()

            if (inputMode == "nosmai") {
                // Even GL texture visibility does not prove cross-context producer
                // synchronization. Use this ONLY as an explicitly opted-in trial.
                if (!experimentalNoFenceWait) {
                    dropped.incrementAndGet()
                    lastError = "Nosmai GPU trial requires explicit acknowledgement of unknown producer sync"
                    return
                }
                if (!GLES20.glIsTexture(id)) {
                    sourceInvisible.incrementAndGet(); dropped.incrementAndGet()
                    lastError = "Nosmai processed GL texture not visible on callback EGL context"
                    return
                }
                sourceVisible.incrementAndGet()
            }
            val now = SystemClock.elapsedRealtimeNanos()
            if (now - lastSentNs < frameIntervalNs) { dropped.incrementAndGet(); return }
            synchronized(lock) {
                if (!active.get() || !publishing.get()) { dropped.incrementAndGet(); return }
                if (bufferOwnerContext != null && bufferOwnerContext != context) {
                    dropped.incrementAndGet()
                    lastError = "EGL context changed; restart test process before reusing GPU textures"
                    return
                }
                val owned = makeGpuCopy(id, w, h, context, now, n)
                if (owned == 0) { dropped.incrementAndGet(); return }
                val frame = TRTCCloudDef.TRTCVideoFrame().apply {
                    width = w
                    height = h
                    timestamp = 0L // Tencent generates timestamps for this experiment.
                    pixelFormat = TRTCCloudDef.TRTC_VIDEO_PIXEL_FORMAT_Texture_2D
                    bufferType = TRTCCloudDef.TRTC_VIDEO_BUFFER_TYPE_TEXTURE
                    texture = TRTCCloudDef.TRTCTexture().apply {
                        textureId = owned
                        eglContext14 = context
                    }
                }
                TRTCCloud.sharedInstance(appContext).sendCustomVideoData(stream, frame)
                lastSentNs = now
                ownedLastSubmittedNs[(ownedNext - 1 + ownedTextures.size) % ownedTextures.size] = now
                sent.incrementAndGet()
                lastError = "GPU $inputMode submitted (not proof of decoded video)"
            }
        } catch (t: Throwable) {
            dropped.incrementAndGet(); report(message(t))
        } finally {
            // Nosmai owns source slot; app-owned GPU copy is separate.
            // Release *every* slot after either GPU copy, drop, or failure.
            try { NosmaiSDK.releaseStreamSlot(id) }
            catch (t: Throwable) { report("releaseStreamSlot: ${message(t)}") }
        }
    }

    /** All pixels remain on the GPU (no glReadPixels and no CPU I420). */
    private fun makeGpuCopy(sourceId: Int, w: Int, h: Int,
                            context: EGLContext, now: Long, frameNo: Long): Int {
        if (bufferWidth != 0 && (bufferWidth != w || bufferHeight != h)) {
            lastError = "Frame dimensions changed; restart GPU test process"
            return 0
        }
        val prevFramebuffer = IntArray(1)
        val prevTexture = IntArray(1)
        val prevClearColor = FloatArray(4)
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, prevFramebuffer, 0)
        GLES20.glGetIntegerv(GLES20.GL_TEXTURE_BINDING_2D, prevTexture, 0)
        GLES20.glGetFloatv(GLES20.GL_COLOR_CLEAR_VALUE, prevClearColor, 0)
        val scissorWasEnabled = GLES20.glIsEnabled(GLES20.GL_SCISSOR_TEST)
        try {
            if (bufferFbo == 0) {
                val ids = IntArray(1)
                GLES20.glGenFramebuffers(1, ids, 0)
                bufferFbo = ids[0]
                if (bufferFbo == 0) { lastError = "glGenFramebuffers failed"; return 0 }
                bufferOwnerContext = context
                bufferWidth = w; bufferHeight = h
                GLES20.glGenTextures(ownedTextures.size, ownedTextures, 0)
                for (textureId in ownedTextures) {
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                    GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h,
                        0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
                }
            }
            val nextIndex = ownedNext
            val lastUse = ownedLastSubmittedNs[nextIndex]
            if (lastUse != 0L && now - lastUse < minimumHoldNs) {
                lastError = "Tencent texture ring still in hold window; frame dropped"
                return 0
            }
            val owned = ownedTextures[nextIndex]
            if (owned <= 0) { lastError = "glGenTextures returned an invalid ID"; return 0 }

            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, bufferFbo)
            if (inputMode == "pattern") {
                // Independent GPU-only diagnostic. A moving colour pattern validates
                // Tencent Texture_2D ingest without Nosmai producer synchronization.
                GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER,
                    GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, owned, 0)
                val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
                if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
                    fboIncomplete.incrementAndGet()
                    lastError = "GPU pattern target framebuffer incomplete: $status"
                    return 0
                }
                if (scissorWasEnabled) GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
                val phase = (frameNo % 15L).toFloat() / 15f
                GLES20.glClearColor(phase, 0.35f, 1f - phase, 1f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            } else {
                // EXPERIMENTAL producer sampling: only a visible GL_TEXTURE_2D
                // with complete framebuffer is eligible. Fence type NOT verified.
                // We do not dereference/use the opaque fifth callback argument.
                GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER,
                    GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, sourceId, 0)
                val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
                if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
                    fboIncomplete.incrementAndGet()
                    lastError = "Nosmai source is not FBO-readable GL_TEXTURE_2D: $status"
                    return 0
                }
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, owned)
                GLES20.glCopyTexSubImage2D(GLES20.GL_TEXTURE_2D, 0,
                    0, 0, 0, 0, w, h)
            }
            // Wait for OUR commands to complete before the Nosmai slot is
            // released and before Tencent samples the app-owned output.
            // This is not an inter-context producer fence wait.
            GLES20.glFinish()
            val error = GLES20.glGetError()
            if (error != GLES20.GL_NO_ERROR) {
                textureCopyErrors.incrementAndGet()
                lastError = "GL error during $inputMode: 0x${Integer.toHexString(error)}"
                return 0
            }
            ownedNext = (ownedNext + 1) % ownedTextures.size
            return owned
        } finally {
            GLES20.glClearColor(prevClearColor[0], prevClearColor[1],
                prevClearColor[2], prevClearColor[3])
            if (scissorWasEnabled) GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, prevTexture[0])
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, prevFramebuffer[0])
        }
    }

    private fun stopInternal() {
        publishing.set(false)
        val wasActive = active.getAndSet(false)
        if (registered.getAndSet(false)) {
            // Do not hold the callback lock here; native SDK may await callbacks.
            try { NosmaiSDK.setTextureFrameCallback(null) }
            catch (t: Throwable) { Log.w(TAG, "unregister texture callback: ${message(t)}") }
            try { NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.PREVIEW_ONLY) }
            catch (t: Throwable) { Log.w(TAG, "restore preview: ${message(t)}") }
        }
        // Resources are owned by Nosmai's GL thread. We cannot safely delete
        // them on Flutter UI thread. This is a *single-session* QA experiment;
        // fully restart app process before reusing the GPU test mode.
        if (wasActive) {
            try { TRTCCloud.sharedInstance(appContext).enableCustomVideoCapture(stream, false) }
            catch (t: Throwable) { Log.w(TAG, "disable custom video: ${message(t)}") }
        }
    }

    fun release() = stopInternal()

    private fun status(): Map<String, Any> = mapOf(
        "active" to active.get(), "publishing" to publishing.get(),
        "frames" to frames.get(), "sent" to sent.get(),
        "dropped" to dropped.get(), "errors" to errors.get(),
        "lastError" to lastError,
        "mode" to "GPU_V12_${inputMode.uppercase()}_${fpsLimit}FPS",
        "textureId" to lastTexture, "textureWidth" to lastWidth, "textureHeight" to lastHeight,
        "callbackArg5" to lastFence, "egl" to eglPresent,
        "noEgl" to noEgl.get(),
        "contextMatches" to nativeContextMatches.get(), "contextMismatches" to nativeContextMismatches.get(),
        "textureCopyErrors" to textureCopyErrors.get(),
        "sourceVisible" to sourceVisible.get(), "sourceInvisible" to sourceInvisible.get(),
        "fboIncomplete" to fboIncomplete.get()
    )

    private fun report(error: String) {
        errors.incrementAndGet()
        lastError = error
        if (errors.get() < 5) Log.e(TAG, error)
    }

    private fun message(t: Throwable) = "${t.javaClass.simpleName}: ${t.message ?: "Native call failed"}"
}
