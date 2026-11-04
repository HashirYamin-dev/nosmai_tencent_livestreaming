package com.nosmai.tencent_live;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.annotation.NonNull;
import com.nosmai.effect.api.NosmaiSDK;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Registered automatically by Flutter; host apps never reference this class. */
public final class NosmaiTencentLivePlugin
    implements FlutterPlugin,
        MethodChannel.MethodCallHandler,
        ActivityAware,
        PluginRegistry.RequestPermissionsResultListener {
  private static final String TAG = "NosmaiTencentLive";
  private static final String CHANNEL = "nosmai_tencent_live";
  private static final int PERMISSION_REQUEST_CODE = 0x4E54; // "NT"
  private static final String[] PERMISSIONS = {
    Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO
  };

  // Process-wide: Nosmai and TRTC are process singletons, and Nosmai keeps the share group for
  // the life of the process.
  private static final Object LOCK = new Object();
  private static SharedGlContext sharedGl;
  private static FrameForwarder forwarder;

  private final Handler main = new Handler(Looper.getMainLooper());
  private MethodChannel channel;
  private Context appContext;
  private ExecutorService commands = newCommandThread();
  private ActivityPluginBinding activity;
  private MethodChannel.Result pendingPermissions;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    appContext = binding.getApplicationContext();
    if (commands.isShutdown()) commands = newCommandThread();
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    commands.execute(
        () -> {
          FrameForwarder current = currentForwarder();
          if (current != null) current.stop();
        });
    commands.shutdown();
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    if ("requestPermissions".equals(call.method)) {
      requestPermissions(result);
      return;
    }
    // Native SDK work and drains run off the platform thread.
    commands.execute(() -> handle(call, result));
  }

  private void handle(MethodCall call, MethodChannel.Result result) {
    try {
      Object value;
      switch (call.method) {
        case "prepare":
          value = prepare();
          break;
        case "arm":
          {
            FrameForwarder target = requireForwarder();
            target.arm(intArgument(call, "fps", 30), boolArgument(call, "adaptToThermalState"));
            value = target.stats();
            break;
          }
        case "publish":
          {
            FrameForwarder target = requireForwarder();
            target.publish();
            value = target.stats();
            break;
          }
        case "setMaxFps":
          {
            FrameForwarder target = requireForwarder();
            target.setMaxFps(intArgument(call, "fps", 30));
            value = target.stats();
            break;
          }
        case "stats":
          {
            FrameForwarder current = currentForwarder();
            value = current != null ? current.stats() : Collections.emptyMap();
            break;
          }
        case "stop":
          {
            FrameForwarder current = currentForwarder();
            if (current != null) current.stop();
            value = null;
            break;
          }
        default:
          main.post(result::notImplemented);
          return;
      }
      main.post(() -> result.success(value));
    } catch (Throwable error) {
      Log.e(TAG, call.method + " failed", error);
      String message = error.getMessage() != null ? error.getMessage() : error.getClass().getSimpleName();
      main.post(
          () ->
              result.error(
                  "NATIVE_" + call.method.toUpperCase(Locale.ROOT) + "_FAILED", message, null));
    }
  }

  /**
   * Must run before NosmaiFlutter.initialize: Nosmai only joins a share group registered before
   * its render context exists.
   */
  private Map<String, Object> prepare() {
    boolean alreadyInitialized;
    try {
      alreadyInitialized = NosmaiSDK.isInitialized();
    } catch (Throwable t) {
      alreadyInitialized = false;
    }
    boolean shared;
    synchronized (LOCK) {
      if (sharedGl == null && !alreadyInitialized) {
        try {
          SharedGlContext context = SharedGlContext.create();
          try {
            System.loadLibrary("nosmai");
          } catch (Throwable ignored) {
            // NosmaiSDK loads it itself on most versions.
          }
          NosmaiSDK.setAgoraShareContext(context.nativeHandle());
          sharedGl = context;
        } catch (Throwable error) {
          Log.w(TAG, "Shared GL context unavailable; CPU frames will be used", error);
        }
      }
      if (forwarder == null) forwarder = new FrameForwarder(appContext, sharedGl);
      shared = sharedGl != null;
    }
    Map<String, Object> state = new HashMap<>();
    state.put("sharedContext", shared);
    state.put("nosmaiAlreadyInitialized", alreadyInitialized);
    return state;
  }

  /** Without prepare (Nosmai initialized directly) frames still flow, as I420. */
  private FrameForwarder requireForwarder() {
    synchronized (LOCK) {
      if (forwarder == null) forwarder = new FrameForwarder(appContext, sharedGl);
      return forwarder;
    }
  }

  private static FrameForwarder currentForwarder() {
    synchronized (LOCK) {
      return forwarder;
    }
  }

  private static int intArgument(MethodCall call, String key, int fallback) {
    Object value = call.argument(key);
    return value instanceof Number ? ((Number) value).intValue() : fallback;
  }

  private static boolean boolArgument(MethodCall call, String key) {
    Object value = call.argument(key);
    return !(value instanceof Boolean) || (Boolean) value;
  }

  // ---- Runtime permissions ------------------------------------------------------------------

  private void requestPermissions(MethodChannel.Result result) {
    List<String> needed = new ArrayList<>();
    for (String permission : PERMISSIONS) {
      if (!granted(permission)) needed.add(permission);
    }
    Activity host = activity != null ? activity.getActivity() : null;
    if (needed.isEmpty() || host == null) {
      result.success(permissionState());
      return;
    }
    if (pendingPermissions != null) {
      result.error(
          "PERMISSION_REQUEST_IN_PROGRESS", "A permission request is already showing", null);
      return;
    }
    pendingPermissions = result;
    host.requestPermissions(needed.toArray(new String[0]), PERMISSION_REQUEST_CODE);
  }

  @Override
  public boolean onRequestPermissionsResult(
      int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
    if (requestCode != PERMISSION_REQUEST_CODE) return false;
    if (pendingPermissions != null) pendingPermissions.success(permissionState());
    pendingPermissions = null;
    return true;
  }

  private Map<String, Boolean> permissionState() {
    Map<String, Boolean> state = new HashMap<>();
    state.put("camera", granted(Manifest.permission.CAMERA));
    state.put("microphone", granted(Manifest.permission.RECORD_AUDIO));
    return state;
  }

  private boolean granted(String permission) {
    return appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activity = binding;
    binding.addRequestPermissionsResultListener(this);
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    onAttachedToActivity(binding);
  }

  @Override
  public void onDetachedFromActivity() {
    if (activity != null) activity.removeRequestPermissionsResultListener(this);
    activity = null;
    if (pendingPermissions != null) pendingPermissions.success(permissionState());
    pendingPermissions = null;
  }

  private static ExecutorService newCommandThread() {
    return Executors.newSingleThreadExecutor(runnable -> new Thread(runnable, "nosmai-tencent-live"));
  }
}
