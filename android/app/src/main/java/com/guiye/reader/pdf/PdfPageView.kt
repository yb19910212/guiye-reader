package com.guiye.reader.pdf

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.view.View
import java.io.File

class PdfPageView(context: Context, file: File) : View(context) {
    private val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = PdfRenderer(descriptor)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private var bitmap: Bitmap? = null
    private var requestedPage = 0
    val pageCount: Int get() = renderer.pageCount

    init { setBackgroundColor(Color.rgb(232, 230, 224)) }

    fun showPage(index: Int) {
        val safe = index.coerceIn(0, (pageCount - 1).coerceAtLeast(0))
        if (safe == requestedPage && bitmap != null) return
        requestedPage = safe
        if (width > 0 && height > 0) renderPage()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w > 0 && h > 0) renderPage()
    }

    private fun renderPage() {
        if (pageCount == 0 || width <= 0 || height <= 0) return
        renderer.openPage(requestedPage).use { page ->
            val scale = minOf(width.toFloat() / page.width, height.toFloat() / page.height)
            val targetWidth = (page.width * scale).toInt().coerceAtLeast(1)
            val targetHeight = (page.height * scale).toInt().coerceAtLeast(1)
            bitmap?.recycle()
            bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888).also {
                it.eraseColor(Color.WHITE)
                page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            }
        }
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        bitmap?.let { image -> canvas.drawBitmap(image, (width - image.width) / 2f, (height - image.height) / 2f, paint) }
    }

    override fun onDetachedFromWindow() {
        bitmap?.recycle(); bitmap = null
        renderer.close(); descriptor.close()
        super.onDetachedFromWindow()
    }
}
