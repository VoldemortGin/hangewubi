package com.hangewubi.ime

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View

class KeyboardView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {

    private var ime: HangeWubiIME? = null
    private var currentMode = 0 // 0=Chinese, 1=English, 2=TempEnglish
    private var isShifted = false
    private var showSymbols = false
    private var pressedKey: Key? = null

    // Paints
    private val keyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private val keyPressedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#D0D0D0")
        style = Paint.Style.FILL
    }
    private val specialKeyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#B0BEC5")
        style = Paint.Style.FILL
    }
    private val spaceKeyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private val enterKeyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#4CAF50")
        style = Paint.Style.FILL
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#212121")
        textAlign = Paint.Align.CENTER
        typeface = Typeface.DEFAULT
    }
    private val subtextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#757575")
        textAlign = Paint.Align.CENTER
        typeface = Typeface.DEFAULT
    }
    private val bgPaint = Paint().apply {
        color = Color.parseColor("#E0E0E0")
        style = Paint.Style.FILL
    }
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#BDBDBD")
        style = Paint.Style.FILL
    }

    private val keyRadius = 8f
    private val keyMargin = 4f

    data class Key(
        val label: String,
        val keyCode: Int,
        val rect: RectF = RectF(),
        val widthWeight: Float = 1f,
        val isSpecial: Boolean = false,
        val secondaryLabel: String? = null
    )

    // QWERTY rows
    private val qwertyRow1 = "qwertyuiop".map { c ->
        Key(c.toString(), KeyEvent.KEYCODE_A + (c - 'a'))
    }
    private val qwertyRow2 = "asdfghjkl".map { c ->
        Key(c.toString(), KeyEvent.KEYCODE_A + (c - 'a'))
    }
    private val qwertyRow3Letters = "zxcvbnm".map { c ->
        Key(c.toString(), KeyEvent.KEYCODE_A + (c - 'a'))
    }

    // Symbol keys
    private val symbolRow1 = listOf(
        Key("1", KeyEvent.KEYCODE_1), Key("2", KeyEvent.KEYCODE_2),
        Key("3", KeyEvent.KEYCODE_3), Key("4", KeyEvent.KEYCODE_4),
        Key("5", KeyEvent.KEYCODE_5), Key("6", KeyEvent.KEYCODE_6),
        Key("7", KeyEvent.KEYCODE_7), Key("8", KeyEvent.KEYCODE_8),
        Key("9", KeyEvent.KEYCODE_9), Key("0", KeyEvent.KEYCODE_0)
    )
    private val symbolRow2 = listOf(
        Key("-", KeyEvent.KEYCODE_MINUS), Key("/", KeyEvent.KEYCODE_SLASH),
        Key(":", KeyEvent.KEYCODE_SEMICOLON), Key(";", KeyEvent.KEYCODE_SEMICOLON),
        Key("(", KeyEvent.KEYCODE_NUMPAD_LEFT_PAREN),
        Key(")", KeyEvent.KEYCODE_NUMPAD_RIGHT_PAREN),
        Key(",", KeyEvent.KEYCODE_COMMA),
        Key(".", KeyEvent.KEYCODE_PERIOD),
        Key("?", KeyEvent.KEYCODE_SLASH)
    )

    // Special keys
    private val shiftKey = Key("\u21E7", KEYCODE_SHIFT, isSpecial = true, widthWeight = 1.5f)
    private val deleteKey = Key("\u232B", KeyEvent.KEYCODE_DEL, isSpecial = true, widthWeight = 1.5f)
    private val symbolToggleKey = Key("?123", KEYCODE_SYMBOL_TOGGLE, isSpecial = true, widthWeight = 1.25f)
    private val modeKey = Key("\u4E2D", KEYCODE_MODE_TOGGLE, isSpecial = true, widthWeight = 1.25f)
    private val commaKey = Key(",", KeyEvent.KEYCODE_COMMA, widthWeight = 1f)
    private val spaceKey = Key("Space", KeyEvent.KEYCODE_SPACE, widthWeight = 4f)
    private val periodKey = Key(".", KeyEvent.KEYCODE_PERIOD, widthWeight = 1f)
    private val enterKey = Key("\u21B5", KeyEvent.KEYCODE_ENTER, isSpecial = true, widthWeight = 1.25f)

    private var allKeys = mutableListOf<Key>()

    companion object {
        const val KEYCODE_SHIFT = -1
        const val KEYCODE_SYMBOL_TOGGLE = -2
        const val KEYCODE_MODE_TOGGLE = -3
    }

    fun setIME(ime: HangeWubiIME) {
        this.ime = ime
    }

    fun updateModeIndicator(mode: Int) {
        currentMode = mode
        modeKey.let {
            // We'll update the label in onDraw
        }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        // 4 rows of keys, standard keyboard height
        val rowHeight = (width * 0.135f).toInt()
        val height = rowHeight * 4 + (keyMargin * 10).toInt()
        setMeasuredDimension(width, height)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        layoutKeys()
    }

    private fun layoutKeys() {
        allKeys.clear()
        val w = width.toFloat()
        val rowCount = 4
        val rowHeight = (height.toFloat() - keyMargin * (rowCount + 1)) / rowCount
        val m = keyMargin

        textPaint.textSize = rowHeight * 0.38f
        subtextPaint.textSize = rowHeight * 0.22f

        if (showSymbols) {
            layoutRow(symbolRow1, 0f, m, w, rowHeight, m)
            layoutRow(symbolRow2, 0f, m * 2 + rowHeight, w, rowHeight, m)

            // Row 3: back to ABC + more symbols + delete
            val abcKey = Key("ABC", KEYCODE_SYMBOL_TOGGLE, isSpecial = true, widthWeight = 1.5f)
            val moreSymbols = listOf(
                Key("'", KeyEvent.KEYCODE_APOSTROPHE),
                Key("\"", KeyEvent.KEYCODE_APOSTROPHE),
                Key("=", KeyEvent.KEYCODE_EQUALS),
                Key("[", KeyEvent.KEYCODE_LEFT_BRACKET),
                Key("]", KeyEvent.KEYCODE_RIGHT_BRACKET)
            )
            val row3 = listOf(abcKey) + moreSymbols + listOf(deleteKey)
            layoutRow(row3, 0f, m * 3 + rowHeight * 2, w, rowHeight, m)

            // Row 4: mode, comma, space, period, enter
            val row4 = listOf(modeKey, commaKey, spaceKey, periodKey, enterKey)
            layoutRow(row4, 0f, m * 4 + rowHeight * 3, w, rowHeight, m)
        } else {
            // Row 1: qwertyuiop
            layoutRow(qwertyRow1, 0f, m, w, rowHeight, m)

            // Row 2: asdfghjkl (indented)
            val indent2 = w * 0.05f
            layoutRow(qwertyRow2, indent2, m * 2 + rowHeight, w - indent2 * 2, rowHeight, m)

            // Row 3: shift + zxcvbnm + delete
            val row3 = listOf(shiftKey) + qwertyRow3Letters + listOf(deleteKey)
            layoutRow(row3, 0f, m * 3 + rowHeight * 2, w, rowHeight, m)

            // Row 4: symbol toggle, mode, comma, space, period, enter
            val row4 = listOf(symbolToggleKey, modeKey, commaKey, spaceKey, periodKey, enterKey)
            layoutRow(row4, 0f, m * 4 + rowHeight * 3, w, rowHeight, m)
        }
    }

    private fun layoutRow(keys: List<Key>, startX: Float, y: Float, totalWidth: Float, rowHeight: Float, margin: Float) {
        val totalWeight = keys.sumOf { it.widthWeight.toDouble() }.toFloat()
        val usableWidth = totalWidth - margin * (keys.size + 1)
        var x = startX + margin

        for (key in keys) {
            val keyWidth = usableWidth * (key.widthWeight / totalWeight)
            key.rect.set(x, y, x + keyWidth, y + rowHeight)
            allKeys.add(key)
            x += keyWidth + margin
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        // Background
        canvas.drawColor(Color.parseColor("#D5D8DE"))

        for (key in allKeys) {
            val isPressed = key == pressedKey
            val r = key.rect

            // Key shadow
            val shadowRect = RectF(r.left, r.top + 2f, r.right, r.bottom + 2f)
            canvas.drawRoundRect(shadowRect, keyRadius, keyRadius, shadowPaint)

            // Key background
            val paint = when {
                isPressed -> keyPressedPaint
                key.keyCode == KeyEvent.KEYCODE_ENTER -> enterKeyPaint
                key.keyCode == KeyEvent.KEYCODE_SPACE -> spaceKeyPaint
                key.isSpecial -> specialKeyPaint
                else -> keyPaint
            }
            canvas.drawRoundRect(r, keyRadius, keyRadius, paint)

            // Key label
            val label = when (key.keyCode) {
                KEYCODE_MODE_TOGGLE -> when (currentMode) {
                    0 -> "\u4E2D"  // 中
                    1 -> "EN"
                    2 -> "en"
                    else -> "\u4E2D"
                }
                KEYCODE_SYMBOL_TOGGLE -> if (showSymbols) "ABC" else "?123"
                else -> {
                    if (isShifted && key.label.length == 1 && key.label[0].isLetter()) {
                        key.label.uppercase()
                    } else {
                        key.label
                    }
                }
            }

            val tp = if (key.keyCode == KeyEvent.KEYCODE_ENTER) {
                Paint(textPaint).apply { color = Color.WHITE }
            } else {
                textPaint
            }

            val textY = r.centerY() - (tp.descent() + tp.ascent()) / 2
            canvas.drawText(label, r.centerX(), textY, tp)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                pressedKey = findKey(event.x, event.y)
                invalidate()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val newKey = findKey(event.x, event.y)
                if (newKey != pressedKey) {
                    pressedKey = newKey
                    invalidate()
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                val key = findKey(event.x, event.y)
                pressedKey = null
                invalidate()
                if (key != null) {
                    handleKeyPress(key)
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                pressedKey = null
                invalidate()
                return true
            }
        }
        return false
    }

    private fun findKey(x: Float, y: Float): Key? {
        return allKeys.firstOrNull { it.rect.contains(x, y) }
    }

    private fun handleKeyPress(key: Key) {
        when (key.keyCode) {
            KEYCODE_SHIFT -> {
                isShifted = !isShifted
                invalidate()
            }
            KEYCODE_SYMBOL_TOGGLE -> {
                showSymbols = !showSymbols
                layoutKeys()
                invalidate()
            }
            KEYCODE_MODE_TOGGLE -> {
                ime?.onToggleMode()
            }
            else -> {
                ime?.onKeyPress(key.keyCode)
                if (isShifted) {
                    isShifted = false
                    invalidate()
                }
            }
        }
    }
}
