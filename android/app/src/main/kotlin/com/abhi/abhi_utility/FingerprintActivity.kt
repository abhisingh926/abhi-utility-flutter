package com.abhi.abhi_utility

import android.app.Activity
import android.graphics.Color
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal

/**
 * Shows the system fingerprint prompt for App Lock ("give <app> more time").
 * The prompt needs an activity, so ReelCounterService opens this one, hides its
 * lock overlays, and gets the answer back through [ReelCounterService.onFingerprintResult].
 */
class FingerprintActivity : Activity() {
    companion object {
        const val EXTRA_PKG = "pkg"
        const val EXTRA_APP_NAME = "appName"
    }

    private var pkg = ""
    private var delivered = false
    private val cancel = CancellationSignal()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.setBackgroundColor(Color.rgb(12, 14, 40))
        pkg = intent.getStringExtra(EXTRA_PKG) ?: ""
        val name = intent.getStringExtra(EXTRA_APP_NAME) ?: "this app"

        val builder = BiometricPrompt.Builder(this)
            .setTitle("Unlock with fingerprint")
            .setSubtitle("Give $name more time")
            .setNegativeButton("Use password", mainExecutor) { _, _ -> finishWith(false) }
        if (Build.VERSION.SDK_INT >= 30) {
            builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        }
        try {
            builder.build().authenticate(cancel, mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) {
                    finishWith(true)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                    finishWith(false)
                }
                // onAuthenticationFailed (wrong finger): the prompt stays open and lets the user retry.
            })
        } catch (e: Exception) {
            finishWith(false)
        }
    }

    private fun finishWith(ok: Boolean) {
        if (delivered) return
        delivered = true
        ReelCounterService.instance?.onFingerprintResult(pkg, ok)
        finish()
        overridePendingTransition(0, 0)
    }

    override fun onDestroy() {
        if (!cancel.isCanceled) cancel.cancel()
        finishWith(false) // closed without an answer: bring the lock back
        super.onDestroy()
    }
}
