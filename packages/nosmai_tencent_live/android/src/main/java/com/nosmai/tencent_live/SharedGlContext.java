package com.nosmai.tencent_live;

import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLExt;
import android.opengl.EGLSurface;
import android.os.Handler;
import android.os.HandlerThread;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * A process-lifetime EGL context on its own thread.
 *
 * <p>Its native handle is registered with Nosmai before Nosmai initializes, so Nosmai's render
 * context joins this share group and its processed textures can be sampled here. The context is
 * never destroyed: Nosmai keeps a reference to the share group for as long as the process runs.
 */
final class SharedGlContext {
  final Handler handler;
  final EGLDisplay display;
  final EGLContext context;
  final int glesMajorVersion;
  @SuppressWarnings({"FieldCanBeLocal", "unused"}) // Keeps the pbuffer alive with the context.
  private final EGLSurface surface;

  private SharedGlContext(
      Handler handler, EGLDisplay display, EGLContext context, EGLSurface surface, int major) {
    this.handler = handler;
    this.display = display;
    this.context = context;
    this.surface = surface;
    this.glesMajorVersion = major;
  }

  long nativeHandle() {
    return context.getNativeHandle();
  }

  boolean post(Runnable task) {
    return handler.post(task);
  }

  /** Runs {@code task} on the GL thread and waits for it, up to {@code timeoutMs}. */
  boolean runAndWait(long timeoutMs, Runnable task) {
    CountDownLatch done = new CountDownLatch(1);
    boolean posted =
        handler.post(
            () -> {
              try {
                task.run();
              } finally {
                done.countDown();
              }
            });
    if (!posted) return false;
    try {
      return done.await(timeoutMs, TimeUnit.MILLISECONDS);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return false;
    }
  }

  static SharedGlContext create() throws Exception {
    HandlerThread thread = new HandlerThread("nosmai-trtc-gl");
    thread.start();
    Handler handler = new Handler(thread.getLooper());
    AtomicReference<SharedGlContext> created = new AtomicReference<>();
    AtomicReference<Throwable> failure = new AtomicReference<>();
    CountDownLatch ready = new CountDownLatch(1);
    handler.post(
        () -> {
          try {
            created.set(makeCurrentContext(handler));
          } catch (Throwable t) {
            failure.set(t);
          } finally {
            ready.countDown();
          }
        });
    if (!ready.await(5, TimeUnit.SECONDS)) {
      thread.quitSafely();
      throw new IllegalStateException("Timed out creating the streaming GL context");
    }
    if (failure.get() != null) {
      thread.quitSafely();
      throw new IllegalStateException("Could not create the streaming GL context", failure.get());
    }
    return created.get();
  }

  private static SharedGlContext makeCurrentContext(Handler handler) {
    EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
    if (display == EGL14.EGL_NO_DISPLAY) throw new IllegalStateException("No EGL display");
    int[] version = new int[2];
    if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
      throw new IllegalStateException("eglInitialize failed");
    }
    for (int major : new int[] {3, 2}) {
      EGLConfig config = chooseConfig(display, major);
      if (config == null) continue;
      EGLContext context =
          EGL14.eglCreateContext(
              display,
              config,
              EGL14.EGL_NO_CONTEXT,
              new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, major, EGL14.EGL_NONE},
              0);
      if (context == null || context == EGL14.EGL_NO_CONTEXT) continue;
      EGLSurface surface =
          EGL14.eglCreatePbufferSurface(
              display, config, new int[] {EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
      if (surface == null || surface == EGL14.EGL_NO_SURFACE) {
        EGL14.eglDestroyContext(display, context);
        continue;
      }
      if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
        EGL14.eglDestroySurface(display, surface);
        EGL14.eglDestroyContext(display, context);
        continue;
      }
      return new SharedGlContext(handler, display, context, surface, major);
    }
    throw new IllegalStateException(
        "Could not create an OpenGL ES context: 0x" + Integer.toHexString(EGL14.eglGetError()));
  }

  private static EGLConfig chooseConfig(EGLDisplay display, int major) {
    int renderable = major >= 3 ? EGLExt.EGL_OPENGL_ES3_BIT_KHR : EGL14.EGL_OPENGL_ES2_BIT;
    int[] attributes = {
      EGL14.EGL_RED_SIZE, 8,
      EGL14.EGL_GREEN_SIZE, 8,
      EGL14.EGL_BLUE_SIZE, 8,
      EGL14.EGL_ALPHA_SIZE, 8,
      EGL14.EGL_RENDERABLE_TYPE, renderable,
      EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
      EGL14.EGL_NONE
    };
    EGLConfig[] configs = new EGLConfig[1];
    int[] count = new int[1];
    if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0)) return null;
    return count[0] > 0 ? configs[0] : null;
  }
}
