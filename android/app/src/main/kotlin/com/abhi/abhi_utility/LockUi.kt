package com.abhi.abhi_utility

import android.animation.ObjectAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Look of the App Lock screens drawn over other apps (lock screen, password pad,
 * extra time, uninstall guard): brand gradient, vector icons, round keys, PIN dots.
 * Plain views only: these windows belong to the accessibility service, not an activity.
 */
class LockUi(private val c: Context) {

    companion object {
        // Brand colours (lib/app_theme.dart).
        val NAVY = Color.rgb(10, 16, 51)
        val INDIGO = Color.rgb(43, 58, 158)
        val CYAN = Color.rgb(34, 195, 238)
        val ERROR = Color.rgb(255, 120, 120)
        private val MEDIUM: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        private val LIGHT: Typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
    }

    fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.resources.displayMetrics).toInt()

    private fun white(alpha: Int) = Color.argb(alpha, 255, 255, 255)

    /** Text sizes itself (not the column's width), centered, never wider than a phone column. */
    private fun TextView.wrapCentered() = apply {
        maxWidth = dp(340f)
        layoutParams = LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_HORIZONTAL }
    }

    /** Full-screen background: navy at the bottom, a hint of indigo at the top. */
    fun background(): Drawable = GradientDrawable(
        GradientDrawable.Orientation.TOP_BOTTOM,
        intArrayOf(Color.rgb(27, 36, 104), NAVY, Color.rgb(6, 9, 30)),
    )

    fun title(text: String) = TextView(c).apply {
        this.text = text
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        typeface = MEDIUM
        gravity = Gravity.CENTER
        letterSpacing = 0.01f
        wrapCentered()
    }

    fun subtitle(text: String) = TextView(c).apply {
        this.text = text
        setTextColor(white(170))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        gravity = Gravity.CENTER
        setLineSpacing(0f, 1.25f)
        wrapCentered()
    }

    fun errorText() = TextView(c).apply {
        setTextColor(ERROR)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        gravity = Gravity.CENTER
        minHeight = dp(20f)
        wrapCentered()
    }

    private fun icon(res: Int, sizeDp: Float, tint: Int) = ImageView(c).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(tint)
        layoutParams = FrameLayout.LayoutParams(dp(sizeDp), dp(sizeDp), Gravity.CENTER)
    }

    /** Round badge with an icon (lock, shield, check…) above a title. */
    fun badge(res: Int, tint: Int = CYAN): View = FrameLayout(c).apply {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.argb(36, Color.red(tint), Color.green(tint), Color.blue(tint)))
            setStroke(dp(1f), Color.argb(90, Color.red(tint), Color.green(tint), Color.blue(tint)))
        }
        addView(icon(res, 30f, tint))
        layoutParams = LinearLayout.LayoutParams(dp(64f), dp(64f)).apply { gravity = Gravity.CENTER_HORIZONTAL }
    }

    /** The locked app's icon on a soft card, with a small lock badge in the corner. */
    fun appBadge(appIcon: Drawable?): View = FrameLayout(c).apply {
        val card = FrameLayout(c).apply {
            background = GradientDrawable().apply {
                cornerRadius = dp(28f).toFloat()
                setColor(white(18))
                setStroke(dp(1f), white(40))
            }
            if (appIcon != null) {
                addView(ImageView(c).apply { setImageDrawable(appIcon) },
                    FrameLayout.LayoutParams(dp(64f), dp(64f), Gravity.CENTER))
            } else {
                addView(icon(R.drawable.lock_ui_lock, 40f, Color.WHITE))
            }
        }
        addView(card, FrameLayout.LayoutParams(dp(104f), dp(104f), Gravity.TOP or Gravity.START))
        val lock = FrameLayout(c).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(CYAN)
                setStroke(dp(3f), NAVY)
            }
            addView(icon(R.drawable.lock_ui_lock, 18f, NAVY))
        }
        addView(lock, FrameLayout.LayoutParams(dp(38f), dp(38f), Gravity.BOTTOM or Gravity.END))
        layoutParams = LinearLayout.LayoutParams(dp(116f), dp(116f)).apply { gravity = Gravity.CENTER_HORIZONTAL }
    }

    private fun ripple(content: Drawable, mask: Drawable? = null) =
        RippleDrawable(ColorStateList.valueOf(white(60)), content, mask)

    /** Wide pill button: cyan filled (main action) or outlined (secondary). */
    fun button(text: String, primary: Boolean, widthDp: Float = 260f, onClick: () -> Unit) = TextView(c).apply {
        this.text = text
        gravity = Gravity.CENTER
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        typeface = MEDIUM
        setTextColor(if (primary) NAVY else Color.WHITE)
        val shape = GradientDrawable().apply {
            cornerRadius = dp(28f).toFloat()
            if (primary) setColor(CYAN) else { setColor(white(10)); setStroke(dp(1f), white(70)) }
        }
        background = ripple(shape)
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(dp(widthDp), dp(52f)).apply { gravity = Gravity.CENTER_HORIZONTAL }
    }

    /** Text-only button (e.g. "Use fingerprint", "Cancel"). */
    fun textButton(text: String, onClick: () -> Unit) = TextView(c).apply {
        this.text = text
        gravity = Gravity.CENTER
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        typeface = MEDIUM
        setTextColor(CYAN)
        setPadding(dp(20f), dp(12f), dp(20f), dp(12f))
        background = ripple(GradientDrawable().apply { setColor(Color.TRANSPARENT); cornerRadius = dp(24f).toFloat() },
            GradientDrawable().apply { setColor(Color.WHITE); cornerRadius = dp(24f).toFloat() })
        isClickable = true
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_HORIZONTAL }
    }

    /**
     * 3×4 number pad: digits, backspace and OK (a check mark). [key] is the key size in px.
     * [onKey] gets "0".."9", "⌫" or "OK".
     */
    fun numberPad(key: Int, gap: Int, onKey: (String) -> Unit): LinearLayout {
        val grid = LinearLayout(c).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "OK").chunked(3).forEach { rowKeys ->
            val row = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
            rowKeys.forEach { k ->
                val circle = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(when (k) { "OK" -> CYAN; "⌫" -> Color.TRANSPARENT; else -> white(22) })
                    if (k != "OK" && k != "⌫") setStroke(dp(1f), white(28))
                }
                val mask = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) }
                val view: View = when (k) {
                    "⌫" -> FrameLayout(c).apply { addView(icon(R.drawable.lock_ui_backspace, 26f, white(220))) }
                    "OK" -> FrameLayout(c).apply { addView(icon(R.drawable.lock_ui_check, 30f, NAVY)) }
                    else -> TextView(c).apply {
                        text = k
                        gravity = Gravity.CENTER
                        setTextColor(Color.WHITE)
                        setTextSize(TypedValue.COMPLEX_UNIT_PX, key * 0.38f)
                        typeface = LIGHT
                        includeFontPadding = false
                    }
                }
                view.background = ripple(circle, mask)
                view.isClickable = true
                view.contentDescription = when (k) { "⌫" -> "Delete"; "OK" -> "Confirm"; else -> k }
                view.setOnClickListener {
                    it.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    onKey(k)
                }
                row.addView(view, LinearLayout.LayoutParams(key, key).apply { setMargins(gap * 2, gap, gap * 2, gap) })
            }
            grid.addView(row, LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_HORIZONTAL })
        }
        return grid
    }

    /** PIN dots: hollow until typed, filled for each digit (at least 4 shown, up to 6). */
    inner class PinDots : View(c) {
        var count = 0
            set(v) { field = v; invalidate() }
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(1.5f).toFloat()
            color = white(150)
        }
        private val r = dp(7f).toFloat()
        private val step = dp(26f).toFloat()

        init {
            layoutParams = LinearLayout.LayoutParams(dp(6 * 26f), dp(28f)).apply { gravity = Gravity.CENTER_HORIZONTAL }
        }

        override fun onDraw(canvas: Canvas) {
            val n = maxOf(4, count)
            val start = (width - (n - 1) * step) / 2f
            for (i in 0 until n) {
                val x = start + i * step
                if (i < count) canvas.drawCircle(x, height / 2f, r, fill)
                else canvas.drawCircle(x, height / 2f, r - ring.strokeWidth / 2, ring)
            }
        }

        /** Wrong password: a short shake (and a buzz). */
        fun shake() {
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            ObjectAnimator.ofFloat(this, "translationX", 0f, 18f, -18f, 12f, -12f, 6f, 0f).apply {
                duration = 380
                start()
            }
        }
    }

    fun column(paddingDp: Float = 24f) = LinearLayout(c).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        val p = dp(paddingDp)
        setPadding(p, p, p, p)
    }

    fun space(heightDp: Float) = View(c).apply { layoutParams = LinearLayout.LayoutParams(1, dp(heightDp)) }
}
