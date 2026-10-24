// Copyright © 2011-2026 Mengjuei Hsieh et al.
// Licensed under the MIT License.

import AppKit
import AVFoundation
import Foundation
import InputMethodKit

public enum VoiceInputState: Equatable {
    case idle
    case requestingPermission
    case connecting
    case listening(partialText: String)
    case polishing
    case finished(text: String)
    case error(String)
}

public final class VoiceInputManager: NSObject, @unchecked Sendable {
    public static let shared = VoiceInputManager()

    public typealias StateChangeCallback = @MainActor (VoiceInputState) -> Void
    public typealias CompletionCallback = @MainActor (String?) -> Void

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?

    private var onStateChange: StateChangeCallback?
    private var onCompletion: CompletionCallback?

    private(set) var currentState: VoiceInputState = .idle
    private var accumulatedFinalText: String = ""
    private var latestPartialText: String = ""
    private var precedingContext: String = ""
    private var isStoppingStream = false
    private let stateLock = NSLock()

    private let afmClient = AFMAssistClient()

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        self.session = URLSession(configuration: config)
    }

    public var isRecordingOrProcessing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch currentState {
        case .requestingPermission, .connecting, .listening, .polishing:
            return true
        default:
            return false
        }
    }

    public func candidateASREndpoints() -> [String] {
        var endpoints: [String] = []
        let custom = Preferences.afmVoiceASREndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            endpoints.append(custom)
        }
        // Local Mac mini ASR service
        endpoints.append("ws://127.0.0.1:8765/v1/audio/transcriptions/stream")
        // Remote / MacBook Tailscale ASR service
        endpoints.append("wss://mac-mini.tail670ea6.ts.net/v1/audio/transcriptions/stream")
        return endpoints
    }

    public func start(
        precedingContext: String = "",
        onStateChange: @escaping StateChangeCallback,
        completion: @escaping CompletionCallback
    ) {
        stateLock.lock()
        guard currentState == .idle else {
            stateLock.unlock()
            AFMDevLogger.shared.log("VOICE-INPUT: Start called while already active (\(currentState))")
            return
        }
        self.precedingContext = precedingContext
        self.onStateChange = onStateChange
        self.onCompletion = completion
        self.accumulatedFinalText = ""
        self.latestPartialText = ""
        self.isStoppingStream = false
        self.currentState = .requestingPermission
        stateLock.unlock()

        AFMDevLogger.shared.log("VOICE-INPUT: Requesting microphone permission")

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            self.initiateConnectionAndRecording()
        case .notDetermined:
            Task { @MainActor in
                onStateChange(.requestingPermission)
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.initiateConnectionAndRecording()
                    } else {
                        self?.handleFailure("未取得麥克風授權，請至系統設定中允許取用。")
                    }
                }
            }
        case .denied, .restricted:
            handleFailure("麥克風取用已被停用，請至「系統設定」>「隱私權與安全性」>「麥克風」允許「思脈注音」取用麥克風。")
        @unknown default:
            handleFailure("無法存取麥克風（未知狀態）。")
        }
    }

    private func initiateConnectionAndRecording() {
        stateLock.lock()
        self.currentState = .connecting
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.connecting)
        }

        // Try candidate endpoints in order
        let endpoints = candidateASREndpoints()
        connectToASR(endpoints: endpoints, index: 0)
    }

    private func connectToASR(endpoints: [String], index: Int) {
        guard index < endpoints.count else {
            handleFailure("無法連接本地 ASR 語音伺服器 (ws://127.0.0.1:8765 或 wss://mac-mini.tail670ea6.ts.net)")
            return
        }

        let endpointStr = endpoints[index]
        guard let url = URL(string: endpointStr) else {
            connectToASR(endpoints: endpoints, index: index + 1)
            return
        }

        AFMDevLogger.shared.log("VOICE-INPUT: Connecting to ASR endpoint [\(endpointStr)]")

        let task = session?.webSocketTask(with: url)
        self.webSocketTask = task
        task?.resume()

        listenForReadyOrData(endpoints: endpoints, index: index)
    }

    private func listenForReadyOrData(endpoints: [String], index: Int) {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let str):
                    text = str
                case .data(let data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    text = ""
                }

                if text.contains("\"ready\"") {
                    AFMDevLogger.shared.log("VOICE-INPUT: ASR READY received from [\(endpoints[index])]")
                    self.startAudioEngine()
                    self.startContinuousReceiveLoop()
                } else {
                    self.handleASRServerMessage(text)
                    self.startContinuousReceiveLoop()
                }

            case .failure(let error):
                AFMDevLogger.shared.log("VOICE-INPUT: Connection failed to [\(endpoints[index])]: \(error.localizedDescription)")
                self.webSocketTask?.cancel()
                self.webSocketTask = nil
                self.connectToASR(endpoints: endpoints, index: index + 1)
            }
        }
    }

    private func startAudioEngine() {
        do {
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw NSError(domain: "VoiceInputManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "無效的麥克風輸入格式"])
            }

            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
                throw NSError(domain: "VoiceInputManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "無法建立 16kHz PCM 目標格式"])
            }

            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "VoiceInputManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "無法建立音訊格式轉換器"])
            }
            self.converter = converter

            let bufferSize: AVAudioFrameCount = 1024
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
                self?.convertAndSendAudio(buffer: buffer)
            }

            engine.prepare()
            try engine.start()
            self.audioEngine = engine

            stateLock.lock()
            self.currentState = .listening(partialText: "")
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(.listening(partialText: ""))
            }
            AFMDevLogger.shared.log("VOICE-INPUT: Audio capture started at \(inputFormat.sampleRate)Hz -> 16000Hz Int16 mono")

        } catch {
            AFMDevLogger.shared.log("VOICE-INPUT: Audio Engine start failed: \(error.localizedDescription)")
            handleFailure("啟動麥克風失敗: \(error.localizedDescription)")
        }
    }

    private func convertAndSendAudio(buffer: AVAudioPCMBuffer) {
        guard let converter = self.converter else { return }

        let ratio = 16000.0 / buffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 128)

        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: targetCapacity) else {
            return
        }

        var error: NSError?
        var hasProvided = false

        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if hasProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvided = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: targetBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil { return }
        guard targetBuffer.frameLength > 0, let channelData = targetBuffer.int16ChannelData else { return }

        let byteCount = Int(targetBuffer.frameLength) * 2
        let pcmData = Data(bytes: channelData[0], count: byteCount)

        stateLock.lock()
        guard let ws = self.webSocketTask, !self.isStoppingStream else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let msg = URLSessionWebSocketTask.Message.data(pcmData)
        ws.send(msg) { _ in }
    }

    private func startContinuousReceiveLoop() {
        guard let ws = self.webSocketTask else { return }

        ws.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let str):
                    text = str
                case .data(let data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    text = ""
                }

                self.handleASRServerMessage(text)

                self.stateLock.lock()
                let isFinished = (self.currentState == .idle)
                self.stateLock.unlock()

                if !isFinished {
                    self.startContinuousReceiveLoop()
                }

            case .failure(let error):
                self.stateLock.lock()
                let wasStopping = self.isStoppingStream
                self.stateLock.unlock()

                if !wasStopping {
                    AFMDevLogger.shared.log("VOICE-INPUT: ASR receive loop ended: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleASRServerMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "partial":
            let text = json["text"] as? String ?? ""
            stateLock.lock()
            self.latestPartialText = text
            self.currentState = .listening(partialText: text)
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(.listening(partialText: text))
            }

        case "final":
            let text = json["text"] as? String ?? ""
            stateLock.lock()
            if !text.isEmpty {
                if !self.accumulatedFinalText.isEmpty {
                    self.accumulatedFinalText += " " + text
                } else {
                    self.accumulatedFinalText = text
                }
            }
            self.latestPartialText = ""
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateChange?(.listening(partialText: self.accumulatedFinalText))
            }

        case "done":
            AFMDevLogger.shared.log("VOICE-INPUT: ASR 'done' received")
            self.finishAndRunLLMPolish()

        case "error":
            let errorMsg = json["error"] as? String ?? "未知錯誤"
            AFMDevLogger.shared.log("VOICE-INPUT: ASR Server Error: \(errorMsg)")
            if errorMsg.contains("Native stream did not complete") || errorMsg.contains("CancellationError") {
                // If ending stream, don't crash, proceed to finish
                self.finishAndRunLLMPolish()
            } else {
                handleFailure("語音辨識伺服器錯誤: \(errorMsg)")
            }

        default:
            break
        }
    }

    public func stopAndPolish() {
        stateLock.lock()
        guard self.currentState != .idle, !self.isStoppingStream else {
            stateLock.unlock()
            return
        }
        self.isStoppingStream = true
        self.currentState = .polishing
        stateLock.unlock()

        AFMDevLogger.shared.log("VOICE-INPUT: User stopped recording. Sending {type: end}...")

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.polishing)
        }

        // 1. Stop audio capture
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil

        // 2. Send end message to ASR
        let endMsg = URLSessionWebSocketTask.Message.string("{\"type\":\"end\"}")
        webSocketTask?.send(endMsg) { error in
            if let error = error {
                AFMDevLogger.shared.log("VOICE-INPUT: Send end message error: \(error.localizedDescription)")
            }
        }

        // 3. Fallback timer: if server doesn't respond with 'done' within 2.0s, force finish
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let stillPolishing = (self.currentState == .polishing)
            self.stateLock.unlock()

            if stillPolishing {
                AFMDevLogger.shared.log("VOICE-INPUT: ASR 'done' timeout fallback triggered")
                self.finishAndRunLLMPolish()
            }
        }
    }

    public func cancel() {
        stateLock.lock()
        guard self.currentState != .idle else {
            stateLock.unlock()
            return
        }
        self.currentState = .idle
        self.isStoppingStream = true
        stateLock.unlock()

        AFMDevLogger.shared.log("VOICE-INPUT: Cancelled by user")

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil

        webSocketTask?.cancel()
        webSocketTask = nil

        DispatchQueue.main.async { [weak self] in
            self?.onCompletion?(nil)
            self?.onStateChange?(.idle)
            self?.resetCallbacks()
        }
    }

    private func finishAndRunLLMPolish() {
        stateLock.lock()
        guard self.currentState == .polishing else {
            stateLock.unlock()
            return
        }
        // Disconnect websocket
        webSocketTask?.cancel()
        webSocketTask = nil

        var rawTranscript = self.accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTranscript.isEmpty {
            rawTranscript = self.latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let context = self.precedingContext
        stateLock.unlock()

        guard !rawTranscript.isEmpty else {
            AFMDevLogger.shared.log("VOICE-INPUT: Empty transcription, nothing to polish")
            DispatchQueue.main.async { [weak self] in
                self?.stateLock.lock()
                self?.currentState = .idle
                self?.stateLock.unlock()
                self?.onCompletion?(nil)
                self?.onStateChange?(.idle)
                self?.resetCallbacks()
            }
            return
        }

        AFMDevLogger.shared.log("VOICE-INPUT: Polishing raw transcript with LLM: '\(rawTranscript)'")

        Task {
            let polished = await self.afmClient.typelessPolish(
                rawTranscript: rawTranscript,
                precedingContext: context
            )
            let result = (polished?.isEmpty == false) ? polished! : rawTranscript
            AFMDevLogger.shared.log("VOICE-INPUT: Typeless final result: '\(result)'")

            await MainActor.run {
                self.stateLock.lock()
                self.currentState = .finished(text: result)
                self.stateLock.unlock()

                self.onStateChange?(.finished(text: result))
                self.onCompletion?(result)

                self.stateLock.lock()
                self.currentState = .idle
                self.stateLock.unlock()
                self.resetCallbacks()
            }
        }
    }

    private func handleFailure(_ message: String) {
        stateLock.lock()
        self.currentState = .error(message)
        stateLock.unlock()

        AFMDevLogger.shared.log("VOICE-INPUT FAILURE: \(message)")

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        webSocketTask?.cancel()
        webSocketTask = nil

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.error(message))
            self?.onCompletion?(nil)
            self?.stateLock.lock()
            self?.currentState = .idle
            self?.stateLock.unlock()
            self?.resetCallbacks()
        }
    }

    private func resetCallbacks() {
        self.onStateChange = nil
        self.onCompletion = nil
        self.accumulatedFinalText = ""
        self.latestPartialText = ""
        self.precedingContext = ""
        self.isStoppingStream = false
    }
}
