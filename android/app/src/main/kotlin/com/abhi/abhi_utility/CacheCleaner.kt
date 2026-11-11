package com.abhi.abhi_utility

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Deletes old temporary copies: zips opened / made / previewed and PDFs opened from
 * other apps each get a folder in the cache (ZipTool, PdfFiles) that nothing else removed,
 * so the app's storage kept growing. Recents point at Downloads, not at these copies.
 */
object CacheCleaner {
    private const val TAG = "CacheCleaner"
    private val FOLDERS = listOf("zip_open", "zip_out", "zip_preview", "pdf_open")

    /** Anything older than this is no longer open in the app. */
    private const val MAX_AGE_MS = 24 * 60 * 60_000L

    fun cleanInBackground(context: Context) {
        val cache = context.applicationContext.cacheDir
        Thread {
            val cutoff = System.currentTimeMillis() - MAX_AGE_MS
            var freed = 0L
            for (name in FOLDERS) {
                File(cache, name).listFiles()?.forEach { dir ->
                    if (dir.lastModified() < cutoff) {
                        freed += dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
                        dir.deleteRecursively()
                    }
                }
            }
            if (freed > 0) Log.i(TAG, "freed ${freed / 1024} KB")
        }.start()
    }
}
