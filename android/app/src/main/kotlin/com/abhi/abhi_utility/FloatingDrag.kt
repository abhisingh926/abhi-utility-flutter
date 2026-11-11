package com.abhi.abhi_utility

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.TextView
import kotlin.math.hypot

/**
 * Makes a floating overlay (download button, reel counter) behave like a chat head:
 * drag it anywhere, it snaps to the nearest side and remembers where it was; drag it
 * onto the ✕ at the bottom to remove it. A tap without moving calls [onTap].
 *
 * The position is saved per [key] as a side (left / right) and a height, so a view
 * whose width changes (the reel counter grows after each reel) stays on screen.
 */
class FloatingDrag(
    private val context: Context,
    private val wm: WindowManager,
    private val view: View,
    private val params: WindowManager.LayoutParams,
    private val key: String,
    private val onTap: () -> Unit,
    private val onRemove: () -> Unit,
) : View.OnTouchListener {

    companion object {
        private const val PREFS = "floating"
        private const val MARGIN_DP = 8f

        private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun dp(c: Context, v: Float) =
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.resources.displayMetrics).toInt()

        /** Puts [params] where the view [key] was left (or on the right at [defaultY]). */
        fun place(c: Context, params: WindowManager.LayoutParams, key: String, defaultY: Int) {
            val p = prefs(c)
            val left = p.getBoolean("${key}_left", false)
            params.gravity = Gravity.TOP or (if (left) Gravity.START else Gravity.END)
            params.x = dp(c, MARGIN_DP)
            params.y = p.getInt("${key}_y", defaultY)
        }
    }

    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val margin = dp(context, MARGIN_DP)

    private var downRawX = 0f
    private var downRawY = 0f
    private var startX = 0
    private var startY = 0
    private var dragging = false
    private var overTarget = false
    private var target: TextView? = null
    private var snap: ValueAnimator? = null

    private fun screen(): Pair<Int, Int> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            wm.currentWindowMetrics.bounds.let { it.width() to it.height() }
        } else {
            context.resources.displayMetrics.let { it.widthPixels to it.heightPixels }
        }

    /** Left edge of the view in screen pixels, whichever side it is anchored to. */
    private fun absoluteX(): Int {
        val (w, _) = screen()
        return if (params.gravity and Gravity.HORIZONTAL_GRAVITY_MASK == Gravity.END ||
            params.gravity and Gravity.HORIZONTAL_GRAVITY_MASK == Gravity.RIGHT
        ) w - params.x - view.width else params.x
    }

    override fun onTouch(v: View, e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                snap?.cancel()
                downRawX = e.rawX
                downRawY = e.rawY
                startX = absoluteX()
                startY = params.y
                dragging = false
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = e.rawX - downRawX
                val dy = e.rawY - downRawY
                if (!dragging && hypot(dx, dy) > slop) {
                    dragging = true
                    // Free movement while dragging: anchor to the left edge.
                    params.gravity = Gravity.TOP or Gravity.START
                    showTarget()
                }
                if (dragging) {
                    val (w, h) = screen()
                    params.x = (startX + dx).toInt().coerceIn(0, (w - view.width).coerceAtLeast(0))
                    params.y = (startY + dy).toInt().coerceIn(0, (h - view.height).coerceAtLeast(0))
                    update()
                    setOverTarget(isOverTarget())
                }
            }
            MotionEvent.ACTION_UP -> {
                if (!dragging) {
                    v.performClick()
                    onTap()
                } else {
                    finishDrag()
                }
            }
            MotionEvent.ACTION_CANCEL -> if (dragging) finishDrag()
        }
        return true
    }

    private fun finishDrag() {
        dragging = false
        val remove = overTarget
        hideTarget()
        if (remove) {
            onRemove()
            return
        }
        // Snap to the nearer side, then anchor there (so a wider counter grows inwards).
        val (w, _) = screen()
        val left = params.x + view.width / 2 < w / 2
        val endX = if (left) margin else w - view.width - margin
        snap = ValueAnimator.ofInt(params.x, endX).apply {
            duration = 180
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                params.x = it.animatedValue as Int
                update()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    params.gravity = Gravity.TOP or (if (left) Gravity.START else Gravity.END)
                    params.x = margin
                    update()
                }
            })
            start()
        }
        prefs(context).edit().putBoolean("${key}_left", left).putInt("${key}_y", params.y).apply()
    }

    private fun update() {
        try {
            if (view.isAttachedToWindow) wm.updateViewLayout(view, params)
        } catch (_: Exception) {
        }
    }

    // ---- The ✕ drop target ---------------------------------------------------------

    private val targetSize get() = dp(context, 60f)
    private val targetBottom get() = dp(context, 56f)

    private fun isOverTarget(): Boolean {
        val (w, h) = screen()
        val cx = w / 2f
        val cy = h - targetBottom - targetSize / 2f
        val vx = params.x + view.width / 2f
        val vy = params.y + view.height / 2f
        return hypot(vx - cx, vy - cy) < dp(context, 72f)
    }

    private fun setOverTarget(over: Boolean) {
        if (over == overTarget) return
        overTarget = over
        target?.let {
            it.animate().scaleX(if (over) 1.3f else 1f).scaleY(if (over) 1.3f else 1f).setDuration(120).start()
            (it.background as? GradientDrawable)?.setColor(
                if (over) Color.argb(235, 220, 40, 40) else Color.argb(200, 30, 30, 30)
            )
        }
        if (over) view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
    }

    private fun showTarget() {
        if (target != null) return
        val t = TextView(context).apply {
            text = "✕"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(200, 30, 30, 30))
                setStroke(dp(context, 2f), Color.WHITE)
            }
            contentDescription = "Drop here to remove"
        }
        val p = WindowManager.LayoutParams(
            targetSize, targetSize,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = targetBottom
        }
        try {
            wm.addView(t, p)
            target = t
        } catch (_: Exception) {
        }
    }

    private fun hideTarget() {
        overTarget = false
        target?.let {
            try {
                wm.removeView(it)
            } catch (_: Exception) {
            }
        }
        target = null
    }

    /** The view is going away (app left, video stopped): drop the ✕ and any animation. */
    fun cancel() {
        snap?.cancel()
        dragging = false
        hideTarget()
    }
}
