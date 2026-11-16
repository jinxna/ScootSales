import Flutter
import AVFoundation
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var onDeviceSpeechController: IosOnDeviceSpeechController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    onDeviceSpeechController?.dispose()
    onDeviceSpeechController = IosOnDeviceSpeechController(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// Bridges Apple's explicit on-device speech recognizer to Flutter.
///
/// The request is rejected when the selected en-US recognizer does not report
/// on-device support. There is deliberately no remote-recognition fallback.
private final class IosOnDeviceSpeechController: NSObject, FlutterStreamHandler {
  private static let methodsName = "fyp_a/voice/on_device"
  private static let eventsName = "fyp_a/voice/on_device/events"

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var audioEngine: AVAudioEngine?
  private var audioTapInstalled = false
  private var generation = 0
  private var active = false
  private var finalDelivered = false

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: Self.methodsName,
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: Self.eventsName,
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    eventChannel.setStreamHandler(self)
  }

  func dispose() {
    cancelRecognition()
    methodChannel.setMethodCallHandler(nil)
    eventChannel.setStreamHandler(nil)
    eventSink = nil
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(isAvailable())
    case "start":
      start(result: result)
    case "stop":
      stop()
      result(nil)
    case "cancel":
      cancelRecognition()
      result(nil)
    case "dispose":
      // A Dart sheet owns one capture session, while this controller owns the
      // engine-wide channels. Release the recognition session without
      // unregistering those channels; AppDelegate calls dispose() during
      // engine shutdown.
      cancelRecognition()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isAvailable() -> Bool {
    guard #available(iOS 13.0, *) else { return false }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
      return false
    }

    let speechAuthorization = SFSpeechRecognizer.authorizationStatus()
    let microphonePermission = AVAudioSession.sharedInstance().recordPermission
    if speechAuthorization == .denied || speechAuthorization == .restricted ||
        microphonePermission == .denied {
      return false
    }
    // The recognizer can report unavailable while either permission is still
    // undetermined. Return the capability result so start() can request access
    // on the user's explicit tap.
    if speechAuthorization == .notDetermined || microphonePermission == .undetermined {
      return true
    }
    return recognizer.isAvailable
  }

  private func start(result: @escaping FlutterResult) {
    cancelRecognition()
    guard #available(iOS 13.0, *), isAvailable() else {
      result(false)
      return
    }

    let captureGeneration = generation + 1
    generation = captureGeneration
    guard SFSpeechRecognizer.authorizationStatus() == .authorized,
          AVAudioSession.sharedInstance().recordPermission == .granted else {
      requestPermissions(for: captureGeneration)
      emit(captureGeneration, type: "error", message: "Speech and microphone permission are required. Tap the microphone again after allowing them.")
      emit(captureGeneration, type: "stopped")
      result(false)
      return
    }

    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // On-device when this iPhone has the English model; otherwise Apple's
    // standard speech service (needs a connection), as Android does.
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      emitError(captureGeneration, message: "Microphone audio input is unavailable.")
      emit(captureGeneration, type: "stopped")
      result(false)
      return
    }

    var tapInstalled = false
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
        request.append(buffer)
      }
      tapInstalled = true
    } catch {
      if tapInstalled { inputNode.removeTap(onBus: 0) }
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      emitError(captureGeneration, message: error.localizedDescription)
      emit(captureGeneration, type: "stopped")
      result(false)
      return
    }

    speechRecognizer = recognizer
    recognitionRequest = request
    audioEngine = engine
    audioTapInstalled = true
    finalDelivered = false
    active = true
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self = self, self.isCurrent(captureGeneration) else { return }
        if let result = result {
          let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
          if result.isFinal {
            if !text.isEmpty && !self.finalDelivered {
              self.finalDelivered = true
              self.emit(captureGeneration, type: "final", text: text)
            }
            self.active = false
            self.stopAudioOnly()
            self.emit(captureGeneration, type: "stopped")
            return
          }
          if !text.isEmpty {
            self.emit(captureGeneration, type: "partial", text: text)
          }
        }
        if let error = error {
          self.active = false
          self.stopAudioOnly()
          self.emitError(captureGeneration, message: error.localizedDescription)
          self.emit(captureGeneration, type: "stopped")
        }
      }
    }

    do {
      try engine.start()
      result(true)
      emit(captureGeneration, type: "ready")
    } catch {
      active = false
      recognitionTask?.cancel()
      stopAudioOnly()
      emitError(captureGeneration, message: error.localizedDescription)
      emit(captureGeneration, type: "stopped")
      result(false)
    }
  }

  private func stop() {
    guard active else { return }
    recognitionRequest?.endAudio()
    audioEngine?.stop()
  }

  private func requestPermissions(for captureGeneration: Int) {
    SFSpeechRecognizer.requestAuthorization { speechStatus in
      AVAudioSession.sharedInstance().requestRecordPermission { microphoneGranted in
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.generation == captureGeneration else { return }
          if speechStatus != .authorized || !microphoneGranted {
            self.emitError(captureGeneration, message: "Speech or microphone permission was denied.")
          } else {
            self.emitError(captureGeneration, message: "Permissions granted. Tap the microphone again to start.")
          }
          self.emit(captureGeneration, type: "stopped")
        }
      }
    }
  }

  private func cancelRecognition() {
    generation += 1
    active = false
    recognitionTask?.cancel()
    recognitionTask = nil
    stopAudioOnly()
  }

  private func stopAudioOnly() {
    if let engine = audioEngine {
      engine.stop()
      if audioTapInstalled {
        engine.inputNode.removeTap(onBus: 0)
      }
    }
    audioTapInstalled = false
    recognitionRequest?.endAudio()
    speechRecognizer = nil
    audioEngine = nil
    recognitionRequest = nil
    recognitionTask = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func isCurrent(_ captureGeneration: Int) -> Bool {
    active && generation == captureGeneration
  }

  private func emitError(_ captureGeneration: Int, message: String) {
    emit(captureGeneration, type: "error", message: message)
  }

  private func emit(_ captureGeneration: Int, type: String, text: String? = nil, message: String? = nil) {
    guard generation == captureGeneration else { return }
    var payload: [String: Any] = ["type": type]
    if let text = text { payload["text"] = text }
    if let message = message { payload["message"] = message }
    eventSink?(payload)
  }
}
