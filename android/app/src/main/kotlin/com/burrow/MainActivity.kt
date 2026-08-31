package com.burrow

import com.burrow.bridge.PtyBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // PtyBridge 不是一个 pub 插件，所以不会被自动注册，必须手动加。
        flutterEngine.plugins.add(PtyBridge())

        // Dart 侧要知道 APK 解出来的 .so 放在哪，才能把 libburrow-launch.so
        // 复制成 $PREFIX/libexec/burrow-launch（见 BootstrapInstaller）。
        // 走 channel 而不是环境变量：Kotlin 改不了已启动的 Dart VM 的进程环境。
        PtyBridge.nativeLibraryDir = applicationInfo.nativeLibraryDir
    }
}
