package com.vativeapps.tencent_flutter_live

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nosmaiTencentBridge: NosmaiTencentBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = NosmaiTencentBridge(applicationContext)
        nosmaiTencentBridge = bridge
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.vativeapps.tencent_flutter_live/nosmai_tencent")
            .setMethodCallHandler(bridge)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        nosmaiTencentBridge?.release()
        nosmaiTencentBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
