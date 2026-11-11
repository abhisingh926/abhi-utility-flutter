package com.abhi.abhi_utility

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Copies the APK of an installed app to Downloads/AbhiUtility/APKs and shares it.
 *
 * Apps from the Play Store are often split into several APKs (base + language,
 * screen size, CPU parts). The base APK alone won't install for those, so they are
 * saved as one ".apks" bundle (a zip of all parts) that installers like SAI open.
 */
object ApkExtractor {
    private const val FOLDER = "AbhiUtility/APKs"
    private const val APK_MIME = "application/vnd.android.package-archive"

    private fun appInfo(activity: Activity, pkg: String): ApplicationInfo =
        activity.packageManager.getApplicationInfo(pkg, 0)

    private fun parts(info: ApplicationInfo): List<File> =
        listOf(File(info.sourceDir)) + (info.splitSourceDirs ?: emptyArray()).map { File(it) }

    @Suppress("DEPRECATION")
    private fun versionName(activity: Activity, pkg: String): String = try {
        activity.packageManager.getPackageInfo(pkg, 0).versionName ?: ""
    } catch (_: PackageManager.NameNotFoundException) {
        ""
    }

    /**
     * Launchable apps with size and version (runs on a background thread). No icons:
     * drawing + PNG-encoding every icon took seconds, so the page loads them per row
     * with [icon] as they scroll into view.
     */
    fun list(activity: Activity, includeSystem: Boolean): List<Map<String, Any?>> {
        val pm = activity.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(intent, 0)
            .map { it.activityInfo.applicationInfo }
            .distinctBy { it.packageName }
            .mapNotNull { info ->
                val system = (info.flags and (ApplicationInfo.FLAG_SYSTEM or
                    ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0
                if (system && !includeSystem) return@mapNotNull null
                val files = parts(info)
                @Suppress("DEPRECATION")
                val pkgInfo = try {
                    pm.getPackageInfo(info.packageName, 0)
                } catch (_: Exception) {
                    null
                }
                mapOf(
                    "pkg" to info.packageName,
                    "label" to pm.getApplicationLabel(info).toString(),
                    "version" to (pkgInfo?.versionName ?: ""),
                    "size" to files.sumOf { it.length() },
                    "split" to (files.size > 1),
                    "system" to system,
                    "updated" to (pkgInfo?.lastUpdateTime ?: 0L),
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
    }

    /** Icons are drawn a few at a time off the main thread. */
    val iconPool: java.util.concurrent.ExecutorService = java.util.concurrent.Executors.newFixedThreadPool(3)

    /**
     * Saves the app to Downloads/AbhiUtility/APKs (replacing an older copy with the
     * same name) and returns its content:// uri and file name.
     */
    fun export(activity: Activity, pkg: String): Pair<Uri, String> {
        val info = appInfo(activity, pkg)
        val files = parts(info)
        val label = activity.packageManager.getApplicationLabel(info).toString()
        val version = versionName(activity, pkg)
        val bundle = files.size > 1
        val base = "$label ${version}".trim().replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val name = if (bundle) "$base.apks" else "$base.apk"

        val resolver = activity.contentResolver
        val path = "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/"
        resolver.delete(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
            arrayOf(name, path),
        )
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, if (bundle) "application/zip" else APK_MIME)
            put(MediaStore.Downloads.RELATIVE_PATH, path)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Could not create the file in Downloads")
        try {
            resolver.openOutputStream(uri)!!.use { out ->
                if (!bundle) {
                    files[0].inputStream().use { it.copyTo(out) }
                } else {
                    ZipOutputStream(out).use { zip ->
                        files.forEach { f ->
                            // base.apk + split_config.xxx.apk, the layout split installers expect.
                            zip.putNextEntry(ZipEntry(f.name))
                            f.inputStream().use { it.copyTo(zip) }
                            zip.closeEntry()
                        }
                    }
                }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri to name
    }

    fun share(activity: Activity, uri: Uri, name: String) {
        val bundle = name.endsWith(".apks")
        val intent = Intent(Intent.ACTION_SEND)
            .setType(if (bundle) "application/octet-stream" else APK_MIME)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_SUBJECT, name)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(intent, "Share $name"))
    }

    /** Opens the saved file with an installer / file manager. */
    fun open(activity: Activity, uri: Uri, name: String) {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, if (name.endsWith(".apks")) "application/octet-stream" else APK_MIME)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(Intent.createChooser(intent, "Open $name"))
    }

    fun openAppInfo(activity: Activity, pkg: String) {
        activity.startActivity(
            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
        )
    }
}
