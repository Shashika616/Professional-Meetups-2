package com.profconn.professional_connections_platform

import android.content.ComponentName
import android.content.pm.PackageManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // The launcher entry the theme asks for, swapped in onStop: changing it
    // while the app is on screen can close the running task.
    private var pendingIcon: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // SecureScreen (lib/core/widgets/secure_screen.dart, #94). FLAG_SECURE
        // makes screenshots and recordings of the window come out black and
        // blanks its recents preview, for as long as a sensitive screen is up.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tiehere/secure_screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(null)
                    }
                    "disable" -> {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tiehere/app_icon")
            .setMethodCallHandler { call, result ->
                if (call.method == "set") {
                    pendingIcon = call.arguments as? String
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onStop() {
        super.onStop()
        val light = when (pendingIcon) {
            "light" -> true
            "dark" -> false
            else -> return
        }
        pendingIcon = null
        setLauncher(if (light) ".LauncherLight" else ".LauncherDark", true)
        setLauncher(if (light) ".LauncherDark" else ".LauncherLight", false)
    }

    private fun setLauncher(alias: String, enabled: Boolean) {
        val component = ComponentName(packageName, packageName + alias)
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        if (packageManager.getComponentEnabledSetting(component) != state) {
            packageManager.setComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
        }
    }
}
