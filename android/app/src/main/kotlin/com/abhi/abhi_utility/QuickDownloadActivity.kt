package com.abhi.abhi_utility

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small see-through "quick download" panel shown over the app the user is in
 * (from the floating ⬇ button or "Share → Abhi Utility"), so they can pick a
 * quality and download without leaving that app. Runs the Dart entry point
 * `quickDownloadMain` (lib/main.dart).
 */
class QuickDownloadActivity : FlutterActivity() {

    override fun getDartEntrypointFunctionName(): String = "quickDownloadMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "abhi_utility/quick").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // Link shared to us ("Share → Abhi Utility"), or null (⬇ button: read the clipboard).
                    "sharedText" -> result.success(
                        if (intent?.action == Intent.ACTION_SEND) intent.getStringExtra(Intent.EXTRA_TEXT) else null
                    )
                    "start" -> result.success(
                        Downloads.start(
                            this,
                            call.argument<String>("url")!!,
                            call.argument<String>("fileName")!!,
                            call.argument<String>("mimeType"),
                            call.argument<String>("referer"),
                            call.argument<String>("userAgent"),
                        )
                    )
                    // Hand over to the full app (e.g. the site needs a login → built-in browser).
                    "openApp" -> {
                        val link = call.argument<String>("text")
                        startActivity(
                            Intent(this, MainActivity::class.java)
                                .setAction(Intent.ACTION_SEND)
                                .setType("text/plain")
                                .putExtra(Intent.EXTRA_TEXT, link ?: "")
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        )
                        result.success(null)
                        finish()
                    }
                    "close" -> {
                        result.success(null)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("QUICK_ERROR", e.message, null)
            }
        }
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, android.R.anim.fade_out)
    }
}
