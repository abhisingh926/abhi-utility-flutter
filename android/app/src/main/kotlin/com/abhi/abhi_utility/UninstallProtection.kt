package com.abhi.abhi_utility

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent

/**
 * Uninstall protection (parental control), two layers:
 *  1. Device admin: while active, Android refuses to uninstall Abhi Utility.
 *  2. ReelCounterService covers every screen that could undo that (uninstall
 *     dialog, Abhi Utility's App info, device admin and accessibility settings)
 *     with a password pad. The App Lock password or the fingerprint unlocks
 *     those screens for a few minutes. (Not the Diary password: anyone can
 *     create that one, so it must never undo the parent's protection.)
 *
 * Turned off only from inside the app (App Lock tab, behind its password).
 */
object UninstallProtection {
    private const val PREFS = "app_lock"
    private const val KEY_ON = "uninstall_protection"

    /** After the right password, protected screens stay open this long. */
    const val UNLOCK_MS = 5 * 60_000L

    fun admin(context: Context) = ComponentName(context, UninstallProtectionAdmin::class.java)

    private fun dpm(context: Context) =
        context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    fun isAdminActive(context: Context): Boolean = dpm(context).isAdminActive(admin(context))

    /** Switched on by the parent (the guard runs even if the admin was removed somehow). */
    fun isOn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ON, false)

    fun setOn(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ON, on).apply()
    }

    /** System screen that asks "Activate device admin app?". */
    fun activateIntent(context: Context): Intent =
        Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
            .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin(context))
            .putExtra(
                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "Stops children from uninstalling Abhi Utility. Only someone with the App Lock " +
                    "password can turn this off (Abhi Utility → App Lock).",
            )

    /** Turns everything off so the app can be uninstalled normally. */
    fun turnOff(context: Context) {
        setOn(context, false)
        if (isAdminActive(context)) dpm(context).removeActiveAdmin(admin(context))
    }

    /** Protection needs the App Lock password (the Diary password doesn't count). */
    fun hasAnyPassword(context: Context): Boolean = AppLock.hasPin(context)

    /** Only the App Lock password. */
    fun checkPassword(context: Context, pin: String): Boolean =
        pin.isNotEmpty() && AppLock.checkPin(context, pin)
}

/** Device admin with no policies: it only makes Android refuse to uninstall the app. */
class UninstallProtectionAdmin : DeviceAdminReceiver() {
    override fun onDisableRequested(context: Context, intent: Intent): CharSequence =
        "Abhi Utility will no longer be protected from being uninstalled. " +
            "Parents: turn it off in Abhi Utility → App Lock instead."
}
