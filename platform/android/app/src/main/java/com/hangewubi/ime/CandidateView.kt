package com.hangewubi.ime

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import androidx.core.content.ContextCompat

class CandidateView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {

    private var ime: HangeWubiIME? = null
    private var preedit: String = ""
    private var candidates: Array<EngineBridge.Candidate> = emptyArray()

    // 候选词命中区域（矩形 + 索引）
    private val candidateRects = mutableListOf<Pair<RectF, Int>>()

    private val bgPaint = Paint().apply { style = Paint.Style.FILL }
    private val preeditPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.LEFT
        typeface = Typeface.DEFAULT_BOLD
    }
    private val candidateTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.LEFT
        typeface = Typeface.DEFAULT
    }
    private val candidateCodePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.LEFT }
    private val indexPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.LEFT }
    private val firstCandBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val separatorPaint = Paint().apply { strokeWidth = 1f }
    private val dividerPaint = Paint().apply { strokeWidth = 1f }

    // 翻页按钮
    private var prevPageRect = RectF()
    private var nextPageRect = RectF()

    init {
        refreshPalette()
    }

    fun setIME(ime: HangeWubiIME) {
        this.ime = ime
    }

    fun update(buffer: String, newCandidates: Array<EngineBridge.Candidate>) {
        preedit = buffer
        candidates = newCandidates
        requestLayout()
        invalidate()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        refreshPalette()
        invalidate()
    }

    private fun refreshPalette() {
        bgPaint.color = ContextCompat.getColor(context, R.color.candidate_bg)
        preeditPaint.color = ContextCompat.getColor(context, R.color.primary)
        candidateTextPaint.color = ContextCompat.getColor(context, R.color.key_label)
        candidateCodePaint.color = ContextCompat.getColor(context, R.color.key_sublabel)
        indexPaint.color = ContextCompat.getColor(context, R.color.key_sublabel)
        firstCandBgPaint.color = ContextCompat.getColor(context, R.color.candidate_highlight)
        separatorPaint.color = ContextCompat.getColor(context, R.color.candidate_separator)
        dividerPaint.color = ContextCompat.getColor(context, R.color.candidate_divider)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = (resources.displayMetrics.density * 44).toInt()
        setMeasuredDimension(width, height)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val h = height.toFloat()
        val w = width.toFloat()
        val density = resources.displayMetrics.density
        val textSize = density * 16f
        val smallTextSize = density * 11f
        val padding = density * 8f

        preeditPaint.textSize = textSize
        candidateTextPaint.textSize = textSize
        candidateCodePaint.textSize = smallTextSize
        indexPaint.textSize = smallTextSize

        candidateRects.clear()

        canvas.drawRect(0f, 0f, w, h, bgPaint)
        canvas.drawLine(0f, 0f, w, 0f, dividerPaint)

        var x = padding

        if (preedit.isNotEmpty()) {
            val textY = h / 2f - (preeditPaint.descent() + preeditPaint.ascent()) / 2f
            canvas.drawText(preedit, x, textY, preeditPaint)
            x += preeditPaint.measureText(preedit) + padding * 2
            canvas.drawLine(x - padding, padding, x - padding, h - padding, separatorPaint)
        }

        val navWidth = density * 40f
        val arrowSize = density * 18f
        val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.key_sublabel)
            this.textSize = arrowSize
            textAlign = Paint.Align.CENTER
        }
        val arrowY = h / 2f - (arrowPaint.descent() + arrowPaint.ascent()) / 2f

        prevPageRect.set(w - navWidth * 2, 0f, w - navWidth, h)
        nextPageRect.set(w - navWidth, 0f, w, h)

        val maxX = w - navWidth * 2 - padding

        for (i in candidates.indices) {
            if (x >= maxX) break

            val cand = candidates[i]
            val indexStr = "${i + 1}."
            val indexWidth = indexPaint.measureText(indexStr)
            val textWidth = candidateTextPaint.measureText(cand.text)
            val cellWidth = indexWidth + textWidth + padding * 2.5f

            val cellRect = RectF(x - padding / 2, 2f, x + cellWidth - padding, h - 2f)

            if (i == 0) {
                canvas.drawRoundRect(cellRect, density * 4f, density * 4f, firstCandBgPaint)
            }

            candidateRects.add(Pair(cellRect, i))

            val textY = h / 2f - (candidateTextPaint.descent() + candidateTextPaint.ascent()) / 2f

            canvas.drawText(indexStr, x, textY, indexPaint)
            x += indexWidth + padding * 0.5f

            canvas.drawText(cand.text, x, textY, candidateTextPaint)
            x += textWidth + padding * 2

            if (i < candidates.size - 1 && x < maxX) {
                canvas.drawLine(x - padding, padding, x - padding, h - padding, separatorPaint)
            }
        }

        if (candidates.isNotEmpty()) {
            canvas.drawLine(w - navWidth * 2, padding, w - navWidth * 2, h - padding, separatorPaint)
            canvas.drawText("\u25C0", prevPageRect.centerX(), arrowY, arrowPaint)
            canvas.drawText("\u25B6", nextPageRect.centerX(), arrowY, arrowPaint)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            val x = event.x
            val y = event.y

            if (prevPageRect.contains(x, y)) {
                ime?.onPrevPage()
                return true
            }
            if (nextPageRect.contains(x, y)) {
                ime?.onNextPage()
                return true
            }

            for ((rect, index) in candidateRects) {
                if (rect.contains(x, y)) {
                    ime?.onCandidateSelected(index)
                    return true
                }
            }
        }
        return true
    }
}
