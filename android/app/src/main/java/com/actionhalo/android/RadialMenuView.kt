package com.actionhalo.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.os.Build
import android.text.SpannableString
import android.text.Spanned
import android.text.TextUtils
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.KeyEvent
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.hypot
import kotlin.math.sqrt
import java.util.Locale

/**
 * A self-contained, permission-free action surface, usable in an Activity or service window.
 * Every action is also a real Button for TalkBack, switch access, and keyboard activation.
 */
class RadialMenuView(context: Context) : FrameLayout(context) {
    /** The same weapon-wheel presentation as the desktop's default GTA mode. */
    var gtaModeEnabled: Boolean = true
        set(value) {
            if (field == value) return
            field = value
            cancelGesture()
            updateActionColors()
            updateCenterLabel()
            requestLayout()
            invalidate()
        }

    var selectedText: String = ""
        set(value) {
            field = value
            updateActionAvailability()
            updatePresentation()
        }

    /** Compatibility menus obtain text only after an explicit action; unknown is not a non-link. */
    var selectionTextKnown: Boolean = true
        set(value) {
            field = value
            updateActionAvailability()
            updatePresentation()
        }

    var onActionSelected: ((HaloAction) -> Unit)? = null
    var onDismiss: (() -> Unit)? = null
    internal var onSourceAppOptions: (() -> Unit)? = null
        set(value) { field = value; sourceOptions.visibility = if (value == null) GONE else VISIBLE; requestLayout() }
    private var inlinePanel: View? = null
    private val clearFeedback = Runnable { showOperationStatus(null) }
    internal var onInteractionStarted: (() -> Unit)? = null
    /** A service window can resize during DOWN, before Android updates child screen coordinates. */
    internal var screenOriginForAnchor: (() -> Pair<Float, Float>)? = null

    private var allActions: List<HaloAction> = emptyList()
    private var actions: List<HaloAction> = emptyList()
    private var page = 0
    private var actionsPerPage = HaloAppearance.actionsPerPage(context)
    private val pageCount get() = (allActions.size + actionsPerPage - 1) / actionsPerPage
    private val actionButtons = mutableListOf<IconButton>()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val slotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create("monospace", Typeface.BOLD)
        textAlign = Paint.Align.CENTER
    }
    private var gtaIconRadius = 0f
    private val circleBounds = RectF()
    private val innerBounds = RectF()
    private val sectorPaths = mutableListOf<Path>()
    private var slotPositions = emptyList<Pair<Float, Float>>()
    private var slotLabels = emptyList<String>()
    private var geometry: RadialGeometry? = null
    private var highlightedIndex = -1
    private var trackingGesture = false
    private var actionCommitted = false
    private var activePointerId = MotionEvent.INVALID_POINTER_ID
    private var pagingGesture = false
    private var pressedPageButton: Button? = null
    private var touchSurfaceBound = false
    private var touchAnchorSet = false
    private var constrainedAnchorPress = false
    private var anchorPressX = 0f
    private var anchorPressY = 0f
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var compactLayout = false
    private var interactionStarted = false
    private var compactHeaderHeight = 0
    private var compactFooterHeight = 0
    private val pagerBounds = RectF()
    private var previewWidth = dp(105f)
    private var flashIndex = -1
    private var actionError: String? = null
    private var operationStatus: String? = null
    private val clearActionError = Runnable { actionError = null; updateCenterLabel() }
    private val clearFlash = Runnable { flashIndex = -1; invalidate() }
    private val centerButton = createButton().apply {
        setTextColor(TEXT_PRIMARY)
        setOnClickListener { onDismiss?.invoke() }
        setOnFocusChangeListener { _, _ -> updatePresentation() }
    }
    private val previousPage = createButton().apply {
        text = "‹"
        textSize = 30f
        contentDescription = context.getString(R.string.radial_previous_page)
        setOnClickListener { changePage(page - 1) }
    }
    private val nextPage = createButton().apply {
        text = "›"
        textSize = 30f
        contentDescription = context.getString(R.string.radial_next_page)
        setOnClickListener { changePage(page + 1) }
    }
    private val sourceOptions = createButton().apply {
        text = "⋮"
        textSize = 26f
        visibility = GONE
        contentDescription = context.getString(R.string.source_app_options)
        setOnClickListener { onSourceAppOptions?.invoke() }
    }
    private val pageLabel = TextView(context).apply {
        gravity = android.view.Gravity.CENTER
        textSize = 13f
        setTextColor(TEXT_PRIMARY)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }

    init {
        setWillNotDraw(false)
        clipChildren = false
        clipToPadding = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        descendantFocusability = FOCUS_AFTER_DESCENDANTS
        if (Build.VERSION.SDK_INT >= 28) {
            accessibilityPaneTitle = context.getString(R.string.radial_accessibility_menu)
        }
        addView(centerButton)
        addView(previousPage)
        addView(pageLabel)
        addView(nextPage)
        addView(sourceOptions)
        updatePager()
        updateCenterLabel()
    }

    fun setActions(actions: List<HaloAction>) {
        allActions = actions.toList()
        actionsPerPage = effectivePageSize(width, height)
        page = 0
        actionCommitted = false
        showPage()
    }

    /** Accept gestures across the host; only a first press outside the wheel moves it. */
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    fun bindTouchSurface(surface: View) {
        touchSurfaceBound = true
        surface.setOnTouchListener { _, event ->
            val surfaceOrigin = IntArray(2)
            val menuOrigin = IntArray(2)
            surface.getLocationOnScreen(surfaceOrigin)
            getLocationOnScreen(menuOrigin)
            val translated = MotionEvent.obtain(event).apply {
                offsetLocation((surfaceOrigin[0] - menuOrigin[0]).toFloat(),
                    (surfaceOrigin[1] - menuOrigin[1]).toFloat())
            }
            try { dispatchTouchEvent(translated) } finally { translated.recycle() }
        }
    }

    private fun changePage(target: Int) {
        if (actionCommitted || target !in 0 until pageCount || target == page) return
        page = target
        showPage()
    }

    private fun showPage() {
        cancelGesture()
        removeCallbacks(clearFlash)
        flashIndex = -1
        actionButtons.forEach(::removeView)
        actionButtons.clear()
        actions = allActions.drop(page * actionsPerPage).take(actionsPerPage)
        slotLabels = actions.indices.map { String.format(Locale.ROOT, "%02d", page * actionsPerPage + it + 1) }
        actions.forEachIndexed { index, action ->
            val button = createButton(context.getDrawable(ActionIcons.resource(action))?.mutate()).apply {
                contentDescription = action.title
                tooltipText = action.title
                setOnClickListener {
                    if (actionButtons.getOrNull(index) === this) activateAction(index)
                }
                setOnFocusChangeListener { _, _ -> updatePresentation() }
            }
            actionButtons += button
            addView(button)
        }
        updatePager()
        updateActionAvailability()
        updateActionColors()
        updateCenterLabel()
        requestLayout()
        invalidate()
    }

    private fun updatePager() {
        val show = pageCount > 1
        listOf(previousPage, pageLabel, nextPage).forEach { it.visibility = if (show) VISIBLE else GONE }
        previousPage.isEnabled = page > 0
        nextPage.isEnabled = page + 1 < pageCount
        previousPage.alpha = if (previousPage.isEnabled) 1f else 0.3f
        nextPage.alpha = if (nextPage.isEnabled) 1f else 0.3f
        pageLabel.text = context.getString(R.string.radial_page_label, page + 1, pageCount)
        pageLabel.contentDescription = context.getString(R.string.radial_page_description, page + 1, pageCount)
    }

    // The app uses the framework Material theme and draws its own icon tint.
    @android.annotation.SuppressLint("AppCompatCustomView")
    private class IconButton(context: Context, val icon: Drawable?) : Button(context) {
        var iconSize = 0
            set(value) {
                if (field == value) return
                field = value
                iconShadow?.recycle()
                iconShadow = null
            }
        private var iconShadow: Bitmap? = null
        private val shadowOffset = IntArray(2)
        private val shadowMaskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            maskFilter = BlurMaskFilter(5f * resources.displayMetrics.density, BlurMaskFilter.Blur.NORMAL)
        }
        private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK }

        fun drawIconShadow(canvas: Canvas) {
            val drawable = icon ?: return
            if (iconSize <= 0 || visibility != View.VISIBLE) return
            val shadow = iconShadow ?: run {
                // Cache the software blur once; dragging only draws the existing alpha mask.
                val source = Bitmap.createBitmap(iconSize, iconSize, Bitmap.Config.ARGB_8888)
                drawable.setBounds(0, 0, iconSize, iconSize)
                drawable.draw(Canvas(source))
                source.extractAlpha(shadowMaskPaint, shadowOffset).also {
                    it.density = Bitmap.DENSITY_NONE
                    iconShadow = it
                    source.recycle()
                }
            }
            shadowPaint.alpha = (230f * alpha).toInt()
            canvas.save()
            canvas.translate(left + width / 2f, top + height / 2f)
            canvas.scale(scaleX, scaleY)
            canvas.drawBitmap(shadow, -iconSize / 2f + shadowOffset[0], -iconSize / 2f + shadowOffset[1], shadowPaint)
            canvas.restore()
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            icon?.let {
                val left = (width - iconSize) / 2
                val top = (height - iconSize) / 2
                it.setBounds(left, top, left + iconSize, top + iconSize)
                it.draw(canvas)
            }
        }

        override fun onDetachedFromWindow() {
            iconShadow?.recycle()
            iconShadow = null
            super.onDetachedFromWindow()
        }
    }

    private fun createButton(icon: Drawable? = null) = IconButton(context, icon).apply {
        background = null
        stateListAnimator = null
        setPadding(0, 0, 0, 0)
        minWidth = 0
        minHeight = 0
        minimumWidth = 0
        minimumHeight = 0
        isAllCaps = false
        gravity = android.view.Gravity.CENTER
        typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
        setTextColor(TEXT_PRIMARY)
        setLineSpacing(dp(2f), 1f)
        maxLines = 3
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        isFocusable = true
        isClickable = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    private fun updateCenterLabel() {
        operationStatus?.let { message ->
            centerButton.text = message
            centerButton.textSize = if (compactLayout) 10f else 12f
            centerButton.maxLines = if (compactLayout) 2 else 4
            centerButton.contentDescription = "$message. ${context.getString(R.string.radial_close_menu)}"
            return
        }
        actionError?.let { message ->
            centerButton.text = message
            centerButton.textSize = 11f
            centerButton.maxLines = if (compactLayout) 2 else 5
            centerButton.contentDescription = "$message. ${context.getString(R.string.radial_close_menu)}"
            return
        }
        val compactText = selectedText.replace(Regex("\\s+"), " ").trim()
        if (compactLayout) {
            centerButton.text = actions.getOrNull(activeIndex())?.title
                ?: context.getString(R.string.radial_compact_close)
            centerButton.textSize = 11f
            centerButton.maxLines = 2
            centerButton.contentDescription = context.getString(R.string.radial_close_menu)
            centerButton.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT)
            return
        }
        if (gtaModeEnabled) {
            val active = activeIndex()
            val title = actions.getOrNull(active)?.title ?: "ActionHalo"
            val hint = if (active >= 0) "SLOT ${slotLabels[active]}  READY" else "HOLD AND RELEASE"
            centerButton.textSize = 15f
            centerButton.maxLines = 4
            centerButton.typeface = Typeface.create("sans-serif-black", Typeface.NORMAL)
            centerButton.text = SpannableString("$title\n$hint").apply {
                setSpan(ForegroundColorSpan(Color.WHITE), 0, title.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(RelativeSizeSpan(2f / 3f), title.length + 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(android.text.style.TypefaceSpan("monospace"), title.length + 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(ForegroundColorSpan(if (active >= 0) GTA_SUBTITLE_ACTIVE else GTA_SUBTITLE), title.length + 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            centerButton.setShadowLayer(dp(8f), 0f, 0f, Color.BLACK)
        } else {
            val active = actions.getOrNull(activeIndex())
            val preview = if (compactText.isEmpty()) {
                context.getString(R.string.radial_choose_action)
            } else {
                TextUtils.ellipsize(compactText.take(160), android.text.TextPaint().apply { textSize = sp(11f) }, previewWidth, TextUtils.TruncateAt.END).toString()
            }
            val brand = "ActionHalo"
            val hint = context.getString(R.string.radial_tap_to_close)
            centerButton.textSize = if (active == null) 11f else 12f
            centerButton.maxLines = if (active == null) 3 else 4
            centerButton.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            centerButton.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT)
            centerButton.text = if (active != null) SpannableString(active.title).apply {
                setSpan(ForegroundColorSpan(ACCENT), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            } else SpannableString("$brand\n$preview\n$hint").apply {
                setSpan(RelativeSizeSpan(14f / 11f), 0, brand.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(ForegroundColorSpan(ACCENT), 0, brand.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(RelativeSizeSpan(10f / 11f), length - hint.length, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(ForegroundColorSpan(TEXT_SECONDARY), brand.length + 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        centerButton.contentDescription = if (compactText.isEmpty()) {
            context.getString(R.string.radial_close_menu)
        } else {
            context.getString(R.string.radial_close_menu_with_selection, compactText.take(200))
        }
    }

    // One immutable geometry value per measure pass; drawing/dragging never reallocates it.
    @android.annotation.SuppressLint("DrawAllocation")
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val preferred = dp(HaloAppearance.menuSizeDp(context).toFloat()).toInt()
        val measuredWidth = resolveSize(preferred, widthMeasureSpec)
        val measuredHeight = resolveSize(preferred, heightMeasureSpec)
        setMeasuredDimension(measuredWidth, measuredHeight)
        inlinePanel?.let { it.measure(exactly(measuredWidth), exactly(measuredHeight)); return }
        sourceOptions.measure(exactly(dp(48f).toInt()), exactly(dp(48f).toInt()))
        if (!interactionStarted) {
            val nextCount = effectivePageSize(measuredWidth, measuredHeight)
            val nextCompact = min(measuredWidth, measuredHeight) < dp(240f)
            if (nextCount != actionsPerPage || nextCompact != compactLayout) {
                val firstIndex = page * actionsPerPage
                actionsPerPage = nextCount
                compactLayout = nextCompact
                page = (firstIndex / nextCount).coerceAtMost((pageCount - 1).coerceAtLeast(0))
                showPage()
            }
        }
        if (compactLayout) {
            measureCompact(measuredWidth, measuredHeight)
            return
        }
        val diameter = min(measuredWidth - paddingLeft - paddingRight, measuredHeight - paddingTop - paddingBottom).coerceAtLeast(1)
        val outerRadius = (diameter / 2f - dp(60f)).coerceAtLeast(diameter * 0.25f)
        val innerRadius = outerRadius * if (gtaModeEnabled) 0.5f else 85f / 130f
        slotPaint.textSize = sp(10f)
        val slotHeight = slotPaint.descent() - slotPaint.ascent()
        geometry = RadialGeometry(
            paddingLeft + (measuredWidth - paddingLeft - paddingRight) / 2f,
            paddingTop + (measuredHeight - paddingTop - paddingBottom) / 2f,
            innerRadius,
            outerRadius,
            actions.size,
            gtaModeEnabled,
            resources.displayMetrics.density,
        )
        val availableArcWidth = if (actions.size <= 2) diameter * 0.30f else {
            val radius = (outerRadius + innerRadius) / 2f
            (2f * radius * sin(Math.PI / actions.size).toFloat() * 0.85f)
        }
        val buttonWidth = min(dp(48f), availableArcWidth).toInt()
        val buttonHeight = dp(48f).toInt()
        val centerSize = (innerRadius * if (gtaModeEnabled) 1.7f else 1.62f).toInt()
        val resizedPreviewWidth = min(dp(105f), (centerSize - dp(6f)).coerceAtLeast(1f))
        if (previewWidth != resizedPreviewWidth) {
            previewWidth = resizedPreviewWidth
            updateCenterLabel()
        }
        centerButton.measure(exactly(centerSize), exactly(centerSize))
        actionButtons.forEach { button ->
            val ringLimit = if (gtaModeEnabled) {
                // Reserve separate bands for the number and the largest selected icon square.
                (outerRadius - innerRadius - slotHeight - dp(8f)) / (GTA_SELECTION_SCALE * sqrt(2f))
            } else Float.POSITIVE_INFINITY
            button.iconSize = minOf(dp(ActionIcons.sizeDp(actions.size)),
                min(buttonWidth, buttonHeight) - dp(2f), ringLimit).coerceAtLeast(1f).toInt()
            button.measure(exactly(buttonWidth), exactly(buttonHeight))
        }
        gtaIconRadius = outerRadius - (actionButtons.firstOrNull()?.iconSize ?: 0) * GTA_SELECTION_SCALE * sqrt(2f) / 2f - dp(2f)
        rebuildSectorPaths()
        previousPage.measure(exactly(dp(48f).toInt()), exactly(dp(48f).toInt()))
        nextPage.measure(exactly(dp(48f).toInt()), exactly(dp(48f).toInt()))
        pageLabel.measure(exactly(dp(72f).toInt()), exactly(dp(48f).toInt()))
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        inlinePanel?.let { it.layout(0, 0, width, height); return }
        layoutAt(sourceOptions, width - dp(28f), dp(28f))
        if (compactLayout) {
            layoutCompact()
            return
        }
        val layout = geometry ?: return
        layoutAt(centerButton, layout.centerX, layout.centerY)
        actionButtons.forEachIndexed { index, button ->
            val (x, y) = if (gtaModeEnabled) layout.pointAt(index, gtaIconRadius) else layout.actionCenter(index)
            layoutAt(button, x, y)
        }
        val pagerY = height - paddingBottom - dp(28f)
        layoutAt(previousPage, layout.centerX - dp(60f), pagerY)
        layoutAt(pageLabel, layout.centerX, pagerY)
        layoutAt(nextPage, layout.centerX + dp(60f), pagerY)
        pagerBounds.set(previousPage.left.toFloat(), previousPage.top.toFloat(), nextPage.right.toFloat(), nextPage.bottom.toFloat())
    }

    private fun layoutAt(view: View, centerX: Float, centerY: Float) {
        val left = (centerX - view.measuredWidth / 2f).toInt()
        val top = (centerY - view.measuredHeight / 2f).toInt()
        view.layout(left, top, left + view.measuredWidth, top + view.measuredHeight)
    }

    private fun effectivePageSize(availableWidth: Int, availableHeight: Int): Int {
        val configured = HaloAppearance.actionsPerPage(context)
        if (availableWidth <= 0 || availableHeight <= 0 || min(availableWidth, availableHeight) >= dp(240f)) return configured
        return minOf(configured, if (availableHeight < dp(208f)) 2 else 4)
    }

    private fun measureCompact(availableWidth: Int, availableHeight: Int) {
        geometry = null
        val contentWidth = (availableWidth - paddingLeft - paddingRight - dp(16f)).toInt().coerceAtLeast(1)
        compactHeaderHeight = minOf(dp(36f).toInt(), availableHeight / 4).coerceAtLeast(1)
        compactFooterHeight = if (pageCount > 1) minOf(dp(40f).toInt(), availableHeight / 4).coerceAtLeast(1) else 0
        val rows = if (actionsPerPage > 2) 2 else 1
        val cellWidth = ((contentWidth - dp(8f)) / 2f).toInt().coerceAtLeast(1)
        val cellHeight = ((availableHeight - paddingTop - paddingBottom - compactHeaderHeight - compactFooterHeight - dp(16f)) / rows).toInt().coerceAtLeast(1)
        centerButton.measure(exactly((contentWidth - if (sourceOptions.visibility == VISIBLE) dp(48f).toInt() else 0).coerceAtLeast(1)), exactly(compactHeaderHeight))
        actionButtons.forEach { button ->
            button.iconSize = minOf(dp(30f).toInt(), cellWidth - dp(28f).toInt(), cellHeight - dp(12f).toInt()).coerceAtLeast(1)
            button.measure(exactly(cellWidth), exactly(cellHeight))
        }
        val footerButtonWidth = minOf(dp(48f).toInt(), contentWidth / 3).coerceAtLeast(1)
        previousPage.measure(exactly(footerButtonWidth), exactly(compactFooterHeight))
        nextPage.measure(exactly(footerButtonWidth), exactly(compactFooterHeight))
        pageLabel.measure(exactly((contentWidth - 2 * footerButtonWidth).coerceAtLeast(1)), exactly(compactFooterHeight))
        slotPaint.textSize = sp(9f)
        updateCenterLabel()
    }

    private fun layoutCompact() {
        val startX = paddingLeft + dp(8f)
        val startY = paddingTop + dp(4f)
        layoutAt(centerButton, width / 2f - if (sourceOptions.visibility == VISIBLE) dp(24f) else 0f, startY + compactHeaderHeight / 2f)
        layoutAt(sourceOptions, width - paddingRight - dp(28f), startY + compactHeaderHeight / 2f)
        actionButtons.forEachIndexed { index, button ->
            val column = index % 2
            val row = index / 2
            val x = startX + column * (button.measuredWidth + dp(8f)) + button.measuredWidth / 2f
            val y = centerButton.bottom + dp(4f) + row * (button.measuredHeight + dp(4f)) + button.measuredHeight / 2f
            layoutAt(button, x, y)
        }
        val footerY = height - paddingBottom - compactFooterHeight / 2f
        layoutAt(previousPage, startX + previousPage.measuredWidth / 2f, footerY)
        layoutAt(pageLabel, width / 2f, footerY)
        layoutAt(nextPage, width - paddingRight - dp(8f) - nextPage.measuredWidth / 2f, footerY)
        pagerBounds.set(previousPage.left.toFloat(), previousPage.top.toFloat(), nextPage.right.toFloat(), nextPage.bottom.toFloat())
    }

    private fun drawCompact(canvas: Canvas) {
        paint.style = Paint.Style.FILL
        paint.color = SURFACE
        canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), dp(16f), dp(16f), paint)
        actionButtons.forEachIndexed { index, button ->
            val active = index == activeIndex()
            paint.color = if (active) ACCENT else RING
            paint.alpha = if (button.isEnabled) 255 else 70
            canvas.drawRoundRect(button.left.toFloat(), button.top.toFloat(), button.right.toFloat(), button.bottom.toFloat(), dp(8f), dp(8f), paint)
            if (gtaModeEnabled) {
                slotPaint.color = if (button.isEnabled) TEXT_SECONDARY else BORDER
                canvas.drawText(slotLabels[index], button.left + dp(11f),
                    (button.top + button.bottom) / 2f - (slotPaint.ascent() + slotPaint.descent()) / 2f, slotPaint)
            }
        }
    }

    private fun safeAnchorShift(x: Float, y: Float): Pair<Float, Float> {
        val layout = geometry ?: return 0f to 0f
        val visible = Rect().also(::getWindowVisibleDisplayFrame)
        if (visible.isEmpty) return 0f to 0f
        val origin = screenOriginForAnchor?.invoke() ?: IntArray(2).also(::getLocationOnScreen).let { it[0].toFloat() to it[1].toFloat() }
        val content = RectF(layout.centerX - layout.outerRadius - dp(8f), layout.centerY - layout.outerRadius - dp(8f),
            layout.centerX + layout.outerRadius + dp(8f), layout.centerY + layout.outerRadius + dp(8f))
        if (pageCount > 1) content.union(pagerBounds)
        if (sourceOptions.visibility == VISIBLE) content.union(RectF(sourceOptions.left.toFloat(), sourceOptions.top.toFloat(), sourceOptions.right.toFloat(), sourceOptions.bottom.toFloat()))
        content.offset(origin.first, origin.second)
        return HaloSafeArea.fittedShift(visible, content, x, y, dp(4f))
    }

    override fun onDraw(canvas: Canvas) {
        if (inlinePanel != null) return
        if (compactLayout) {
            drawCompact(canvas)
            return
        }
        super.onDraw(canvas)
        val layout = geometry ?: return
        if (pageCount > 1) {
            paint.style = Paint.Style.FILL
            paint.color = if (gtaModeEnabled) GTA_CORE else SURFACE
            canvas.drawRoundRect(pagerBounds, dp(24f), dp(24f), paint)
        }
        if (gtaModeEnabled) {
            drawGtaWheel(canvas, layout)
            return
        }
        paint.style = Paint.Style.FILL
        paint.color = SURFACE
        canvas.drawCircle(layout.centerX, layout.centerY, layout.outerRadius + dp(2f), paint)
        val radius = (layout.innerRadius + layout.outerRadius) / 2f
        circleBounds.set(layout.centerX - radius, layout.centerY - radius, layout.centerX + radius, layout.centerY + radius)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = layout.outerRadius - layout.innerRadius
        paint.strokeCap = Paint.Cap.BUTT
        actions.indices.forEach { index ->
            val selected = index == highlightedIndex || actionButtons[index].isFocused
            paint.color = if (selected) ACCENT else RING
            val gap = if (actions.size > 1) 2.5f else 0f
            canvas.drawArc(circleBounds, layout.sectorStartDegrees(index) + gap / 2f, layout.sweepDegrees - gap, false, paint)
        }
        paint.style = Paint.Style.FILL
        paint.color = SURFACE
        canvas.drawCircle(layout.centerX, layout.centerY, layout.innerRadius - dp(3f), paint)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = dp(1f)
        paint.color = if (centerButton.isFocused) ACCENT else BORDER
        canvas.drawCircle(layout.centerX, layout.centerY, layout.innerRadius - dp(4f), paint)
        paint.color = BORDER
        canvas.drawCircle(layout.centerX, layout.centerY, layout.outerRadius + dp(1f), paint)
    }

    // Intercept the physical gesture so dragging across children never triggers two actions.
    // Accessibility and keyboard activation still invoke each child's normal click listener.
    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = inlinePanel == null

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (inlinePanel != null) {
            if (event.actionMasked == MotionEvent.ACTION_UP && (event.x < 0 || event.y < 0 || event.x > width || event.y > height)) onDismiss?.invoke()
            return true
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                interactionStarted = true
                onInteractionStarted?.invoke()
                activePointerId = event.getPointerId(0)
                trackingGesture = true
                parent?.requestDisallowInterceptTouchEvent(true)
                pagingGesture = isOverPager(event.x, event.y)
                pressedPageButton = if (pagingGesture) pageButtonAt(event.x, event.y) else null
                pressedPageButton?.isPressed = true
                if (pressedPageButton === sourceOptions) touchAnchorSet = true
                if (!pagingGesture) {
                    val layout = geometry
                    if (touchSurfaceBound && !touchAnchorSet && !actionCommitted && layout != null &&
                        event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) && event.x.isFinite() && event.y.isFinite()
                    ) {
                        // Keep visible targets under the finger; blank space provides a new center.
                        if (!compactLayout && hypot(event.x - layout.centerX, event.y - layout.centerY) > layout.outerRadius) {
                            val requestedX = event.x - layout.centerX
                            val requestedY = event.y - layout.centerY
                            val shift = safeAnchorShift(requestedX, requestedY)
                            translationX += shift.first
                            translationY += shift.second
                            constrainedAnchorPress = kotlin.math.abs(requestedX - shift.first) > 1f || kotlin.math.abs(requestedY - shift.second) > 1f
                            anchorPressX = event.x - shift.first
                            anchorPressY = event.y - shift.second
                            highlight(layout.centerX, layout.centerY)
                        } else highlight(event.x, event.y)
                        // Later presses keep the center reachable for dismissal, even after cancellation or paging.
                        touchAnchorSet = true
                    } else highlight(event.x, event.y)
                }
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (!trackingGesture) return false
                val pointerIndex = event.findPointerIndex(activePointerId)
                if (pointerIndex < 0) cancelGesture()
                else if (pagingGesture) {
                    pressedPageButton?.isPressed = pageButtonAt(event.getX(pointerIndex), event.getY(pointerIndex)) === pressedPageButton
                } else {
                    val x = event.getX(pointerIndex)
                    val y = event.getY(pointerIndex)
                    if (constrainedAnchorPress && hypot(x - anchorPressX, y - anchorPressY) > touchSlop) constrainedAnchorPress = false
                    if (!constrainedAnchorPress) highlight(x, y, stable = true)
                }
                return true
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                // A second finger is an interrupted gesture, never a second selection.
                cancelGesture()
                return true
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (event.getPointerId(event.actionIndex) == activePointerId) cancelGesture()
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (!trackingGesture) return true
                val pointerIndex = event.findPointerIndex(activePointerId)
                if (pagingGesture) {
                    val button = if (pointerIndex >= 0) pageButtonAt(event.getX(pointerIndex), event.getY(pointerIndex)) else null
                    val activate = button != null && button === pressedPageButton
                    cancelGesture()
                    if (activate) button?.performClick()
                    return true
                }
                val target = if (pointerIndex < 0) null
                else if (constrainedAnchorPress) RadialGeometry.Target.Center
                else touchTarget(event.getX(pointerIndex), event.getY(pointerIndex), stable = true)
                cancelGesture()
                performClick()
                when (target) {
                    is RadialGeometry.Target.Action -> activateAction(target.index)
                    RadialGeometry.Target.Center, RadialGeometry.Target.Outside -> onDismiss?.invoke()
                    RadialGeometry.Target.Gap -> Unit
                    null -> Unit
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                cancelGesture()
                return true
            }
        }
        return trackingGesture
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_ESCAPE && event.action == KeyEvent.ACTION_UP) {
            onDismiss?.invoke()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchHoverEvent(event: MotionEvent): Boolean {
        // Observe before dispatch: the real Button children consume hover over their icons.
        // Touch exploration still follows the unmodified native accessibility path.
        if (event.isFromSource(InputDevice.SOURCE_MOUSE) || event.isFromSource(InputDevice.SOURCE_STYLUS)) {
            when (event.actionMasked) {
                MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> highlight(event.x, event.y)
                MotionEvent.ACTION_HOVER_EXIT -> { highlightedIndex = -1; updatePresentation() }
            }
        }
        return super.dispatchHoverEvent(event)
    }

    private fun highlight(x: Float, y: Float, stable: Boolean = false) {
        val next = (touchTarget(x, y, stable) as? RadialGeometry.Target.Action)?.index
            ?.takeIf { actionButtons.getOrNull(it)?.isEnabled == true } ?: -1
        if (next == highlightedIndex) return
        highlightedIndex = next
        if (trackingGesture && HaloAppearance.hapticsEnabled(context) && next >= 0) performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        updatePresentation()
    }

    private fun cancelGesture() {
        trackingGesture = false
        constrainedAnchorPress = false
        pagingGesture = false
        pressedPageButton?.isPressed = false
        pressedPageButton = null
        activePointerId = MotionEvent.INVALID_POINTER_ID
        parent?.requestDisallowInterceptTouchEvent(false)
        highlightedIndex = -1
        updatePresentation()
    }

    private fun isOverPager(x: Float, y: Float) = pageCount > 1 && pagerBounds.contains(x, y) ||
        sourceOptions.visibility == VISIBLE && x >= sourceOptions.left && x < sourceOptions.right && y >= sourceOptions.top && y < sourceOptions.bottom

    private fun pageButtonAt(x: Float, y: Float): Button? = listOf(previousPage, nextPage, sourceOptions).firstOrNull {
        it.visibility == VISIBLE && it.isEnabled && x >= it.left && x < it.right && y >= it.top && y < it.bottom
    }

    private fun touchTarget(x: Float, y: Float, stable: Boolean = false): RadialGeometry.Target? {
        if (isOverPager(x, y)) return RadialGeometry.Target.Gap
        if (compactLayout) {
            if (x < 0 || y < 0 || x >= width || y >= height) return RadialGeometry.Target.Outside
            if (y <= centerButton.bottom) return RadialGeometry.Target.Center
            val index = actionButtons.indexOfFirst { x >= it.left && x < it.right && y >= it.top && y < it.bottom }
            return if (index >= 0) RadialGeometry.Target.Action(index) else RadialGeometry.Target.Gap
        }
        return if (stable) geometry?.dragTarget(x, y, highlightedIndex) else geometry?.hitTest(x, y)
    }

    private fun activeIndex(): Int {
        val index = if (highlightedIndex >= 0 || trackingGesture) highlightedIndex else actionButtons.indexOfFirst { it.isFocused }
        return index.takeIf { actionButtons.getOrNull(it)?.isEnabled == true } ?: -1
    }

    private fun updateActionAvailability() {
        val canOpenLink = !selectionTextKnown || ActionUrls.normalizeOpenUrl(selectedText) != null
        actionButtons.forEachIndexed { index, button ->
            val enabled = actions[index].type != ActionType.OPEN_URL || canOpenLink
            button.isEnabled = enabled
            button.isClickable = enabled
            button.isFocusable = enabled
            if (!enabled) button.clearFocus()
        }
        if (highlightedIndex >= 0 && !actionButtons[highlightedIndex].isEnabled) highlightedIndex = -1
    }

    private fun updatePresentation() {
        updateActionColors()
        updateCenterLabel()
        invalidate()
    }

    private fun updateActionColors() {
        actionButtons.forEachIndexed { index, button ->
            val active = index == activeIndex()
            button.icon?.setTint(if (gtaModeEnabled) Color.WHITE else if (active) SURFACE else TEXT_PRIMARY)
            button.invalidate()
            button.alpha = if (!button.isEnabled) 0.25f else if (gtaModeEnabled && !active) 0.85f else 1f
            button.scaleX = if (gtaModeEnabled && active && !compactLayout) GTA_SELECTION_SCALE else 1f
            button.scaleY = button.scaleX
        }
    }

    private fun activateAction(index: Int) {
        val action = actions.getOrNull(index) ?: return
        if (actionCommitted || !actionButtons[index].isEnabled) return
        actionCommitted = true
        highlightedIndex = index
        updatePresentation()
        if (gtaModeEnabled) {
            removeCallbacks(clearFlash)
            flashIndex = index
            postDelayed(clearFlash, 50)
            invalidate()
        }
        // Execute on release immediately; visual feedback never delays the action.
        onActionSelected?.invoke(action)
    }

    internal fun showInlinePanel(panel: View) {
        hideInlinePanel()
        cancelGesture()
        inlinePanel = panel
        for (index in 0 until childCount) getChildAt(index).importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(panel)
        requestLayout()
        invalidate()
    }

    internal fun hideInlinePanel() {
        inlinePanel?.let(::removeView)
        inlinePanel = null
        for (index in 0 until childCount) getChildAt(index).importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        requestLayout()
        invalidate()
    }

    fun showActionFeedback(message: Int) {
        removeCallbacks(clearActionError)
        actionError = null
        showOperationStatus(context.getString(message))
        postDelayed(clearFeedback, 1_800)
    }

    /** Retry a failed external action without reopening or moving the wheel. */
    fun beginInteractionSession() {
        removeCallbacks(clearFeedback)
        actionCommitted = false
        operationStatus = null
        updatePager()
        removeCallbacks(clearFlash)
        flashIndex = -1
        cancelGesture()
    }

    fun showActionError(message: Int) {
        operationStatus = null
        updatePager()
        removeCallbacks(clearActionError)
        actionError = context.getString(message) + "\n" + context.getString(R.string.action_retry_hint)
        updateCenterLabel()
        announceForAccessibility(actionError)
        postDelayed(clearActionError, 5_000)
    }

    /** Busy feedback stays inside the wheel; its close and outside gestures remain available. */
    fun showOperationStatus(message: String?) {
        removeCallbacks(clearFeedback)
        val next = message?.takeIf { it.isNotBlank() }
        if (operationStatus == next) return
        operationStatus = next
        updatePager()
        updateCenterLabel()
        operationStatus?.let(::announceForAccessibility)
    }

    private fun rebuildSectorPaths() {
        val layout = geometry ?: return
        sectorPaths.clear()
        slotPositions = actions.indices.map {
            layout.pointAt(it, layout.innerRadius + dp(2f) + (slotPaint.descent() - slotPaint.ascent()) / 2f)
        }
        circleBounds.set(layout.centerX - layout.outerRadius, layout.centerY - layout.outerRadius, layout.centerX + layout.outerRadius, layout.centerY + layout.outerRadius)
        innerBounds.set(layout.centerX - layout.innerRadius, layout.centerY - layout.innerRadius, layout.centerX + layout.innerRadius, layout.centerY + layout.innerRadius)
        actions.indices.forEach { index ->
            val start = layout.sectorStartDegrees(index)
            val sweep = layout.sectorSweepDegrees
            sectorPaths += Path().apply {
                arcTo(circleBounds, start, sweep)
                arcTo(innerBounds, start + sweep, -sweep)
                close()
            }
        }
    }

    private fun drawGtaWheel(canvas: Canvas, layout: RadialGeometry) {
        val active = activeIndex()
        paint.strokeJoin = Paint.Join.ROUND
        sectorPaths.forEachIndexed { index, path ->
            val selected = index == active
            if (selected) {
                // Cached paths with layered strokes keep the halo glow on the GPU.
                paint.style = Paint.Style.STROKE
                paint.color = Color.argb(18, 255, 255, 255)
                paint.strokeWidth = dp(24f)
                canvas.drawPath(path, paint)
                paint.color = Color.argb(36, 255, 255, 255)
                paint.strokeWidth = dp(12f)
                canvas.drawPath(path, paint)
                paint.color = Color.argb(70, 255, 255, 255)
                paint.strokeWidth = dp(6f)
                canvas.drawPath(path, paint)
            }
            paint.style = Paint.Style.FILL
            paint.color = when {
                index == flashIndex -> Color.WHITE
                selected -> GTA_SELECTED
                else -> GTA_SECTOR
            }
            if (!actionButtons[index].isEnabled) paint.alpha = (paint.alpha * 0.25f).toInt()
            canvas.drawPath(path, paint)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = dp(if (selected) 2f else 1f)
            paint.color = if (selected) Color.argb(240, 255, 255, 255) else GTA_BORDER
            if (!actionButtons[index].isEnabled) paint.alpha = (paint.alpha * 0.25f).toInt()
            canvas.drawPath(path, paint)
        }
        actionButtons.forEach { it.drawIconShadow(canvas) }
        val coreRadius = (layout.innerRadius - dp(10f)).coerceAtLeast(1f)
        paint.style = Paint.Style.FILL
        paint.color = Color.argb(50, 0, 0, 0)
        canvas.drawCircle(layout.centerX, layout.centerY, coreRadius + dp(5f), paint)
        paint.color = GTA_CORE
        canvas.drawCircle(layout.centerX, layout.centerY, coreRadius, paint)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = dp(1f)
        paint.color = if (centerButton.isFocused) Color.WHITE else GTA_BORDER
        canvas.drawCircle(layout.centerX, layout.centerY, coreRadius, paint)

        slotPositions.forEachIndexed { index, (x, y) ->
            slotPaint.color = Color.argb(if (actionButtons[index].isEnabled) 71 else 18, 255, 255, 255)
            canvas.save()
            canvas.rotate(layout.actionAngleDegrees(index) + 90f, x, y)
            canvas.drawText(slotLabels[index], x, y - (slotPaint.ascent() + slotPaint.descent()) / 2f, slotPaint)
            canvas.restore()
        }
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(clearFeedback)
        removeCallbacks(clearActionError)
        actionError = null
        removeCallbacks(clearFlash)
        flashIndex = -1
        cancelGesture()
        super.onDetachedFromWindow()
    }

    private fun dp(value: Float) = value * resources.displayMetrics.density
    private fun sp(value: Float) = android.util.TypedValue.applyDimension(android.util.TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics)
    private fun exactly(size: Int) = MeasureSpec.makeMeasureSpec(size, MeasureSpec.EXACTLY)

    companion object {
        private const val GTA_SELECTION_SCALE = 1.22f
        private val SURFACE = Color.rgb(20, 25, 34)
        private val RING = Color.rgb(39, 47, 59)
        private val BORDER = Color.rgb(68, 79, 94)
        private val ACCENT = Color.rgb(246, 158, 83)
        private val TEXT_PRIMARY = Color.rgb(250, 247, 240)
        private val TEXT_SECONDARY = Color.rgb(163, 177, 195)
        private val GTA_SECTOR = Color.argb(189, 13, 13, 13)
        private val GTA_SELECTED = Color.argb(245, 224, 224, 224)
        private val GTA_BORDER = Color.argb(36, 255, 255, 255)
        private val GTA_CORE = Color.argb(235, 10, 10, 10)
        private val GTA_SUBTITLE = Color.argb(107, 255, 255, 255)
        private val GTA_SUBTITLE_ACTIVE = Color.argb(166, 255, 255, 255)
    }
}
