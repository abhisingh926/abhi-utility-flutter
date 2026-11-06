package com.abhi.abhi_utility

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/**
 * Shares this app's own APK, so friends can install it (WhatsApp, Bluetooth,
 * Quick Share…). The APK is copied to Downloads/AbhiUtility first: other apps
 * can't read it from where Android keeps installed apps.
 */
object AppShare {
    private const val FOLDER = "AbhiUtility"

    fun versionName(activity: Activity): String =
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: "1.0"

    /** Size of the installed APK in bytes. */
    fun apkSize(activity: Activity): Long = File(activity.applicationInfo.sourceDir).length()

    /** Copies the APK to Downloads and returns its content:// uri (runs on a background thread). */
    fun exportApk(activity: Activity): Uri {
        val apk = File(activity.applicationInfo.sourceDir)
        val name = "Abhi Utility ${versionName(activity)}.apk"
        val resolver = activity.contentResolver
        val path = "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/"

        // Replace an older copy we made, instead of piling up "(1)", "(2)"… files.
        resolver.delete(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
            arrayOf(name, path),
        )

        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "application/vnd.android.package-archive")
            put(MediaStore.Downloads.RELATIVE_PATH, path)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Could not create the APK file")
        try {
            resolver.openOutputStream(uri)!!.use { out -> apk.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri
    }

    fun share(activity: Activity, uri: Uri) {
        val intent = Intent(Intent.ACTION_SEND)
            .setType("application/vnd.android.package-archive")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_SUBJECT, "Abhi Utility app")
            .putExtra(
                Intent.EXTRA_TEXT,
                "Try Abhi Utility 🔦🔒📄 — shake flashlight, reel counter, app lock, PDF scanner, diary and more. " +
                    "Open the APK file to install it (allow \"Install unknown apps\" when asked)."
            )
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(intent, "Share Abhi Utility"))
    }
}
