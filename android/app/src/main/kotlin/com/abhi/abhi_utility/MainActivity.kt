package com.abhi.abhi_utility

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the Flutter UI to native code:
 *  - "abhi_utility/control": start/stop the shake service, toggle the torch
 *  - "abhi_utility/torch":   stream of torch on/off state
 */
class MainActivity : FlutterFragmentActivity() {

    private lateinit var cameraManager: CameraManager
    private var cameraId: String? = null
    private var torchOn = false
    private var torchCallback: CameraManager.TorchCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        cameraId = findFlashCamera(cameraManager)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "abhi_utility/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasTorch" -> result.success(cameraId != null)
                "isServiceRunning" -> result.success(ShakeService.isRunning)
                "startService" -> {
                    requestNotificationPermission()
                    val intent = Intent(this, ShakeService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                    else startService(intent)
                    result.success(true)
                }
                "stopService" -> {
                    stopService(Intent(this, ShakeService::class.java))
                    result.success(false)
                }
                "toggleTorch" -> {
                    val id = cameraId
                    if (id == null) {
                        result.error("NO_TORCH", "No flashlight on this device", null)
                    } else try {
                        cameraManager.setTorchMode(id, !torchOn)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("TORCH_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "abhi_utility/reels").setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(isReelServiceEnabled())
                "openSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "stats" -> {
                    val days = call.argument<Int>("days") ?: 7
                    result.success(ReelStats.lastDays(this, days))
                }
                "timeStats" -> {
                    val days = call.argument<Int>("days") ?: 7
                    result.success(ReelStats.lastDaysTime(this, days))
                }
                "isOverlayEnabled" -> result.success(ReelStats.isOverlayEnabled(this))
                "setOverlayEnabled" -> {
                    ReelStats.setOverlayEnabled(this, call.argument<Boolean>("enabled") ?: true)
                    result.success(null)
                }
                "appNames" -> result.success(ReelApps.NAMES)
                "initialTab" -> result.success(intent?.getStringExtra("tab"))
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "abhi_utility/applock").setMethodCallHandler { call, result ->
            when (call.method) {
                // Installed apps with icons; built off the main thread (can take a moment).
                "apps" -> Thread {
                    val apps = AppLock.launchableApps(this).map { a ->
                        mapOf(
                            "pkg" to a.pkg,
                            "label" to a.label,
                            "category" to a.category,
                            "system" to a.system,
                            "icon" to AppLock.appIcon(this, a.pkg),
                        )
                    }
                    runOnUiThread { result.success(apps) }
                }.start()
                "rules" -> Thread {
                    val list = AppLock.rules(this).map { (pkg, rule) ->
                        val s = AppLock.status(this, pkg, rule)
                        mapOf(
                            "pkg" to pkg,
                            "label" to AppLock.appLabel(this, pkg),
                            "icon" to AppLock.appIcon(this, pkg),
                            "mode" to rule.mode,
                            "minutes" to rule.minutes,
                            "usedSeconds" to s.usedSeconds,
                            "limitSeconds" to s.limitSeconds,
                            "locked" to s.locked,
                            "unlockAt" to s.unlockAt,
                        )
                    }
                    runOnUiThread { result.success(list) }
                }.start()
                "setRule" -> {
                    val pkg = call.argument<String>("pkg")!!
                    val mode = call.argument<String>("mode")!!
                    val minutes = call.argument<Int>("minutes") ?: 0
                    AppLock.setRule(this, pkg, AppLock.Rule(mode, minutes))
                    result.success(null)
                }
                // Same rule for several apps at once (e.g. "lock all social media").
                "setRules" -> {
                    val pkgs = call.argument<List<String>>("pkgs") ?: emptyList()
                    val rule = AppLock.Rule(
                        call.argument<String>("mode")!!, call.argument<Int>("minutes") ?: 0
                    )
                    pkgs.forEach { AppLock.setRule(this, it, rule) }
                    result.success(null)
                }
                // ---- Uninstall protection ----
                "protectionStatus" -> result.success(protectionStatus())
                "enableProtection" -> {
                    if (!UninstallProtection.hasAnyPassword(this)) {
                        result.error("NO_PIN", "Set the App Lock password first", null)
                    } else if (UninstallProtection.isAdminActive(this)) {
                        UninstallProtection.setOn(this, true)
                        result.success(protectionStatus())
                    } else {
                        // Android asks "Activate device admin app?"; answer in onActivityResult.
                        // (If protection was on before, its guard must not cover that screen.)
                        ReelCounterService.instance?.allowProtectedScreens()
                        pendingProtection?.success(protectionStatus())
                        pendingProtection = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(UninstallProtection.activateIntent(this), REQUEST_DEVICE_ADMIN)
                    }
                }
                "disableProtection" -> {
                    UninstallProtection.turnOff(this)
                    result.success(protectionStatus())
                }
                "hasPin" -> result.success(AppLock.hasPin(this))
                "fingerprintEnabled" -> result.success(AppLock.fingerprintEnabled(this))
                "setFingerprintEnabled" -> {
                    AppLock.setFingerprintEnabled(this, call.argument<Boolean>("on") ?: true)
                    result.success(null)
                }
                "checkPin" -> result.success(AppLock.checkPin(this, call.argument<String>("pin") ?: ""))
                "setPin" -> {
                    // Changing an existing password needs the current one.
                    val old = call.argument<String>("old")
                    if (AppLock.hasPin(this) && (old == null || !AppLock.checkPin(this, old))) {
                        result.error("WRONG_PIN", "Current password is wrong", null)
                    } else {
                        AppLock.setPin(this, call.argument<String>("pin")!!)
                        result.success(null)
                    }
                }
                "removeRule" -> {
                    AppLock.setRule(this, call.argument<String>("pkg")!!, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Zip tool: create, view, extract, lock / unlock zips (ZipTool.kt).
        MethodChannel(messenger, "abhi_utility/zip").setMethodCallHandler { call, result ->
            fun <T> bg(work: () -> T) = Thread {
                try {
                    val r = work()
                    runOnUiThread { result.success(r) }
                } catch (_: ZipTool.WrongPassword) {
                    runOnUiThread { result.error("WRONG_PASSWORD", "Wrong password", null) }
                } catch (e: Throwable) {
                    runOnUiThread { result.error("ZIP_FAILED", e.message ?: e.javaClass.simpleName, null) }
                }
            }.start()
            fun s(key: String) = call.argument<String>(key)
            when (call.method) {
                "localCopy" -> bg { ZipTool.localCopy(this, s("src")!!) }
                "create" -> bg {
                    ZipTool.create(this, call.argument<List<Map<String, String>>>("files")!!, s("name")!!, s("password"))
                }
                "list" -> bg { ZipTool.list(s("path")!!) }
                "checkPassword" -> bg { ZipTool.checkPassword(s("path")!!, s("password")!!) }
                "preview" -> bg { ZipTool.preview(this, s("path")!!, s("password"), s("entry")!!) }
                "extract" -> bg {
                    ZipTool.extract(this, s("path")!!, s("password"), call.argument<List<String>>("entries"), s("folder")!!)
                }
                "relock" -> bg { ZipTool.relock(this, s("path")!!, s("password"), s("newPassword"), s("name")!!) }
                "recent" -> bg { ZipTool.recent(this) }
                "delete" -> bg { ZipTool.delete(this, s("uri")!!); null }
                "share" -> { ZipTool.share(this, s("uri")!!, s("name")!!); result.success(null) }
                "openWith" -> {
                    try {
                        ZipTool.openWith(this, s("uri")!!, s("name")!!)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("NO_APP", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // APK Extractor: list apps, save their APK to Downloads, share / open it.
        MethodChannel(messenger, "abhi_utility/apk").setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> Thread {
                    try {
                        val apps = ApkExtractor.list(this, call.argument<Boolean>("system") ?: false)
                        runOnUiThread { result.success(apps) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("LIST_FAILED", e.message, null) }
                    }
                }.start()
                "export" -> Thread {
                    val pkg = call.argument<String>("pkg")!!
                    val action = call.argument<String>("action") ?: "save"
                    try {
                        val (uri, name) = ApkExtractor.export(this, pkg)
                        runOnUiThread {
                            try {
                                when (action) {
                                    "share" -> ApkExtractor.share(this, uri, name)
                                    "open" -> ApkExtractor.open(this, uri, name)
                                }
                            } catch (_: Exception) {
                            }
                            result.success(mapOf("uri" to uri.toString(), "name" to name))
                        }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("EXPORT_FAILED", e.message, null) }
                    }
                }.start()
                "appInfo" -> {
                    ApkExtractor.openAppInfo(this, call.argument<String>("pkg")!!)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "abhi_utility/app").setMethodCallHandler { call, result ->
            when (call.method) {
                "shareText" -> {
                    val send = Intent(Intent.ACTION_SEND)
                        .setType("text/plain")
                        .putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                    call.argument<String>("subject")?.let { send.putExtra(Intent.EXTRA_SUBJECT, it) }
                    startActivity(Intent.createChooser(send, call.argument<String>("title") ?: "Share"))
                    result.success(null)
                }
                "info" -> result.success(
                    mapOf("version" to AppShare.versionName(this), "apkSize" to AppShare.apkSize(this))
                )
                "shareApk" -> Thread {
                    try {
                        val uri = AppShare.exportApk(this)
                        runOnUiThread {
                            AppShare.share(this, uri)
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("SHARE_FAILED", e.message, null) }
                    }
                }.start()
                else -> result.notImplemented()
            }
        }

        pdfChannel = MethodChannel(messenger, "abhi_utility/pdf")
        pdfChannel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "save" -> {
                        val bytes = call.argument<ByteArray>("bytes")!!
                        val name = call.argument<String>("name")!!
                        Thread {
                            try {
                                val uri = PdfFiles.save(this, bytes, name)
                                runOnUiThread { result.success(uri) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("SAVE_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    "exists" -> result.success(PdfFiles.exists(this, call.argument<String>("uri")!!))
                    "open" -> { PdfFiles.open(this, call.argument<String>("uri")!!); result.success(null) }
                    "share" -> { PdfFiles.share(this, call.argument<String>("uri")!!); result.success(null) }
                    "copyToCache" -> {
                        val uri = call.argument<String>("uri")!!
                        Thread {
                            try {
                                val path = PdfFiles.copyToCache(this, uri)
                                runOnUiThread { result.success(path) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("OPEN_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    // PDF this app was opened with ("Open with → Abhi Utility"), if any.
                    "takeIncoming" -> {
                        val uri = incomingPdfUri(intent)
                        if (uri != null) intent?.data = null // only once (and leave spreadsheets alone)
                        result.success(uri)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("PDF_ERROR", e.message, null)
            }
        }

        // Excel viewer: list / read spreadsheets, "All files access", "Open with".
        sheetsChannel = MethodChannel(messenger, "abhi_utility/sheets")
        sheetsChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> result.success(SheetFiles.hasAllFilesAccess(this))
                "requestAllFilesAccess" -> {
                    SheetFiles.requestAllFilesAccess(this)
                    result.success(null)
                }
                "scan" -> Thread {
                    try {
                        val list = SheetFiles.scan(this)
                        runOnUiThread { result.success(list) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("SCAN_FAILED", e.message, null) }
                    }
                }.start()
                "read" -> {
                    val source = call.argument<String>("source")!!
                    Thread {
                        try {
                            val bytes = SheetFiles.read(this, source)
                            runOnUiThread { result.success(bytes) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("READ_FAILED", e.message, null) }
                        }
                    }.start()
                }
                "displayName" -> result.success(SheetFiles.displayName(this, call.argument<String>("uri")!!))
                // Spreadsheet this app was opened with ("Open with → Abhi Utility"), if any.
                "takeIncoming" -> {
                    val uri = SheetFiles.incomingUri(this, intent)
                    if (uri != null) intent?.data = null // only once
                    result.success(uri)
                }
                else -> result.notImplemented()
            }
        }

        downloaderChannel = MethodChannel(messenger, "abhi_utility/downloader")
        downloaderChannel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> result.success(
                        Downloads.start(
                            this,
                            call.argument<String>("url")!!,
                            call.argument<String>("fileName")!!,
                            call.argument<String>("mimeType"),
                            call.argument<String>("referer"),
                            call.argument<String>("userAgent"),
                            call.argument<String>("cookie"),
                        )
                    )
                    // Login cookies of the built-in browser, so logged-in videos download too.
                    "cookies" -> result.success(
                        android.webkit.CookieManager.getInstance().getCookie(call.argument<String>("url")!!)
                    )
                    "list" -> result.success(Downloads.list(this))
                    "open" -> {
                        Downloads.open(this, call.argument<Number>("id")!!.toLong(), call.argument<String>("mime"))
                        result.success(null)
                    }
                    "share" -> {
                        Downloads.share(this, call.argument<Number>("id")!!.toLong(), call.argument<String>("mime"))
                        result.success(null)
                    }
                    "remove" -> {
                        Downloads.remove(this, call.argument<Number>("id")!!.toLong())
                        result.success(null)
                    }
                    "bubbleEnabled" -> result.success(Downloads.bubbleEnabled(this))
                    "setBubbleEnabled" -> {
                        Downloads.setBubbleEnabled(this, call.argument<Boolean>("enabled") ?: true)
                        result.success(null)
                    }
                    // Why the app was opened: a shared link or the floating ⬇ button.
                    "takeLaunch" -> {
                        result.success(downloaderLaunch(intent))
                        intent?.removeExtra(Intent.EXTRA_TEXT)
                        intent?.removeExtra(EXTRA_OPEN)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("DOWNLOAD_ERROR", e.message, null)
            }
        }

        MethodChannel(messenger, "abhi_utility/status").setMethodCallHandler { call, result ->
            val business = call.argument<Boolean>("business") ?: false
            try {
                when (call.method) {
                    "hasAccess" -> result.success(StatusSaver.tree(this, business) != null)
                    // Opens the system folder picker at WhatsApp's status folder.
                    "pick" -> {
                        pendingStatusPick?.success(false)
                        pendingStatusPick = result
                        pendingStatusBusiness = business
                        @Suppress("DEPRECATION")
                        startActivityForResult(StatusSaver.pickIntent(business), StatusSaver.REQUEST_CODE)
                    }
                    "list" -> Thread {
                        val list = try { StatusSaver.list(this, business) } catch (e: Exception) { null }
                        runOnUiThread { result.success(list) }
                    }.start()
                    "thumb" -> Thread {
                        val bytes = StatusSaver.thumbnail(this, call.argument<String>("uri")!!, call.argument<Boolean>("video") ?: false)
                        runOnUiThread { result.success(bytes) }
                    }.start()
                    "save" -> Thread {
                        try {
                            val where = StatusSaver.save(this, call.argument<String>("uri")!!, call.argument<String>("name")!!, call.argument<String>("mime")!!)
                            runOnUiThread { result.success(where) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE_FAILED", e.message, null) }
                        }
                    }.start()
                    "open" -> {
                        StatusSaver.open(this, call.argument<String>("uri")!!, call.argument<String>("mime")!!)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("STATUS_ERROR", e.message, null)
            }
        }

        EventChannel(messenger, "abhi_utility/torch").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val cb = object : CameraManager.TorchCallback() {
                    override fun onTorchModeChanged(id: String, enabled: Boolean) {
                        if (id == cameraId) {
                            torchOn = enabled
                            events.success(enabled)
                        }
                    }
                }
                torchCallback = cb
                // Callback fires immediately with the current state.
                cameraManager.registerTorchCallback(cb, null)
            }

            override fun onCancel(arguments: Any?) {
                torchCallback?.let { cameraManager.unregisterTorchCallback(it) }
                torchCallback = null
            }
        })
    }

    private fun isReelServiceEnabled(): Boolean {
        val enabled = Settings.Secure.getString(
            contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val me = ComponentName(this, ReelCounterService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    private var pendingProtection: MethodChannel.Result? = null

    /** on: switched on; admin: Android blocks uninstalling; guard: the screen guard can run. */
    private fun protectionStatus(): Map<String, Boolean> = mapOf(
        "on" to UninstallProtection.isOn(this),
        "admin" to UninstallProtection.isAdminActive(this),
        "guard" to isReelServiceEnabled(),
        "hasPassword" to UninstallProtection.hasAnyPassword(this),
    )

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100)
        }
    }

    private var pdfChannel: MethodChannel? = null

    private fun incomingPdfUri(i: Intent?): String? {
        if (i?.action != Intent.ACTION_VIEW) return null
        if (SheetFiles.incomingUri(this, i) != null) return null // Excel/CSV: the Excel viewer
        return i.data?.toString()
    }

    private var sheetsChannel: MethodChannel? = null

    private var downloaderChannel: MethodChannel? = null
    private var pendingStatusPick: MethodChannel.Result? = null
    private var pendingStatusBusiness = false

    @Deprecated("Needed for the folder picker result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_DEVICE_ADMIN) {
            // Only switch on if the parent pressed "Activate".
            if (UninstallProtection.isAdminActive(this)) UninstallProtection.setOn(this, true)
            pendingProtection?.success(protectionStatus())
            pendingProtection = null
            return
        }
        if (requestCode != StatusSaver.REQUEST_CODE) return
        val result = pendingStatusPick ?: return
        pendingStatusPick = null
        val tree = data?.data
        if (resultCode != RESULT_OK || tree == null) {
            result.success(null) // cancelled
            return
        }
        try {
            // true = the WhatsApp status folder; false = some other folder was picked.
            result.success(StatusSaver.onPicked(this, pendingStatusBusiness, tree))
        } catch (e: Exception) {
            result.error("PICK_FAILED", e.message, null)
        }
    }

    companion object {
        /** Extra set by the floating ⬇ button: open the Downloader. */
        const val EXTRA_OPEN = "open"

        private const val REQUEST_DEVICE_ADMIN = 4711
    }

    /** {action: "share", text} for "Share → Abhi Utility", {action: "bubble"} for the ⬇ button, else null. */
    private fun downloaderLaunch(i: Intent?): Map<String, String>? {
        if (i == null) return null
        if (i.action == Intent.ACTION_SEND) {
            val text = i.getStringExtra(Intent.EXTRA_TEXT) ?: return null
            return mapOf("action" to "share", "text" to text)
        }
        if (i.getStringExtra(EXTRA_OPEN) == "downloader") return mapOf("action" to "bubble")
        if (i.getStringExtra(EXTRA_OPEN) == "status") return mapOf("action" to "status")
        return null
    }

    /** App already open and another app sends a PDF / link, or the ⬇ button is tapped. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingPdfUri(intent)?.let { pdfChannel?.invokeMethod("incomingPdf", it) }
        SheetFiles.incomingUri(this, intent)?.let { sheetsChannel?.invokeMethod("incomingSheet", it) }
        downloaderLaunch(intent)?.let { downloaderChannel?.invokeMethod("launch", it) }
    }

    override fun onDestroy() {
        torchCallback?.let { cameraManager.unregisterTorchCallback(it) }
        super.onDestroy()
    }
}
