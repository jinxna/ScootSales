package my.scootsales.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Speech capture for the voice button and the Copilot.
 *
 * It prefers the on-device recognizer (API 31+). Many phones have no local
 * recognizer or no offline language pack, so it falls back to the standard
 * system SpeechRecognizer without forcing offline mode. That service may use
 * the network, depending on the phone's speech engine. Only when neither exists
 * do `isAvailable` and `start` return false, so Flutter keeps typed commands.
 */
class OnDeviceSpeechController(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val METHODS = "fyp_a/voice/on_device"
        private const val EVENTS = "fyp_a/voice/on_device/events"
        const val AUDIO_PERMISSION_REQUEST = 7401
        // Constants added in API 31/33; literals keep older compileSdk safe.
        private const val ERROR_TOO_MANY_REQUESTS = 10
        private const val ERROR_SERVER_DISCONNECTED = 11
        private const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        private const val ERROR_LANGUAGE_UNAVAILABLE = 13
        private const val FALLBACK_LANGUAGE = "en-US"
        private const val PERMISSION_MESSAGE =
            "Allow the microphone in Settings to use voice."
    }

    private val methodChannel = MethodChannel(messenger, METHODS)
    private val eventChannel = EventChannel(messenger, EVENTS)
    private var eventSink: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var generation = 0L
    private var active = false
    private var finalDelivered = false

    /** The current recognizer has reported onReadyForSpeech. */
    private var readySeen = false
    private var pendingStart: MethodChannel.Result? = null
    private var pendingLanguage: String? = null

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "start" -> start(result, call.argument<String>("language"))
            "stop" -> {
                try {
                    recognizer?.stopListening()
                    result.success(null)
                } catch (error: Throwable) {
                    cancelRecognition()
                    result.error(
                        "speech-stop-failed",
                        error.message ?: "Unable to stop speech recognition.",
                        null,
                    )
                }
            }
            "cancel" -> {
                cancelRecognition()
                abandonPendingStart()
                result.success(null)
            }
            "dispose" -> {
                // A Dart sheet owns one capture session, while this
                // controller owns the engine-wide channels. Release the
                // recognition session without unregistering those channels;
                // the Activity calls dispose() during engine shutdown.
                cancelRecognition()
                abandonPendingStart()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        cancelRecognition()
        eventSink = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    private fun isOnDeviceAvailable(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && runCatching {
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
        }.getOrDefault(false)
    }

    private fun isAvailable(): Boolean {
        return isOnDeviceAvailable() || runCatching {
            SpeechRecognizer.isRecognitionAvailable(activity)
        }.getOrDefault(false)
    }

    /** Forwarded by MainActivity for [AUDIO_PERMISSION_REQUEST]. */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != AUDIO_PERMISSION_REQUEST) return
        val result = pendingStart ?: return
        val language = pendingLanguage
        pendingStart = null
        pendingLanguage = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            beginListening(result, language)
            return
        }
        val captureGeneration = generation
        emitError(captureGeneration, permissionDeniedMessage())
        emit(captureGeneration, "stopped")
        result.success(false)
    }

    private fun abandonPendingStart() {
        pendingStart?.success(false)
        pendingStart = null
        pendingLanguage = null
    }

    private fun permissionDeniedMessage(): String {
        // After a denial, shouldShowRequestPermissionRationale is false only
        // when the user chose "don't ask again" (or the system blocks it).
        val blocked = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !activity.shouldShowRequestPermissionRationale(
                Manifest.permission.RECORD_AUDIO,
            )
        return if (blocked) {
            "$PERMISSION_MESSAGE Open Settings, Apps, this app, Permissions, Microphone."
        } else {
            PERMISSION_MESSAGE
        }
    }

    private fun hasAudioPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun start(result: MethodChannel.Result, language: String?) {
        if (pendingStart != null) {
            // A permission request is already waiting for its answer.
            result.success(false)
            return
        }
        cancelRecognition()
        if (!isAvailable()) {
            result.success(false)
            return
        }
        if (!hasAudioPermission()) {
            // The answer comes back in onRequestPermissionsResult.
            pendingStart = result
            pendingLanguage = language
            val permissionError = runCatching {
                activity.requestPermissions(
                    arrayOf(Manifest.permission.RECORD_AUDIO),
                    AUDIO_PERMISSION_REQUEST,
                )
            }.exceptionOrNull()
            if (permissionError != null) {
                pendingStart = null
                pendingLanguage = null
                val captureGeneration = ++generation
                emitError(
                    captureGeneration,
                    permissionError.message ?: permissionDeniedMessage(),
                )
                emit(captureGeneration, "stopped")
                result.success(false)
            }
            return
        }
        beginListening(result, language)
    }

    private fun beginListening(result: MethodChannel.Result, language: String?) {
        cancelRecognition()
        val captureGeneration = ++generation
        val deviceTag = Locale.getDefault().toLanguageTag()
        val requested = language?.takeIf { it.isNotBlank() }
            ?: if (deviceTag.startsWith("en", ignoreCase = true)) deviceTag else FALLBACK_LANGUAGE
        startRecognizer(captureGeneration, requested, isOnDeviceAvailable(), true, result)
    }

    private fun startRecognizer(
        captureGeneration: Long,
        language: String,
        onDevice: Boolean,
        canRetry: Boolean,
        result: MethodChannel.Result?,
    ) {
        var localRecognizer: SpeechRecognizer? = null
        try {
            finalDelivered = false
            readySeen = false
            val createdRecognizer =
                if (onDevice) {
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                } else {
                    SpeechRecognizer.createSpeechRecognizer(activity)
                }
            localRecognizer = createdRecognizer
            recognizer = createdRecognizer
            createdRecognizer.setRecognitionListener(
                recognitionListener(
                    captureGeneration,
                    createdRecognizer,
                ) { error ->
                    // Use the standard system recognizer once when the
                    // on-device one has no language pack, or fails before it
                    // starts listening. Some phones report on-device support
                    // and then fail at once with a client, network or service
                    // error.
                    val languageProblem =
                        error == ERROR_LANGUAGE_NOT_SUPPORTED ||
                            error == ERROR_LANGUAGE_UNAVAILABLE
                    val failedBeforeListening = !readySeen &&
                        error != SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS
                    if (canRetry && onDevice &&
                        (languageProblem || failedBeforeListening) &&
                        runCatching {
                            SpeechRecognizer.isRecognitionAvailable(activity)
                        }.getOrDefault(false)
                    ) {
                        releaseRecognizer(createdRecognizer)
                        startRecognizer(captureGeneration, language, false, false, null)
                        true
                    } else {
                        false
                    }
                },
            )

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                )
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                if (onDevice) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
            active = true
            createdRecognizer.startListening(intent)
            result?.success(true)
        } catch (error: Throwable) {
            active = false
            releaseRecognizer(localRecognizer)
            emitError(captureGeneration, error.message ?: "Unable to start speech recognition.")
            emit(captureGeneration, "stopped")
            result?.success(false)
        }
    }

    private fun recognitionListener(
        captureGeneration: Long,
        localRecognizer: SpeechRecognizer,
        retryHandler: (Int) -> Boolean,
    ): RecognitionListener {
        return object : RecognitionListener {
            // The recognizer can take seconds to load its model; only now is
            // it really listening.
            override fun onReadyForSpeech(params: Bundle?) {
                if (!isCurrent(captureGeneration)) return
                readySeen = true
                emit(captureGeneration, "ready")
            }

            override fun onBeginningOfSpeech() = Unit

            override fun onRmsChanged(rmsdB: Float) = Unit

            override fun onBufferReceived(buffer: ByteArray?) = Unit

            override fun onEndOfSpeech() = Unit

            override fun onError(error: Int) {
                if (!isCurrent(captureGeneration)) return
                if (retryHandler(error)) return
                active = false
                emitError(captureGeneration, errorMessage(error))
                emit(captureGeneration, "stopped")
                releaseRecognizer(localRecognizer)
            }

            override fun onResults(results: Bundle?) {
                if (!isCurrent(captureGeneration)) return
                active = false
                val matches =
                    results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = matches?.firstOrNull()?.trim().orEmpty()
                if (text.isNotEmpty() && !finalDelivered) {
                    finalDelivered = true
                    emit(captureGeneration, "final", text)
                }
                emit(captureGeneration, "stopped")
                releaseRecognizer(localRecognizer)
            }

            override fun onPartialResults(partialResults: Bundle?) {
                if (!isCurrent(captureGeneration)) return
                val matches =
                    partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = matches?.firstOrNull()?.trim().orEmpty()
                if (text.isNotEmpty()) emit(captureGeneration, "partial", text)
            }

            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        }
    }

    private fun isCurrent(captureGeneration: Long): Boolean {
        return captureGeneration == generation && active
    }

    private fun emitError(captureGeneration: Long, message: String) {
        emit(captureGeneration, "error", message)
    }

    private fun emit(captureGeneration: Long, type: String, text: String? = null) {
        if (captureGeneration != generation) return
        val payload = mutableMapOf<String, Any>("type" to type)
        if (text != null) payload[if (type == "error") "message" else "text"] = text
        eventSink?.success(payload)
    }

    private fun cancelRecognition() {
        generation += 1
        active = false
        val localRecognizer = recognizer
        recognizer = null
        runCatching { localRecognizer?.cancel() }
        runCatching { localRecognizer?.destroy() }
    }

    private fun releaseRecognizer(localRecognizer: SpeechRecognizer?) {
        if (recognizer === localRecognizer) recognizer = null
        runCatching { localRecognizer?.destroy() }
    }

    private fun errorMessage(error: Int): String {
        return when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "Audio capture failed."
            SpeechRecognizer.ERROR_CLIENT -> "Speech recognition is unavailable."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is required."
            SpeechRecognizer.ERROR_NETWORK,
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
                "Speech needs a language pack or internet. Check your connection."
            ERROR_TOO_MANY_REQUESTS -> "Speech recognition is busy. Try again in a moment."
            ERROR_SERVER_DISCONNECTED -> "The speech service stopped. Try again."
            ERROR_LANGUAGE_NOT_SUPPORTED ->
                "This phone does not support speech in this language."
            ERROR_LANGUAGE_UNAVAILABLE ->
                "The speech language pack is not installed. Install it in the phone's speech settings."
            SpeechRecognizer.ERROR_NO_MATCH -> "No speech match was found."
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognition is busy. Try again."
            SpeechRecognizer.ERROR_SERVER -> "The speech recognizer failed."
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was detected."
            else -> "Speech recognition failed."
        }
    }
}
