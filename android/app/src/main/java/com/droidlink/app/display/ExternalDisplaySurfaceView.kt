package com.droidlink.app.display

import android.content.Context
import android.util.AttributeSet
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import droidlink.protocol.ExternalDisplayProto
import kotlinx.coroutines.CoroutineScope

/**
 * Hardware-accelerated SurfaceView rendering the Mac's external monitor frames
 * and capturing multi-touch, S-Pen stylus, and mouse interactions.
 */
class ExternalDisplaySurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : SurfaceView(context, attrs, defStyleAttr), SurfaceHolder.Callback {

    companion object {
        private const val TAG = "ExtDisplaySurfaceView"
    }

    private var decoder: ExternalDisplayDecoder? = null
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var scope: CoroutineScope? = null
    private var isTouchDown = false

    var onInputEventCaptured: ((ExternalDisplayProto.ExternalDisplayInput) -> Unit)? = null
    var onSurfaceReady: (() -> Unit)? = null
    var onFrameRendered: ((frameNum: Int, latencyMs: Long) -> Unit)? = null

    init {
        holder.addCallback(this)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    fun configure(width: Int, height: Int, scope: CoroutineScope) {
        this.displayWidth = width
        this.displayHeight = height
        this.scope = scope
        initDecoderIfPossible()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "Surface created")
        initDecoderIfPossible()
        onSurfaceReady?.invoke()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        Log.d(TAG, "Surface changed: ${width}x${height}")
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "Surface destroyed; releasing decoder")
        if (isTouchDown) {
            isTouchDown = false
            val cancelMsg = ExternalDisplayProto.ExternalDisplayInput.newBuilder()
                .setAction(ExternalDisplayProto.ExternalDisplayInput.ActionType.CANCEL)
                .setToolType(ExternalDisplayProto.ExternalDisplayInput.ToolType.FINGER)
                .build()
            onInputEventCaptured?.invoke(cancelMsg)
        }
        decoder?.release()
        decoder = null
    }

    private fun initDecoderIfPossible() {
        val sc = scope ?: return
        if (holder.surface?.isValid == true && decoder == null) {
            val d = ExternalDisplayDecoder(holder.surface, displayWidth, displayHeight, sc)
            d.onFrameRendered = { num, lat ->
                onFrameRendered?.invoke(num, lat)
            }
            decoder = d
        }
    }

    fun queueVideoFrame(frameData: ByteArray, isKeyframe: Boolean, frameNumber: Int, timestamp: Long) {
        decoder?.queueFrame(frameData, isKeyframe, frameNumber, timestamp)
    }

    // MARK: - Input Capture (Touch, S-Pen Stylus, Mouse)

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                isTouchDown = true
                ExternalDisplayProto.ExternalDisplayInput.ActionType.DOWN
            }
            MotionEvent.ACTION_MOVE -> ExternalDisplayProto.ExternalDisplayInput.ActionType.MOVE
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                isTouchDown = false
                ExternalDisplayProto.ExternalDisplayInput.ActionType.UP
            }
            MotionEvent.ACTION_CANCEL -> {
                isTouchDown = false
                ExternalDisplayProto.ExternalDisplayInput.ActionType.CANCEL
            }
            else -> return super.onTouchEvent(event)
        }

        val pointerIndex = event.actionIndex
        val pointerId = event.getPointerId(pointerIndex)

        val toolType = when (event.getToolType(pointerIndex)) {
            MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> ExternalDisplayProto.ExternalDisplayInput.ToolType.STYLUS
            MotionEvent.TOOL_TYPE_MOUSE -> ExternalDisplayProto.ExternalDisplayInput.ToolType.MOUSE
            else -> ExternalDisplayProto.ExternalDisplayInput.ToolType.FINGER
        }

        val normX = (event.getX(pointerIndex) / width.toFloat()).coerceIn(0f, 1f)
        val normY = (event.getY(pointerIndex) / height.toFloat()).coerceIn(0f, 1f)
        val pressure = event.getPressure(pointerIndex)

        val inputBuilder = ExternalDisplayProto.ExternalDisplayInput.newBuilder()
            .setAction(action)
            .setToolType(toolType)
            .setPointerId(pointerId)
            .setNormalizedX(normX)
            .setNormalizedY(normY)
            .setPressure(pressure)
            .setButtonState(event.buttonState)

        if (toolType == ExternalDisplayProto.ExternalDisplayInput.ToolType.STYLUS) {
            val tilt = event.getAxisValue(MotionEvent.AXIS_TILT, pointerIndex)
            inputBuilder.setTiltX(tilt)
        }

        onInputEventCaptured?.invoke(inputBuilder.build())
        return true
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_SCROLL) {
            val vScroll = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
            val hScroll = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
            val normX = (event.x / width.toFloat()).coerceIn(0f, 1f)
            val normY = (event.y / height.toFloat()).coerceIn(0f, 1f)

            val inputMsg = ExternalDisplayProto.ExternalDisplayInput.newBuilder()
                .setAction(ExternalDisplayProto.ExternalDisplayInput.ActionType.SCROLL)
                .setToolType(ExternalDisplayProto.ExternalDisplayInput.ToolType.MOUSE)
                .setNormalizedX(normX)
                .setNormalizedY(normY)
                .setScrollDx(hScroll)
                .setScrollDy(vScroll)
                .build()

            onInputEventCaptured?.invoke(inputMsg)
            return true
        }
        return super.onGenericMotionEvent(event)
    }

    fun release() {
        decoder?.release()
        decoder = null
    }
}
