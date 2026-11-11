package com.abhi.abhi_utility

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.content.Intent
import android.net.Uri
import java.io.File
import androidx.core.content.FileProvider
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
    /** Status Saver thumbnails, a few at a time. */
    private val thumbPool = java.util.concurrent.Executors.newFixedThreadPool(3)


    private lateinit var cameraManager: CameraManager
    private var cameraId: String? = null
    private var torchOn = false
    private var torchCallback: CameraManager.TorchCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CacheCleaner.cleanInBackground(this)
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        cameraId = findFlashCamera(cameraManager)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        BackupCrypto.register(messenger) // encrypted diary backups

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
                // Display names: built-in reel apps, the apps being counted, and any [pkgs] asked for
                // (e.g. apps that were counted earlier and still show up in the history).
                "appNames" -> {
                    val extra = call.argument<List<String>>("pkgs") ?: emptyList()
                    val names = LinkedHashMap<String, String>(ReelApps.NAMES)
                    for (pkg in ReelApps.counted(this) + extra) {
                        if (pkg !in names) names[pkg] = AppLock.appLabel(this, pkg)
                    }
                    result.success(names)
                }
                "countedApps" -> result.success(ReelApps.counted(this).toList())
                "setCountedApps" -> {
                    ReelApps.setCounted(this, call.argument<List<String>>("pkgs") ?: emptyList())
                    result.success(null)
                }
                "bankingStatus" -> result.success(BankingMode.status(this))
                "setBankingAuto" -> {
                    BankingMode.setAutoOn(this, call.argument<Boolean>("on") ?: true)
                    result.success(null)
                }
                "bankingApps" -> Thread {
                    val pkgs = BankingMode.installedBankApps(this)
                    runOnUiThread { result.success(pkgs) }
                }.start()
                "setBankingApps" -> {
                    val pkgs = call.argument<List<String>>("pkgs") ?: emptyList()
                    Thread { BankingMode.setChosen(this, pkgs); runOnUiThread { result.success(null) } }.start()
                }
                "openAccessibility" -> {
                    startActivity(BankingMode.settingsIntent(this))
                    result.success(null)
                }
                "resumeFromBanking" -> {
                    BankingMode.resume(this)
                    result.success(null)
                }
                "openUsageAccess" -> {
                    startActivity(
                        Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "initialTab" -> result.success(intent?.getStringExtra("tab"))
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "abhi_utility/applock").setMethodCallHandler { call, result ->
            when (call.method) {
                // Installed apps with icons; built off the main thread (can take a moment).
                "apps" -> Thread {
                    val t = android.os.SystemClock.elapsedRealtime()
                    val apps = AppLock.appsForPicker(this)
                    android.util.Log.d("AppLock", "apps: ${apps.size} in ${android.os.SystemClock.elapsedRealtime() - t} ms")
                    runOnUiThread { result.success(apps) }
                }.start()
                "rules" -> Thread {
                    val list = AppLock.rules(this).map { (pkg, rule) ->
                        val s = AppLock.status(this, pkg, rule)
                        mapOf(
                            "pkg" to pkg,
                            "label" to AppLock.appLabel(this, pkg),
                            "icon" to AppLock.cachedIcon(this, pkg),
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
                    if (BuildConfig.PLAY_STORE) {
                        result.error("UNAVAILABLE", "Uninstall protection isn't in the Play Store version", null)
                    } else if (!UninstallProtection.hasAnyPassword(this)) {
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

        // SOS: contacts, on/off, permissions, practice "S" check (Sos.kt).
        MethodChannel(messenger, "abhi_utility/sos").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(sosStatus())
                // SOS history (SosHistory.kt): every SOS, its calls, location SMS and recording.
                "history" -> result.success(SosHistory.list(this))
                "clearHistory" -> {
                    SosHistory.clear(this)
                    result.success(null)
                }
                // A recording that never got uploaded (kept in files/sos) opens in a video player.
                "openRecording" -> {
                    val file = File(call.argument<String>("path") ?: "")
                    val dir = File(filesDir, "sos").canonicalFile
                    if (!file.exists() || file.canonicalFile.parentFile != dir) {
                        result.error("NOT_FOUND", "The recording is no longer on this phone", null)
                    } else try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                        startActivity(
                            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/mp4")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("NO_PLAYER", "No app can play this video", null)
                    }
                }
                "setOn" -> {
                    Sos.setOn(this, call.argument<Boolean>("on") ?: false)
                    ReelCounterService.instance?.sos?.refresh()
                    result.success(sosStatus())
                }
                "setContacts" -> {
                    Sos.setContacts(this, call.argument<List<Map<String, String>>>("contacts") ?: emptyList())
                    ReelCounterService.instance?.sos?.refresh()
                    result.success(sosStatus())
                }
                "requestPermissions" -> {
                    val missing = Sos.missingPermissions(this)
                    if (missing.isEmpty()) {
                        result.success(sosStatus())
                    } else {
                        pendingSosPermissions?.success(sosStatus())
                        pendingSosPermissions = result
                        requestPermissions(missing.toTypedArray(), REQUEST_SOS_PERMISSIONS)
                    }
                }
                "openAppSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", packageName, null))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "pickContact" -> {
                    pendingContactPick?.success(null)
                    pendingContactPick = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(
                        Intent(Intent.ACTION_PICK, android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI),
                        REQUEST_PICK_CONTACT
                    )
                }
                // Practice pad: points [x0, y0, x1, y1, …] in logical pixels.
                "isS" -> {
                    val flat = call.argument<List<Double>>("points") ?: emptyList()
                    val density = resources.displayMetrics.density
                    val pts = flat.chunked(2).filter { it.size == 2 }
                        .map { android.graphics.PointF(it[0].toFloat() * density, it[1].toFloat() * density) }
                    result.success(Sos.isS(pts, 80f * density))
                }
                "stop" -> {
                    ReelCounterService.instance?.sos?.stop()
                    result.success(null)
                }
                // No one answered: text the location / record video + sound (asks for what's missing).
                "setNoAnswer" -> {
                    val sms = call.argument<Boolean>("smsLocation") ?: false
                    val record = call.argument<Boolean>("record") ?: false
                    Sos.setNoAnswer(this, sms, record)
                    val missing = buildSet {
                        if (sms) addAll(Sos.missing(this@MainActivity, Sos.LOCATION_SMS_PERMISSIONS))
                        if (record) addAll(Sos.missing(this@MainActivity, Sos.RECORD_PERMISSIONS))
                    }
                    if (missing.isEmpty()) {
                        result.success(sosStatus())
                    } else {
                        pendingSosPermissions?.success(sosStatus())
                        pendingSosPermissions = result
                        requestPermissions(missing.toTypedArray(), REQUEST_SOS_PERMISSIONS)
                    }
                }
                // SOS key of the logged-in account for uploading recordings; no key = clear.
                "setUpload" -> {
                    val key = call.argument<String>("key")
                    val url = call.argument<String>("baseUrl")
                    Sos.setUpload(
                        this,
                        if (key.isNullOrEmpty() || url.isNullOrEmpty()) null
                        else Sos.Upload(key, url, call.argument<Int>("userId") ?: 0),
                        call.argument<String>("name"),
                    )
                    result.success(sosStatus())
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
                "icon" -> {
                    val pkg = call.argument<String>("pkg")!!
                    ApkExtractor.iconPool.execute {
                        val png = AppLock.appIcon(this, pkg)
                        runOnUiThread { result.success(png) }
                    }
                }
                "appInfo" -> {
                    ApkExtractor.openAppInfo(this, call.argument<String>("pkg")!!)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "abhi_utility/app").setMethodCallHandler { call, result ->
            when (call.method) {
                // Privacy policy / terms in the browser.
                "openUrl" -> try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))))
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
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
                // Diary / App Lock open: no picture of the app in Recents. Android 13+ can
                // do that alone; older versions need FLAG_SECURE (also blocks screenshots).
                "setPrivate" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (Build.VERSION.SDK_INT >= 33) {
                        setRecentsScreenshotEnabled(!on)
                    } else if (on) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                // Survives "Clear data" (only a reinstall resets it): limits offline use.
                "firstInstallTime" -> result.success(
                    packageManager.getPackageInfo(packageName, 0).firstInstallTime
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

        // Excel viewer and Docs: list / read / save files, "All files access", "Open with".
        sheetsChannel = MethodChannel(messenger, "abhi_utility/sheets")
        sheetsChannel!!.setMethodCallHandler { call, result -> handleFiles(SheetFiles.Kind.SHEETS, call, result) }
        docsChannel = MethodChannel(messenger, "abhi_utility/docs")
        docsChannel!!.setMethodCallHandler { call, result -> handleFiles(SheetFiles.Kind.DOCS, call, result) }

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
                    "hasAccess" -> result.success(StatusSaver.hasAccess(this, business))
                    // "All files access" settings page (reading the folder directly, no picker).
                    "requestAllFiles" -> {
                        SheetFiles.requestAllFilesAccess(this)
                        result.success(null)
                    }
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
                    // A shared pool: a folder of 100+ statuses used to start 100+ threads at once.
                    "thumb" -> thumbPool.execute {
                        val bytes = try {
                            StatusSaver.thumbnail(this, call.argument<String>("uri")!!, call.argument<Boolean>("video") ?: false)
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread { result.success(bytes) }
                    }
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
    private var pendingSosPermissions: MethodChannel.Result? = null
    private var pendingContactPick: MethodChannel.Result? = null

    private fun sosStatus(): Map<String, Any?> = mapOf(
        "on" to Sos.isOn(this),
        "contacts" to Sos.contactMaps(this),
        "permissions" to Sos.missingPermissions(this).isEmpty(),
        "service" to isReelServiceEnabled(),
        "active" to (ReelCounterService.instance?.sos?.isActive ?: false),
        "smsLocation" to Sos.smsLocation(this),
        "record" to Sos.record(this),
        "smsLocationPermissions" to Sos.missing(this, Sos.LOCATION_SMS_PERMISSIONS).isEmpty(),
        "recordPermissions" to Sos.missing(this, Sos.RECORD_PERMISSIONS).isEmpty(),
        "uploadUserId" to Sos.upload(this)?.userId,
    )

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_SOS_PERMISSIONS) {
            ReelCounterService.instance?.sos?.refresh()
            pendingSosPermissions?.success(sosStatus())
            pendingSosPermissions = null
        }
    }

    /** Name + number of the contact picked for SOS (no contacts permission needed). */
    private fun onContactPicked(resultCode: Int, data: Intent?) {
        val result = pendingContactPick ?: return
        pendingContactPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val phone = android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER
            val name = android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
            contentResolver.query(uri, arrayOf(name, phone), null, null, null)?.use {
                if (it.moveToFirst()) {
                    result.success(mapOf("name" to (it.getString(0) ?: ""), "number" to (it.getString(1) ?: "")))
                    return
                }
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("PICK_FAILED", e.message, null)
        }
    }

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
        // Excel/CSV and Word files have their own viewers.
        if (SheetFiles.incomingUri(this, i, SheetFiles.Kind.SHEETS) != null) return null
        if (SheetFiles.incomingUri(this, i, SheetFiles.Kind.DOCS) != null) return null
        return i.data?.toString()
    }

    /** Excel viewer ("sheets") and Docs ("docs") share these file operations. */
    private fun handleFiles(kind: SheetFiles.Kind, call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasAllFilesAccess" -> result.success(SheetFiles.hasAllFilesAccess(this))
            "requestAllFilesAccess" -> {
                SheetFiles.requestAllFilesAccess(this)
                result.success(null)
            }
            "scan" -> Thread {
                try {
                    val list = SheetFiles.scan(this, kind)
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
            "write" -> {
                val source = call.argument<String>("source")!!
                val bytes = call.argument<ByteArray>("bytes")!!
                Thread {
                    try {
                        SheetFiles.write(this, source, bytes)
                        runOnUiThread { result.success(true) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("WRITE_FAILED", e.message, null) }
                    }
                }.start()
            }
            "saveCopy" -> {
                val bytes = call.argument<ByteArray>("bytes")!!
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime")!!
                Thread {
                    try {
                        val uri = SheetFiles.saveCopy(this, bytes, name, mime)
                        runOnUiThread { result.success(uri) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("SAVE_FAILED", e.message, null) }
                    }
                }.start()
            }
            "displayName" -> result.success(SheetFiles.displayName(this, call.argument<String>("uri")!!))
            // File of this kind the app was opened with ("Open with → Abhi Utility"), if any.
            "takeIncoming" -> {
                val uri = SheetFiles.incomingUri(this, intent, kind)
                if (uri != null) intent?.data = null // only once
                result.success(uri)
            }
            else -> result.notImplemented()
        }
    }

    private var sheetsChannel: MethodChannel? = null
    private var docsChannel: MethodChannel? = null

    private var downloaderChannel: MethodChannel? = null
    private var pendingStatusPick: MethodChannel.Result? = null
    private var pendingStatusBusiness = false

    @Deprecated("Needed for the folder picker result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_CONTACT) {
            onContactPicked(resultCode, data)
            return
        }
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
        private const val REQUEST_SOS_PERMISSIONS = 4712
        private const val REQUEST_PICK_CONTACT = 4713
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
        SheetFiles.incomingUri(this, intent, SheetFiles.Kind.SHEETS)?.let { sheetsChannel?.invokeMethod("incomingSheet", it) }
        SheetFiles.incomingUri(this, intent, SheetFiles.Kind.DOCS)?.let { docsChannel?.invokeMethod("incomingDoc", it) }
        downloaderLaunch(intent)?.let { downloaderChannel?.invokeMethod("launch", it) }
    }

    override fun onDestroy() {
        torchCallback?.let { cameraManager.unregisterTorchCallback(it) }
        super.onDestroy()
    }
}
