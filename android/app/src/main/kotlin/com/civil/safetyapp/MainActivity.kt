package com.civil.safetyapp

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {

    companion object {
        private const val LOCATION_CHANNEL = "com.civilsafety.app/locationStream"
        private const val SERVICE_CHANNEL = "com.civilsafety.app/native_service"
        private const val REQUEST_NOTIFICATION_PERMISSION = 1001
    }

    private var pendingNotificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // 🔹 플러터 플러그인들 등록
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        // 🔹 네이티브 → Flutter 로 위치 보내는 EventChannel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCATION_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {

            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                // LocationService.kt 에서 BackgroundChannel.sink?.success(...) 로 전송
                BackgroundChannel.sink = events
            }

            override fun onCancel(arguments: Any?) {
                BackgroundChannel.sink = null
            }
        })

        // 🔹 Flutter → 네이티브 ForegroundService / 배터리 최적화 제어
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                "startService" -> {
                    try {
                        val intent = Intent(this, LocationService::class.java)

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            this.startForegroundService(intent)
                        } else {
                            this.startService(intent)
                        }

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("START_SERVICE_ERROR", e.message, null)
                    }
                }

                "stopService" -> {
                    try {
                        val intent = Intent(this, LocationService::class.java)
                        this.stopService(intent)

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_SERVICE_ERROR", e.message, null)
                    }
                }

                "isIgnoringBatteryOptimizations" -> {
                    try {
                        result.success(isIgnoringBatteryOptimizations())
                    } catch (e: Exception) {
                        result.error("BATTERY_CHECK_ERROR", e.message, false)
                    }
                }

                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        requestIgnoreBatteryOptimizations()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BATTERY_REQUEST_ERROR", e.message, false)
                    }
                }

                "openBatteryOptimizationSettings" -> {
                    try {
                        openBatteryOptimizationSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BATTERY_SETTING_ERROR", e.message, false)
                    }
                }

                "isPreciseLocationGranted" -> {
                    try {
                        result.success(isPreciseLocationGranted())
                    } catch (e: Exception) {
                        result.error("PRECISE_LOCATION_CHECK_ERROR", e.message, false)
                    }
                }

                "isNotificationPermissionGranted" -> {
                    try {
                        result.success(isNotificationPermissionGranted())
                    } catch (e: Exception) {
                        result.error("NOTIFICATION_CHECK_ERROR", e.message, false)
                    }
                }

                "requestNotificationPermission" -> {
                    try {
                        requestNotificationPermission(result)
                    } catch (e: Exception) {
                        result.error("NOTIFICATION_REQUEST_ERROR", e.message, false)
                    }
                }

                "openNotificationSettings" -> {
                    try {
                        openNotificationSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("NOTIFICATION_SETTING_ERROR", e.message, false)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }

        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (e: Exception) {
            openBatteryOptimizationSettings()
        }
    }

    private fun openBatteryOptimizationSettings() {
        try {
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            startActivity(intent)
        } catch (e: Exception) {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        }
    }

    private fun isPreciseLocationGranted(): Boolean {
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun isNotificationPermissionGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }

        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            isNotificationPermissionGranted()
        ) {
            result.success(true)
            return
        }

        pendingNotificationPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATION_PERMISSION
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == REQUEST_NOTIFICATION_PERMISSION) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED

            pendingNotificationPermissionResult?.success(granted)
            pendingNotificationPermissionResult = null
        }
    }

    private fun openNotificationSettings() {
        try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            }
            startActivity(intent)
        } catch (e: Exception) {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        }
    }

}