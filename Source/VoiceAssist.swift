// Copyright © 2011-2026 Mengjuei Hsieh et al.
// Licensed under the MIT License.

import AppKit
import AVFoundation
import Foundation
import InputMethodKit

public enum VoiceMode: String, Sendable, CaseIterable {
    case dictate = "dictate"         // 標準口述重構與書面潤飾
    case helpMeWrite = "helpMeWrite" // 語音指令寫作（草稿、代碼、信件）
    case translate = "translate"     // 語音多國語言翻譯
}

public struct VoiceSoundEffect {
    public static func playStart() {
        guard Preferences.afmVoiceFeedbackSoundEnabled else { return }
        DispatchQueue.main.async {
            NSSound(named: "Tink")?.play()
        }
    }

    public static func playStop() {
        guard Preferences.afmVoiceFeedbackSoundEnabled else { return }
        DispatchQueue.main.async {
            NSSound(named: "Pop")?.play()
        }
    }

    public static func playCancel() {
        guard Preferences.afmVoiceFeedbackSoundEnabled else { return }
        DispatchQueue.main.async {
            NSSound(named: "Funk")?.play()
        }
    }
}

public struct UserPhrasesDictionaryProvider {
    public static func loadTopUserPhrases(limit: Int = 30) -> [String] {
        let path = LanguageModelManager.userPhrasesDataPathMcBopomofo
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var phrases: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ")
            if let first = parts.first, !first.isEmpty {
                phrases.append(String(first))
            }
            if phrases.count >= limit { break }
        }
        return phrases
    }
}

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

    private let audioEngine = AVAudioEngine()
    private var isTapInstalled = false
    private let audioQueue = DispatchQueue(label: "org.openvanilla.mcbopomofo.voice.audio", qos: .userInitiated)

    private var converter: AVAudioConverter?
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?

    private var onStateChange: StateChangeCallback?
    private var onCompletion: CompletionCallback?

    private(set) var currentState: VoiceInputState = .idle
    private(set) var currentMode: VoiceMode = .dictate
    private var targetAppBundleID: String?
    private var targetAppName: String?
    private var accumulatedFinalText: String = ""
    private var latestPartialText: String = ""
    private var precedingContext: String = ""
    private var isStoppingStream = false
    private var didStartPolishing = false
    private var currentSessionID: UInt64 = 0

    private var fallbackDoneTimer: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var sessionWatchdogWorkItem: DispatchWorkItem?
    private var inFlightPolishTask: Task<Void, Never>?
    private static var lastSuccessfulASREndpoint: String?

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
        if let last = Self.lastSuccessfulASREndpoint, !last.isEmpty {
            endpoints.append(last)
        }
        let custom = Preferences.afmVoiceASREndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty && !endpoints.contains(custom) {
            endpoints.append(custom)
        }
        let local = "ws://127.0.0.1:8765/v1/audio/transcriptions/stream"
        if !endpoints.contains(local) {
            endpoints.append(local)
        }
        let remote = "wss://mac-mini.tail670ea6.ts.net/v1/audio/transcriptions/stream"
        if !endpoints.contains(remote) {
            endpoints.append(remote)
        }
        return endpoints
    }

    public func start(
        mode: VoiceMode = .dictate,
        targetAppBundleID: String? = nil,
        targetAppName: String? = nil,
        precedingContext: String = "",
        onStateChange: @escaping StateChangeCallback,
        completion: @escaping CompletionCallback
    ) {
        stateLock.lock()
        if currentState != .idle {
            AFMDevLogger.shared.log("VOICE-INPUT: Start called while state is \(currentState). Performing clean session reset.")
            self.currentSessionID &+= 1
            self.currentState = .idle
        }

        self.currentSessionID &+= 1
        let sessionID = self.currentSessionID
        self.currentMode = mode
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.precedingContext = precedingContext
        self.onStateChange = onStateChange
        self.onCompletion = completion
        self.accumulatedFinalText = ""
        self.latestPartialText = ""
        self.isStoppingStream = false
        self.didStartPolishing = false

        cancelInternalTimersAndTasks()

        guard AVCaptureDevice.default(for: .audio) != nil else {
            stateLock.unlock()
            AFMDevLogger.shared.log("VOICE-INPUT: No audio capture device found on this system")
            handleFailure("找不到麥克風輸入裝置。若使用 Mac mini 請先接上麥克風或連線 AirPods。", sessionID: sessionID)
            return
        }

        self.currentState = .requestingPermission
        stateLock.unlock()

        // 25s session watchdog
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let stillActive = (self.currentSessionID == sessionID && self.currentState != .idle)
            self.stateLock.unlock()
            if stillActive {
                AFMDevLogger.shared.log("VOICE-INPUT: Session \(sessionID) watchdog expired after 25s, auto-resetting")
                self.handleFailure("語音輸入逾時（25秒），已自動重設", sessionID: sessionID)
            }
        }
        self.sessionWatchdogWorkItem = watchdog
        DispatchQueue.global().asyncAfter(deadline: .now() + 25.0, execute: watchdog)

        AFMDevLogger.shared.log("VOICE-INPUT: Starting session \(sessionID) [mode=\(mode.rawValue)]")

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            self.initiateConnectionAndRecording(sessionID: sessionID)
        case .notDetermined:
            Task { @MainActor in
                onStateChange(.requestingPermission)
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.initiateConnectionAndRecording(sessionID: sessionID)
                    } else {
                        self?.handleFailure("未取得麥克風授權，請至系統設定中允許取用。", sessionID: sessionID)
                    }
                }
            }
        case .denied, .restricted:
            handleFailure("麥克風取用已被停用，請至「系統設定」>「隱私權與安全性」>「麥克風」允許「思脈注音」取用麥克風。", sessionID: sessionID)
        @unknown default:
            handleFailure("無法存取麥克風（未知狀態）。", sessionID: sessionID)
        }
    }

    private func initiateConnectionAndRecording(sessionID: UInt64) {
        stateLock.lock()
        guard self.currentSessionID == sessionID, !self.isStoppingStream, (self.currentState == .requestingPermission || self.currentState == .idle) else {
            stateLock.unlock()
            AFMDevLogger.shared.log("VOICE-INPUT: Aborting connection because state is \(currentState), stopping=\(isStoppingStream), session=\(sessionID)")
            return
        }
        self.currentState = .connecting
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let ok = (self.currentSessionID == sessionID)
            self.stateLock.unlock()
            if ok {
                self.onStateChange?(.connecting)
            }
        }

        let endpoints = candidateASREndpoints()
        connectToASR(endpoints: endpoints, index: 0, sessionID: sessionID)
    }

    private func connectToASR(endpoints: [String], index: Int, sessionID: UInt64) {
        stateLock.lock()
        guard self.currentSessionID == sessionID, !self.isStoppingStream && self.currentState == .connecting else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        guard index < endpoints.count else {
            handleFailure("無法連接本地或遠端 ASR 語音伺服器 (ws://127.0.0.1:8765 或 Tailscale wss)", sessionID: sessionID)
            return
        }

        let endpointStr = endpoints[index]
        guard let url = URL(string: endpointStr) else {
            connectToASR(endpoints: endpoints, index: index + 1, sessionID: sessionID)
            return
        }

        AFMDevLogger.shared.log("VOICE-INPUT: Connecting to ASR endpoint [\(endpointStr)] (session=\(sessionID))")

        self.webSocketTask?.cancel()
        let task = session?.webSocketTask(with: url)
        self.webSocketTask = task
        task?.resume()

        connectionTimeoutWorkItem?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let stillConnecting = (self.currentSessionID == sessionID && self.currentState == .connecting)
            self.stateLock.unlock()

            if stillConnecting {
                AFMDevLogger.shared.log("VOICE-INPUT: Connection to [\(endpointStr)] timed out after 2.5s, trying next candidate")
                self.webSocketTask?.cancel()
                self.webSocketTask = nil
                self.connectToASR(endpoints: endpoints, index: index + 1, sessionID: sessionID)
            }
        }
        self.connectionTimeoutWorkItem = watchdog
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: watchdog)

        listenForReadyOrData(endpoints: endpoints, index: index, sessionID: sessionID)
    }

    private func listenForReadyOrData(endpoints: [String], index: Int, sessionID: UInt64) {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            self.stateLock.lock()
            guard self.currentSessionID == sessionID else {
                self.stateLock.unlock()
                return
            }
            let stopping = self.isStoppingStream
            let state = self.currentState
            self.stateLock.unlock()

            if stopping || state == .idle {
                AFMDevLogger.shared.log("VOICE-INPUT: Received ASR response but stream is already stopping or idle, closing")
                self.webSocketTask?.cancel()
                self.webSocketTask = nil
                return
            }

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
                    Self.lastSuccessfulASREndpoint = endpoints[index]
                    self.connectionTimeoutWorkItem?.cancel()
                    self.connectionTimeoutWorkItem = nil

                    self.startAudioCapture(sessionID: sessionID)
                } else {
                    self.handleASRServerMessage(text, sessionID: sessionID)
                    self.startContinuousReceiveLoop(sessionID: sessionID)
                }

            case .failure(let error):
                AFMDevLogger.shared.log("VOICE-INPUT: Connection failed to [\(endpoints[index])]: \(error.localizedDescription)")
                self.connectionTimeoutWorkItem?.cancel()
                self.connectionTimeoutWorkItem = nil
                self.webSocketTask?.cancel()
                self.webSocketTask = nil
                self.connectToASR(endpoints: endpoints, index: index + 1, sessionID: sessionID)
            }
        }
    }

    private func startAudioCapture(sessionID: UInt64) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            guard self.currentSessionID == sessionID, !self.isStoppingStream, self.currentState == .connecting else {
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()

            do {
                self.stopAudioCaptureInternal()

                let inputNode = self.audioEngine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)

                guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                    throw NSError(domain: "VoiceInputManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "無效的麥克風輸入格式（未檢測到有效音訊輸入裝置）"])
                }

                guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
                    throw NSError(domain: "VoiceInputManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "無法建立 16kHz PCM 目標格式"])
                }

                guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                    throw NSError(domain: "VoiceInputManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "無法建立音訊格式轉換器"])
                }
                self.converter = converter

                let bufferSize: AVAudioFrameCount = 1024
                try ObjCExceptionCatcher.execute {
                    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
                        self?.convertAndSendAudio(buffer: buffer, sessionID: sessionID)
                    }
                }
                self.isTapInstalled = true

                self.audioEngine.prepare()
                try self.audioEngine.start()

                VoiceSoundEffect.playStart()

                self.stateLock.lock()
                guard self.currentSessionID == sessionID else {
                    self.stateLock.unlock()
                    self.stopAudioCaptureInternal()
                    return
                }
                self.currentState = .listening(partialText: "")
                self.stateLock.unlock()

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.stateLock.lock()
                    let ok = (self.currentSessionID == sessionID)
                    self.stateLock.unlock()
                    if ok {
                        self.onStateChange?(.listening(partialText: ""))
                    }
                }

                AFMDevLogger.shared.log("VOICE-INPUT: Audio capture started at \(inputFormat.sampleRate)Hz -> 16000Hz Int16 mono (session=\(sessionID))")
                self.startContinuousReceiveLoop(sessionID: sessionID)

            } catch {
                AFMDevLogger.shared.log("VOICE-INPUT: Audio Engine start failed: \(error.localizedDescription)")
                self.handleFailure("啟動麥克風失敗: \(error.localizedDescription)", sessionID: sessionID)
            }
        }
    }

    private func stopAudioCapture() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopAudioCaptureInternal()
        }
    }

    private func stopAudioCaptureInternal() {
        if self.isTapInstalled {
            try? ObjCExceptionCatcher.execute {
                self.audioEngine.inputNode.removeTap(onBus: 0)
            }
            self.isTapInstalled = false
        }
        if self.audioEngine.isRunning {
            self.audioEngine.stop()
        }
        self.audioEngine.reset()
        self.converter = nil
    }

    private func convertAndSendAudio(buffer: AVAudioPCMBuffer, sessionID: UInt64) {
        stateLock.lock()
        guard self.currentSessionID == sessionID, !self.isStoppingStream, let ws = self.webSocketTask else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

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

        let msg = URLSessionWebSocketTask.Message.data(pcmData)
        ws.send(msg) { _ in }
    }

    private func startContinuousReceiveLoop(sessionID: UInt64) {
        guard let ws = self.webSocketTask else { return }

        ws.receive { [weak self] result in
            guard let self = self else { return }

            self.stateLock.lock()
            guard self.currentSessionID == sessionID else {
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()

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

                self.handleASRServerMessage(text, sessionID: sessionID)

                self.stateLock.lock()
                let isFinished = (self.currentState == .idle || self.didStartPolishing)
                self.stateLock.unlock()

                if !isFinished {
                    self.startContinuousReceiveLoop(sessionID: sessionID)
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

    private func handleASRServerMessage(_ jsonString: String, sessionID: UInt64) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "partial":
            let text = json["text"] as? String ?? ""
            stateLock.lock()
            guard self.currentSessionID == sessionID else {
                stateLock.unlock()
                return
            }
            self.latestPartialText = text
            self.currentState = .listening(partialText: text)
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock()
                let ok = (self.currentSessionID == sessionID)
                self.stateLock.unlock()
                if ok {
                    self.onStateChange?(.listening(partialText: text))
                }
            }

        case "final":
            let text = json["text"] as? String ?? ""
            stateLock.lock()
            guard self.currentSessionID == sessionID else {
                stateLock.unlock()
                return
            }
            if !text.isEmpty {
                if !self.accumulatedFinalText.isEmpty {
                    self.accumulatedFinalText += " " + text
                } else {
                    self.accumulatedFinalText = text
                }
            }
            self.latestPartialText = ""
            let displayText = self.accumulatedFinalText
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock()
                let ok = (self.currentSessionID == sessionID)
                self.stateLock.unlock()
                if ok {
                    self.onStateChange?(.listening(partialText: displayText))
                }
            }

        case "done":
            AFMDevLogger.shared.log("VOICE-INPUT: ASR 'done' received for session \(sessionID)")
            self.finishAndRunLLMPolish(sessionID: sessionID)

        case "error":
            let errorMsg = json["error"] as? String ?? "未知錯誤"
            AFMDevLogger.shared.log("VOICE-INPUT: ASR Server Error: \(errorMsg)")
            if errorMsg.contains("Native stream did not complete") || errorMsg.contains("CancellationError") {
                self.finishAndRunLLMPolish(sessionID: sessionID)
            } else {
                handleFailure("語音辨識伺服器錯誤: \(errorMsg)", sessionID: sessionID)
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
        let sessionID = self.currentSessionID
        let previousState = self.currentState
        self.isStoppingStream = true
        self.currentState = .polishing
        self.didStartPolishing = false
        stateLock.unlock()

        VoiceSoundEffect.playStop()
        AFMDevLogger.shared.log("VOICE-INPUT: User stopped recording (session=\(sessionID)). Sending {type: end}...")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let ok = (self.currentSessionID == sessionID)
            self.stateLock.unlock()
            if ok {
                self.onStateChange?(.polishing)
            }
        }

        // 1. Stop audio capture
        stopAudioCapture()

        if previousState == .requestingPermission || previousState == .connecting {
            AFMDevLogger.shared.log("VOICE-INPUT: Stopped while still in \(previousState); ending immediately")
            self.finishAndRunLLMPolish(sessionID: sessionID)
            return
        }

        // 2. Send end message to ASR
        let endMsg = URLSessionWebSocketTask.Message.string("{\"type\":\"end\"}")
        webSocketTask?.send(endMsg) { error in
            if let error = error {
                AFMDevLogger.shared.log("VOICE-INPUT: Send end message error: \(error.localizedDescription)")
            }
        }

        // 3. Fallback timer: if server doesn't respond with 'done' within 1.2s, force finish
        fallbackDoneTimer?.cancel()
        let timerItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let needFallback = (self.currentSessionID == sessionID && !self.didStartPolishing && self.currentState == .polishing)
            self.stateLock.unlock()

            if needFallback {
                AFMDevLogger.shared.log("VOICE-INPUT: ASR 'done' timeout fallback triggered for session \(sessionID)")
                self.finishAndRunLLMPolish(sessionID: sessionID)
            }
        }
        self.fallbackDoneTimer = timerItem
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2, execute: timerItem)
    }

    public func cancel() {
        stateLock.lock()
        guard self.currentState != .idle else {
            stateLock.unlock()
            return
        }
        let sessionID = self.currentSessionID
        self.currentSessionID &+= 1
        self.currentState = .idle
        self.isStoppingStream = true
        self.didStartPolishing = false
        stateLock.unlock()

        VoiceSoundEffect.playCancel()
        AFMDevLogger.shared.log("VOICE-INPUT: Cancelled by user (session=\(sessionID))")

        cancelInternalTimersAndTasks()
        stopAudioCapture()

        webSocketTask?.cancel()
        webSocketTask = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onCompletion?(nil)
            self.onStateChange?(.idle)
            self.resetCallbacks()
        }
    }

    private func cancelInternalTimersAndTasks() {
        fallbackDoneTimer?.cancel()
        fallbackDoneTimer = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        sessionWatchdogWorkItem?.cancel()
        sessionWatchdogWorkItem = nil
        inFlightPolishTask?.cancel()
        inFlightPolishTask = nil
    }

    private func finishAndRunLLMPolish(sessionID: UInt64) {
        stateLock.lock()
        guard self.currentSessionID == sessionID else {
            stateLock.unlock()
            return
        }
        guard !self.didStartPolishing else {
            stateLock.unlock()
            return
        }
        self.didStartPolishing = true

        fallbackDoneTimer?.cancel()
        fallbackDoneTimer = nil

        // Disconnect websocket
        webSocketTask?.cancel()
        webSocketTask = nil

        var rawTranscript = self.accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTranscript.isEmpty {
            rawTranscript = self.latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let context = self.precedingContext
        let mode = self.currentMode
        let bundleID = self.targetAppBundleID
        let appName = self.targetAppName
        let customPhrases = UserPhrasesDictionaryProvider.loadTopUserPhrases(limit: 25)
        stateLock.unlock()

        guard !rawTranscript.isEmpty else {
            AFMDevLogger.shared.log("VOICE-INPUT: Empty transcription, nothing to polish (session=\(sessionID))")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock()
                guard self.currentSessionID == sessionID else {
                    self.stateLock.unlock()
                    return
                }
                self.currentState = .idle
                self.stateLock.unlock()

                self.onCompletion?(nil)
                self.onStateChange?(.idle)
                self.resetCallbacks()
            }
            return
        }

        AFMDevLogger.shared.log("VOICE-INPUT: Polishing raw transcript with LLM [mode=\(mode.rawValue), app=\(appName ?? "none")]: '\(rawTranscript)' (session=\(sessionID))")

        inFlightPolishTask?.cancel()
        inFlightPolishTask = Task { [weak self] in
            guard let self = self else { return }

            let maxTimeout: Double = (mode == .helpMeWrite ? 8.0 : 4.0)

            let polishedResult: String = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    await self.afmClient.typelessPolish(
                        rawTranscript: rawTranscript,
                        precedingContext: context,
                        mode: mode,
                        targetAppBundleID: bundleID,
                        targetAppName: appName,
                        customPhrases: customPhrases
                    )
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(maxTimeout * 1_000_000_000))
                    return nil
                }
                if let first = await group.next() ?? nil, !first.isEmpty {
                    group.cancelAll()
                    return first
                }
                group.cancelAll()
                return rawTranscript
            }

            let result = !polishedResult.isEmpty ? polishedResult : rawTranscript
            AFMDevLogger.shared.log("VOICE-INPUT: Typeless final result: '\(result)' (session=\(sessionID))")

            await MainActor.run {
                self.stateLock.lock()
                guard self.currentSessionID == sessionID else {
                    self.stateLock.unlock()
                    return
                }
                self.currentState = .finished(text: result)
                self.stateLock.unlock()

                self.onStateChange?(.finished(text: result))
                self.onCompletion?(result)

                self.stateLock.lock()
                guard self.currentSessionID == sessionID else {
                    self.stateLock.unlock()
                    return
                }
                self.currentState = .idle
                self.stateLock.unlock()
                self.resetCallbacks()
            }
        }
    }

    private func handleFailure(_ message: String, sessionID: UInt64? = nil) {
        stateLock.lock()
        if let sID = sessionID, self.currentSessionID != sID {
            stateLock.unlock()
            return
        }
        let activeSessionID = self.currentSessionID
        self.currentSessionID &+= 1
        self.currentState = .error(message)
        self.isStoppingStream = true
        self.didStartPolishing = false
        stateLock.unlock()

        AFMDevLogger.shared.log("VOICE-INPUT FAILURE: \(message) (session=\(activeSessionID))")

        cancelInternalTimersAndTasks()
        stopAudioCapture()

        webSocketTask?.cancel()
        webSocketTask = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStateChange?(.error(message))
            self.onCompletion?(nil)
            self.stateLock.lock()
            self.currentState = .idle
            self.stateLock.unlock()
            self.resetCallbacks()
        }
    }

    private func resetCallbacks() {
        self.onStateChange = nil
        self.onCompletion = nil
        self.accumulatedFinalText = ""
        self.latestPartialText = ""
        self.precedingContext = ""
        self.currentMode = .dictate
        self.targetAppBundleID = nil
        self.targetAppName = nil
        self.isStoppingStream = false
    }
}
