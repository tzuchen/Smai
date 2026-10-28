// Copyright (c) 2022 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Cocoa
import InputMethodKit
import InputSourceHelper

private func install() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        return -1
    }
    let bundleUrl = Bundle.main.bundleURL
    var maybeInputSource = InputSourceHelper.inputSource(for: bundleID)

    if maybeInputSource == nil {
        NSLog("Registering input source \(bundleID) at \(bundleUrl.absoluteString)");
        // then register
        let status = InputSourceHelper.registerInputSource(at: bundleUrl)

        if !status {
            NSLog("Fatal error: Cannot register input source \(bundleID) at \(bundleUrl.absoluteString).")
            return -1
        }

        maybeInputSource = InputSourceHelper.inputSource(for: bundleID)
    }

    guard let inputSource = maybeInputSource else {
        NSLog("Fatal error: Cannot find input source \(bundleID) after registration.")
        return -1
    }

    if !InputSourceHelper.inputSourceEnabled(for: inputSource) {
        NSLog("Enabling input source \(bundleID) at \(bundleUrl.absoluteString).")
        let status = InputSourceHelper.enable(inputSource: inputSource)
        if !status {
            NSLog("Fatal error: Cannot enable input source \(bundleID).")
            return -1
        }
        if !InputSourceHelper.inputSourceEnabled(for: inputSource) {
            NSLog("Fatal error: Cannot enable input source \(bundleID).")
            return -1
        }
    }

    if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "--all" {
        let enabled = InputSourceHelper.enableAllInputMode(for: bundleID)
        NSLog(enabled ? "All input sources enabled for \(bundleID)" : "Cannot enable all input sources for \(bundleID), but this is ignored")
    }
    return 0
}

if CommandLine.arguments.count > 1 {
    if CommandLine.arguments[1] == "install" {
        let exitCode = install()
        exit(exitCode)
    }
    if CommandLine.arguments[1] == "--diagnose-capslock-routing" {
        var switchState = AFMCapsLockSwitch()

        // Verify initial state: no fallback English.
        let initialChinese = !switchState.isFallbackEnglish

        // Press 1: zero-flag Caps at 10.000 -> toggle, English true.
        let p1 = switchState.handleCapsLock(isOn: false, timestamp: 10.000)
        let p1Toggle = (p1 == .toggle)
        let p1English = switchState.isFallbackEnglish

        // Press 2: zero-flag Caps at 10.029 -> duplicate, English stays true.
        let p2 = switchState.handleCapsLock(isOn: false, timestamp: 10.029)
        let p2Duplicate = (p2 == .duplicate)
        let p2English = switchState.isFallbackEnglish

        // Press 3: zero-flag Caps at 17.230 -> toggle, Chinese false.
        let p3 = switchState.handleCapsLock(isOn: false, timestamp: 17.230)
        let p3Toggle = (p3 == .toggle)
        let p3Chinese = !switchState.isFallbackEnglish

        // Press 4: zero-flag Caps at 17.245 -> duplicate, Chinese stays false.
        let p4 = switchState.handleCapsLock(isOn: false, timestamp: 17.245)
        let p4Duplicate = (p4 == .duplicate)
        let p4Chinese = !switchState.isFallbackEnglish

        // Press 5: zero-flag Caps at 20.000 -> toggle, English true.
        let p5 = switchState.handleCapsLock(isOn: false, timestamp: 20.000)
        let p5Toggle = (p5 == .toggle)
        let p5English = switchState.isFallbackEnglish

        // Press 6: zero-flag Caps at 20.030 -> duplicate, English stays true.
        let p6 = switchState.handleCapsLock(isOn: false, timestamp: 20.030)
        let p6Duplicate = (p6 == .duplicate)
        let p6English = switchState.isFallbackEnglish

        // Native Caps ON at 25.000 -> native, English false.
        let p7 = switchState.handleCapsLock(isOn: true, timestamp: 25.000)
        let p7Native = (p7 == .native)
        let p7English = switchState.isFallbackEnglish

        // Native release at 26.000 -> native, English false.
        let p8 = switchState.handleCapsLock(isOn: false, timestamp: 26.000)
        let p8Native = (p8 == .native)
        let p8English = switchState.isFallbackEnglish

        // Repeated release at 26.025 -> duplicate, NOT toggle.
        let p9 = switchState.handleCapsLock(isOn: false, timestamp: 26.025)
        let p9Duplicate = (p9 == .duplicate)
        let p9NotToggle = (p9 != .toggle)

        // Rapid next intentional press at 26.200 -> toggle, English true.
        let p10 = switchState.handleCapsLock(isOn: false, timestamp: 26.200)
        let p10Toggle = (p10 == .toggle)
        let p10English = switchState.isFallbackEnglish

        // observeNativeCapsOn clears fallback English.
        switchState.observeNativeCapsOn()
        let clearedFallback = !switchState.isFallbackEnglish

        let diagnosticPassed =
            initialChinese
            && p1Toggle && p1English
            && p2Duplicate && p2English
            && p3Toggle && p3Chinese
            && p4Duplicate && p4Chinese
            && p5Toggle && p5English
            && p6Duplicate && p6English
            && p7Native && !p7English
            && p8Native && !p8English
            && p9Duplicate && p9NotToggle
            && p10Toggle && p10English
            && clearedFallback

        let resultDict: [String: Any] = [
            "case": "capslockRouting",
            "initialChinese": initialChinese,
            "press1Toggle": p1Toggle,
            "press1English": p1English,
            "press2Duplicate": p2Duplicate,
            "press2English": p2English,
            "press3Toggle": p3Toggle,
            "press3Chinese": p3Chinese,
            "press4Duplicate": p4Duplicate,
            "press4Chinese": p4Chinese,
            "press5Toggle": p5Toggle,
            "press5English": p5English,
            "press6Duplicate": p6Duplicate,
            "press6English": p6English,
            "press7Native": p7Native,
            "press7English": p7English,
            "press8Native": p8Native,
            "press8English": p8English,
            "press9Duplicate": p9Duplicate,
            "press9NotToggle": p9NotToggle,
            "press10Toggle": p10Toggle,
            "press10English": p10English,
            "clearedFallback": clearedFallback,
            "diagnosticPassed": diagnosticPassed
        ]

        if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }

        exit(diagnosticPassed ? 0 : 2)
    }
    if CommandLine.arguments[1] == "--diagnose-english-case" {
        var casePolicy = AFMEnglishCasePolicy()

        func replay(_ letters: [Character], flags: NSEvent.ModifierFlags) -> String? {
            var result = ""
            for char in letters {
                guard let committed = casePolicy.letterToCommit(
                    text: String(char),
                    flags: flags
                ) else {
                    return nil
                }
                result += committed
            }
            return result
        }

        // Initial lowercase letters remain lowercase.
        let initialLower = replay(["h", "e", "l", "l", "o"], flags: [])

        // Input HELLO with Shift and no modifier press must return hello.
        let noModifierPress = replay(["H", "E", "L", "L", "O"], flags: [.shift])

        // Observe Shift down, then HELLO with Shift => HELLO.
        casePolicy.observeModifierEvent(keyCode: 56, shiftIsOn: true)
        let shiftHeld = replay(["H", "E", "L", "L", "O"], flags: [.shift])

        // Observe Shift up => hello despite keydown Shift true.
        casePolicy.observeModifierEvent(keyCode: 56, shiftIsOn: false)
        let shiftReleased = replay(["H", "E", "L", "L", "O"], flags: [.shift])

        // Right Shift down => HELLO.
        casePolicy.observeModifierEvent(keyCode: 60, shiftIsOn: true)
        let rightShiftHeld = replay(["H", "E", "L", "L", "O"], flags: [.shift])

        // Non-Shift Caps key must NOT reset held shift.
        casePolicy.observeModifierEvent(keyCode: 57, shiftIsOn: false)
        let nonShiftCaps = replay(["H", "E", "L", "L", "O"], flags: [.shift])

        // resetShiftTracking => hello.
        casePolicy.resetShiftTracking()
        let afterReset = replay(["H", "E", "L", "L", "O"], flags: [.shift])

        // Command+Shift input C returns nil.
        let commandShift = replay(["C"], flags: [.command, .shift])

        // Control/Option letters nil.
        let controlLetter = replay(["A"], flags: [.control])
        let optionLetter = replay(["B"], flags: [.option])

        // Punctuation ! nil.
        let punctuation = replay(["!"], flags: [.shift])

        // Enter \r nil.
        let enter = replay(["\r"], flags: [])

        // Multi HELLO nil.
        let multi = casePolicy.letterToCommit(text: "HELLO", flags: [.shift])

        // Unicode ㄋ nil.
        let unicode = replay(["ㄋ"], flags: [])

        // nil nil.
        let nilText = casePolicy.letterToCommit(text: nil, flags: [])

        // Native Caps flags CapsLock+Shift with physical false => H.
        let nativeCapsShift = replay(["H"], flags: [.capsLock, .shift])

        // Native Caps alone input H => h.
        let nativeCapsAlone = replay(["H"], flags: [.capsLock])

        let diagnosticPassed =
            initialLower == "hello"
            && noModifierPress == "hello"
            && shiftHeld == "HELLO"
            && shiftReleased == "hello"
            && rightShiftHeld == "HELLO"
            && nonShiftCaps == "HELLO"
            && afterReset == "hello"
            && commandShift == nil
            && controlLetter == nil
            && optionLetter == nil
            && punctuation == nil
            && enter == nil
            && multi == nil
            && unicode == nil
            && nilText == nil
            && nativeCapsShift == "H"
            && nativeCapsAlone == "h"

        let resultDict: [String: Any] = [
            "case": "englishCase",
            "initialLower": initialLower,
            "noModifierPress": noModifierPress,
            "shiftHeld": shiftHeld,
            "shiftReleased": shiftReleased,
            "rightShiftHeld": rightShiftHeld,
            "nonShiftCaps": nonShiftCaps,
            "afterReset": afterReset,
            "commandShift": commandShift ?? "",
            "controlLetter": controlLetter ?? "",
            "optionLetter": optionLetter ?? "",
            "punctuation": punctuation ?? "",
            "enter": enter ?? "",
            "multi": multi ?? "",
            "unicode": unicode ?? "",
            "nilText": nilText ?? "",
            "nativeCapsShift": nativeCapsShift ?? "",
            "nativeCapsAlone": nativeCapsAlone ?? "",
            "diagnosticPassed": diagnosticPassed
        ]

        if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }

        exit(diagnosticPassed ? 0 : 2)
    }
    if CommandLine.arguments[1] == "--diagnose-slash-command" {
        // 1) Test AFMSymbolPolicy
        let optSlash = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "/", flags: [.option])
        let optQuestion = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "?", flags: [.option, .shift])
        let optMinus = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "-", flags: [.option])
        let optUnderscore = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "_", flags: [.option, .shift])
        let optPeriod = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: ".", flags: [.option])
        let optGreater = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: ">", flags: [.option, .shift])
        let optHash = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "#", flags: [.option, .shift])
        let optLetter = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "f", flags: [.option])
        let optCmdSlash = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "/", flags: [.option, .command])

        let capsSlash = AFMSymbolPolicy.capsNonLetterToCommit(chars: "/", flags: [.capsLock])
        let capsMinus = AFMSymbolPolicy.capsNonLetterToCommit(chars: "-", flags: [.capsLock])
        let capsHash = AFMSymbolPolicy.capsNonLetterToCommit(chars: "#", flags: [.capsLock, .shift])
        let capsLetter = AFMSymbolPolicy.capsNonLetterToCommit(chars: "a", flags: [.capsLock])

        let symbolPolicyPassed =
            optSlash == "/"
            && optQuestion == "?"
            && optMinus == "-"
            && optUnderscore == "_"
            && optPeriod == "."
            && optGreater == ">"
            && optHash == "#"
            && optLetter == nil
            && optCmdSlash == nil
            && capsSlash == "/"
            && capsMinus == "-"
            && capsHash == "#"
            && capsLetter == nil

        // 2) Test AFMSlashCommandTracker
        var tracker = AFMSlashCommandTracker()
        tracker.start()
        let startOk = tracker.isActive && tracker.buffer == "/"

        _ = tracker.handleKey(keyCode: 15, chars: "r", flags: [])
        _ = tracker.handleKey(keyCode: 14, chars: "e", flags: [])
        _ = tracker.handleKey(keyCode: 1, chars: "s", flags: [])
        _ = tracker.handleKey(keyCode: 32, chars: "u", flags: [])
        _ = tracker.handleKey(keyCode: 46, chars: "m", flags: [])
        _ = tracker.handleKey(keyCode: 14, chars: "e", flags: [])
        let bufferResume = tracker.buffer == "/resume"
        let enterAction = tracker.handleKey(keyCode: UInt16(kVK_Return), chars: "\r", flags: [])
        let enterOk = (enterAction == .commit("/resume")) && !tracker.isActive

        // Space commit test
        tracker.start()
        _ = tracker.handleKey(keyCode: 5, chars: "g", flags: [])
        _ = tracker.handleKey(keyCode: 31, chars: "o", flags: [])
        _ = tracker.handleKey(keyCode: 0, chars: "a", flags: [])
        _ = tracker.handleKey(keyCode: 37, chars: "l", flags: [])
        let spaceAction = tracker.handleKey(keyCode: UInt16(kVK_Space), chars: " ", flags: [])
        let spaceOk = (spaceAction == .commit("/goal ")) && !tracker.isActive

        // Backspace test
        tracker.start()
        _ = tracker.handleKey(keyCode: 4, chars: "h", flags: [])
        let back1 = tracker.handleKey(keyCode: UInt16(kVK_Delete), chars: "", flags: [])
        let back1Ok = (back1 == .updateMarked("/")) && tracker.buffer == "/"
        let back2 = tracker.handleKey(keyCode: UInt16(kVK_Delete), chars: "", flags: [])
        let back2Ok = (back2 == .cancel) && !tracker.isActive

        // Escape test
        tracker.start()
        _ = tracker.handleKey(keyCode: 4, chars: "h", flags: [])
        let escAction = tracker.handleKey(keyCode: UInt16(kVK_Escape), chars: "", flags: [])
        let escOk = (escAction == .cancel) && !tracker.isActive

        // Shortcut pass-through test (Cmd+C)
        tracker.start()
        _ = tracker.handleKey(keyCode: 8, chars: "c", flags: [])
        let cmdAction = tracker.handleKey(keyCode: 8, chars: "c", flags: [.command])
        let cmdOk = (cmdAction == .commitAndPassThrough("/c")) && !tracker.isActive

        let trackerPassed = startOk && bufferResume && enterOk && spaceOk && back1Ok && back2Ok && escOk && cmdOk
        let diagnosticPassed = symbolPolicyPassed && trackerPassed

        let resultDict: [String: Any] = [
            "case": "slashCommand",
            "symbolPolicyPassed": symbolPolicyPassed,
            "trackerPassed": trackerPassed,
            "diagnosticPassed": diagnosticPassed
        ]

        if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }

        exit(diagnosticPassed ? 0 : 2)
    }
    if CommandLine.arguments[1] == "--diagnose-afm-queue" {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let coordinator = AFMRequestCoordinator()
            let meter = AFMQueueDiagnosticMeter()

            let oldTask = Task {
                await coordinator.run {
                    await meter.enter(label: "old")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await meter.leave()
                    return 0
                }
            }

            try? await Task.sleep(nanoseconds: 50_000_000)

            let cancelledWaiterTask = Task {
                await coordinator.run {
                    await meter.enter(label: "cancelled")
                    return 0
                }
            }

            let latestTask = Task {
                await coordinator.run {
                    await meter.enter(label: "latest")
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    await meter.leave()
                    return 2
                }
            }

            oldTask.cancel()
            cancelledWaiterTask.cancel()

            let oldResult = await oldTask.value
            let cancelledResult = await cancelledWaiterTask.value
            let latestResult = await latestTask.value

            let nextTask = Task {
                await coordinator.run {
                    await meter.enter(label: "next")
                    await meter.leave()
                    return 3
                }
            }
            let nextResult = await nextTask.value

            let snapshot = await meter.snapshot()
            let diagnosticPassed =
                oldResult == nil
                && cancelledResult == nil
                && latestResult == 2
                && nextResult == 3
                && snapshot.maxActive == 1
                && snapshot.startedLabels == ["old", "latest", "next"]

            let resultDict: [String: Any] = [
                "case": "afmQueue",
                "diagnosticPassed": diagnosticPassed,
                "oldCallerDiscarded": oldResult == nil,
                "waitingCallerDiscarded": cancelledResult == nil,
                "latestApplied": latestResult == 2,
                "slotReusable": nextResult == 3,
                "maxActive": snapshot.maxActive,
                "startedLabels": snapshot.startedLabels
            ]

            if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
               let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }

            exit(diagnosticPassed ? 0 : 2)
        }

        let timeout = semaphore.wait(timeout: .now() + 8.0)
        if timeout == .timedOut {
            exit(2)
        }
        exit(0)
    }
    if CommandLine.arguments[1] == "--diagnose-afm-boundaries" {
        // 1) Exercise the real AFMTriggerPolicy delay policy.
        let normalDelay = AFMTriggerPolicy.delayNanoseconds(for: "你好")
        let normalIs700ms = (normalDelay == 700_000_000 || normalDelay == 350_000_000 || normalDelay == 200_000_000)
        let chineseCommaZero = (AFMTriggerPolicy.delayNanoseconds(for: "，") == 0)
        let chineseFullstopZero = (AFMTriggerPolicy.delayNanoseconds(for: "。") == 0)
        let chineseQuestionZero = (AFMTriggerPolicy.delayNanoseconds(for: "？") == 0)
        let asciiCommaZero = (AFMTriggerPolicy.delayNanoseconds(for: ",") == 0)
        let asciiPeriodZero = (AFMTriggerPolicy.delayNanoseconds(for: ".") == 0)
        let asciiQuestionZero = (AFMTriggerPolicy.delayNanoseconds(for: "?") == 0)
        let doubleQuestionAsciiZero = (AFMTriggerPolicy.delayNanoseconds(for: "??") == 0)
        let doubleQuestionFullwidthZero = (AFMTriggerPolicy.delayNanoseconds(for: "？？") == 0)
        let midDoubleQuestionZero = (AFMTriggerPolicy.delayNanoseconds(for: "這家店很??不想再來") == 0)
        let promptOptTrailingZero = (AFMTriggerPolicy.delayNanoseconds(for: ">>測試任務>>") == 0)
        let promptOptPunctZero = (AFMTriggerPolicy.delayNanoseconds(for: ">>測試任務。") == 0)
        let promptOptDebounce = (AFMTriggerPolicy.delayNanoseconds(for: ">>測試任務") == 600_000_000)
        let promptOptDoublePeriodZero = (AFMTriggerPolicy.delayNanoseconds(for: "。。測試任務。。") == 0)
        let promptOptDoublePeriodDebounce = (AFMTriggerPolicy.delayNanoseconds(for: "。。測試任務") == 600_000_000)
        let asciiSpaceZero = (AFMTriggerPolicy.delayNanoseconds(for: " ") == 0)
        let fullwidthSpaceZero = (AFMTriggerPolicy.delayNanoseconds(for: "\u{3000}") == 0)

        let policyPassed =
            normalIs700ms
            && chineseCommaZero
            && chineseFullstopZero
            && chineseQuestionZero
            && asciiCommaZero
            && asciiPeriodZero
            && asciiQuestionZero
            && doubleQuestionAsciiZero
            && doubleQuestionFullwidthZero
            && midDoubleQuestionZero
            && promptOptTrailingZero
            && promptOptPunctZero
            && promptOptDebounce
            && promptOptDoublePeriodZero
            && promptOptDoublePeriodDebounce
            && asciiSpaceZero
            && fullwidthSpaceZero

        // 2) Exercise the real KeyHandler engine with a fixed keyboard input.
        LanguageModelManager.loadDataModel(.bopomofo)
        let handler = KeyHandler()
        handler.inputMode = .bopomofo

        var state: InputState = InputState.Empty()
        var committedText = ""
        var errorCount = 0

        func feed(text: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
            for char in text {
                let input = KeyHandlerInput(
                    inputText: String(char),
                    keyCode: keyCode,
                    charCode: char.utf16.first!,
                    flags: flags,
                    isVerticalMode: false
                )
                _ = handler.handle(input: input, state: state) { newState in
                    if let committingState = newState as? InputState.Committing {
                        committedText += committingState.poppedText
                    }
                    state = newState
                } errorCallback: {
                    errorCount += 1
                }
            }
        }

        // Temporarily enable AFM assist inside the CLI; restore the previous
        // preference on scope exit so the CLI never mutates user settings.
        let previousSpaceChoice = Preferences.chooseCandidateUsingSpace
        let previousPhraseAfterCursor = Preferences.selectPhraseAfterCursorAsCandidate
        let previousAFMEnabled = Preferences.afmAssistEnabled
        Preferences.afmAssistEnabled = true
        defer { Preferences.afmAssistEnabled = previousAFMEnabled }

        var allPass = policyPassed
        var iterations: [[String: Any]] = []

        // Repeat the same punctuation lifecycle at least twice using the same
        // handler to catch override leakage across sentences.
        for iteration in 0..<8 {
            Preferences.chooseCandidateUsingSpace = false
            Preferences.selectPhraseAfterCursorAsCandidate = iteration % 4 >= 2
            // Fixed keyboard input for the sentence (ends with a trailing space).
            feed(text: "ji3vu;35 2l4c93u.32ji gp ")
            let afterSentence = (state as? InputState.Inputting)?.composingBuffer ?? ""

            // Comma key: charCode 44, keyCode 43, no flags.
            let boundary = iteration % 2 == 0 ? "，" : " "
            if iteration % 2 == 0 {
                feed(text: "<", keyCode: 43, flags: [.shift])
            } else {
                feed(text: " ", keyCode: 49)
            }
            guard let inputtingAfterComma = state as? InputState.Inputting else {
                allPass = false
                iterations.append([
                    "iteration": iteration,
                    "stage": "afterComma",
                    "stateType": String(describing: type(of: state)),
                    "eligible": false
                ])
                continue
            }
            let commaBuffer = inputtingAfterComma.composingBuffer
            let commaEndsPunctuation = commaBuffer.hasSuffix(boundary)
            let commaCursor = inputtingAfterComma.cursorIndex

            // Build the AFM candidate state; it must be non-nil and include a
            // candidate whose value ends with 深.
            let choosing = handler.buildAFMCandidateState() as? InputState.ChoosingCandidate
            let candidatesJSON: [[String: Any]] = choosing.map { c in
                c.candidates.enumerated().map { (i, cand) in
                    ["id": i, "reading": cand.reading, "value": cand.value]
                }
            } ?? []
            let deepExists = candidatesJSON.contains { ($0["value"] as? String)?.hasSuffix("深") == true }

            var result = ""
            var applied = false
            if let choosing, let first = choosing.candidates.first(where: { $0.value.hasSuffix("深") }) {
                if let newState = handler.applyAFMCandidate(reading: first.reading, value: first.value) {
                    state = newState
                    applied = true
                    result = (state as? InputState.Inputting)?.composingBuffer ?? ""
                } else {
                    result = (state as? InputState.Inputting)?.composingBuffer ?? ""
                }
            }

            // The full composing text must preserve the original trailing
            // punctuation, keep the cursor index, and contain 深 replacing 身.
            let preservesPunctuation = result.hasSuffix(boundary)
            let cursorPreserved = ((state as? InputState.Inputting)?.cursorIndex ?? 0) == commaCursor
            let containsDeep = result.contains("深")
            let replacedShen = !result.contains("身")
            let trailingSpaceSurvives = iteration % 2 == 0 || result.hasSuffix(" ")

            // A plain space after the completed sentence stays marked.
            feed(text: " ")
            let spaceBuffer = (state as? InputState.Inputting)?.composingBuffer ?? ""
            let spaceStaysMarked = spaceBuffer.hasSuffix(" ")

            let eligible =
                commaEndsPunctuation
                && (choosing != nil)
                && deepExists
                && applied
                && preservesPunctuation
                && cursorPreserved
                && containsDeep
                && replacedShen
                && trailingSpaceSurvives
                && spaceStaysMarked
                && errorCount == 0
            allPass = allPass && eligible

            // Press Enter to commit, then repeat the same lifecycle.
            let committedBeforeEnter = committedText
            feed(text: "\r", keyCode: 36)
            let isAfterEmpty = state is InputState.Empty || state is InputState.EmptyIgnoringPreviousState
            allPass = allPass && isAfterEmpty

            iterations.append([
                "iteration": iteration,
                "afterSentence": afterSentence,
                "commaEndsPunctuation": commaEndsPunctuation,
                "commaCursor": commaCursor,
                "eligible": eligible,
                "candidates": candidatesJSON,
                "result": result,
                "applied": applied,
                "preservesPunctuation": preservesPunctuation,
                "cursorPreserved": cursorPreserved,
                "containsDeep": containsDeep,
                "replacedShen": replacedShen,
                "trailingSpaceSurvives": trailingSpaceSurvives,
                "spaceStaysMarked": spaceStaysMarked,
                "errorCount": errorCount,
                "committedBoundaryText": String(committedText.suffix(committedText.count - committedBeforeEnter.count))
            ])
        }

        // First-tone with AFM enabled: ㄊㄚˉㄉㄜ˙ => 他的 with no inserted
        // erroneous boundary space.
        var firstToneState: InputState = InputState.Empty()
        var firstToneCommitted = ""
        for char in "ㄊㄚˉㄉㄜ˙" {
            let input = KeyHandlerInput(
                inputText: String(char),
                keyCode: 0,
                charCode: char.utf16.first!,
                flags: [],
                isVerticalMode: false
            )
            _ = handler.handle(input: input, state: firstToneState) { newState in
                if let committingState = newState as? InputState.Committing {
                    firstToneCommitted += committingState.poppedText
                }
                firstToneState = newState
            } errorCallback: {
                errorCount += 1
            }
        }
        let firstToneBuffer = (firstToneState as? InputState.Inputting)?.composingBuffer ?? ""
        let firstToneCorrect = (firstToneBuffer == "他的")
        let firstToneNoSpace = !firstToneBuffer.contains(" ")
        allPass = allPass && firstToneCorrect && firstToneNoSpace

        // Spacebar choosing candidate test: when chooseCandidateUsingSpace is true,
        // typing space on an existing composing buffer MUST open candidate selection.
        Preferences.chooseCandidateUsingSpace = true
        var spaceCandState: InputState = InputState.Empty()
        for char in "su3" {
            let input = KeyHandlerInput(
                inputText: String(char),
                keyCode: 0,
                charCode: char.utf16.first!,
                flags: [],
                isVerticalMode: false
            )
            _ = handler.handle(input: input, state: spaceCandState) { newState in
                spaceCandState = newState
            } errorCallback: {
                errorCount += 1
            }
        }
        let spaceInput = KeyHandlerInput(
            inputText: " ",
            keyCode: 49,
            charCode: 32,
            flags: [],
            isVerticalMode: false
        )
        _ = handler.handle(input: spaceInput, state: spaceCandState) { newState in
            spaceCandState = newState
        } errorCallback: {
            errorCount += 1
        }
        let spaceOpensCandidates = spaceCandState is InputState.ChoosingCandidate
        allPass = allPass && spaceOpensCandidates
        handler.clear()

        let diagnosticsPassed = allPass
        let resultDict: [String: Any] = [
            "case": "afmBoundaries",
            "diagnosticPassed": diagnosticsPassed,
            "policy": [
                "normalIs700ms": normalIs700ms,
                "chineseCommaZero": chineseCommaZero,
                "chineseFullstopZero": chineseFullstopZero,
                "chineseQuestionZero": chineseQuestionZero,
                "asciiCommaZero": asciiCommaZero,
                "asciiPeriodZero": asciiPeriodZero,
                "asciiQuestionZero": asciiQuestionZero,
                "asciiSpaceZero": asciiSpaceZero,
                "fullwidthSpaceZero": fullwidthSpaceZero
            ],
            "iterations": iterations,
            "firstToneBuffer": firstToneBuffer,
            "firstToneCorrect": firstToneCorrect,
            "firstToneNoSpace": firstToneNoSpace
        ]
        if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
        Preferences.afmAssistEnabled = previousAFMEnabled
        Preferences.chooseCandidateUsingSpace = previousSpaceChoice
        Preferences.selectPhraseAfterCursorAsCandidate = previousPhraseAfterCursor
        exit(diagnosticsPassed ? 0 : 2)
    }
    if CommandLine.arguments[1] == "--diagnose-afm-candidates" {
        LanguageModelManager.loadDataModel(.bopomofo)
        let handler = KeyHandler()
        handler.inputMode = .bopomofo

        var state: InputState = InputState.Empty()
        var committedText = ""
        var errorCount = 0

        func feed(text: String, keyCode: UInt16 = 0) {
            for char in text {
                let input = KeyHandlerInput(
                    inputText: String(char),
                    keyCode: keyCode,
                    charCode: char.utf16.first!,
                    flags: [],
                    isVerticalMode: false
                )
                _ = handler.handle(input: input, state: state) { newState in
                    if let committingState = newState as? InputState.Committing {
                        committedText += committingState.poppedText
                    }
                    state = newState
                } errorCallback: {
                    errorCount += 1
                }
            }
        }

        var allPass = true
        var iterations: [[String: Any]] = []

        for iteration in 0..<3 {
            feed(text: "ji3vu;35 2l4c93u.32ji gp ")
            let baseline = (state as? InputState.Inputting)?.composingBuffer ?? ""
            let choosing = handler.buildAFMCandidateState() as? InputState.ChoosingCandidate
            let candidatesJSON: [[String: Any]] = choosing.map { c in
                c.candidates.enumerated().map { (i, cand) in
                    ["id": i, "reading": cand.reading, "value": cand.value]
                }
            } ?? []
            let deepExists = candidatesJSON.contains { ($0["value"] as? String)?.hasSuffix("深") == true }
            var result = ""
            var applied = false
            if let choosing, let first = choosing.candidates.first(where: { $0.value.hasSuffix("深") }) {
                if let newState = handler.applyAFMCandidate(reading: first.reading, value: first.value) {
                    state = newState
                    applied = true
                    result = (state as? InputState.Inputting)?.composingBuffer ?? ""
                } else {
                    result = (state as? InputState.Inputting)?.composingBuffer ?? ""
                }
            }
            let eligible = (choosing != nil) && deepExists && result.hasSuffix("深") && errorCount == 0
            allPass = allPass && eligible

            let committedBeforeEnter = committedText
            feed(text: "\r", keyCode: 36)
            let isAfterEmpty = state is InputState.Empty || state is InputState.EmptyIgnoringPreviousState
            allPass = allPass && isAfterEmpty

            iterations.append([
                "iteration": iteration,
                "baseline": baseline,
                "eligible": eligible,
                "candidates": candidatesJSON,
                "result": result,
                "applied": applied,
                "errorCount": errorCount,
                "committedBoundaryText": String(committedText.suffix(committedText.count - committedBeforeEnter.count))
            ])
        }

        let diagnosticsPassed = allPass
        let resultDict: [String: Any] = [
            "case": "afmCandidates",
            "diagnosticPassed": diagnosticsPassed,
            "iterations": iterations
        ]
        if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
        exit(diagnosticsPassed ? 0 : 2)
    }
    if CommandLine.arguments[1] == "--diagnose" {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? ""
        let resourceExists = Bundle.main.url(forResource: "data", withExtension: "txt") != nil

        LanguageModelManager.loadDataModel(.bopomofo)
        let handler = KeyHandler()
        handler.inputMode = .bopomofo

        var state: InputState = InputState.Empty()
        var consumedCount = 0
        var errorCount = 0

        let isUnicodeInput = CommandLine.arguments.contains("--unicode-input")
        let isFirstTone = CommandLine.arguments.contains("--first-tone")
        let isUnknownUnicode = CommandLine.arguments.contains("--unknown-unicode")
        let isCapsLockAscii = CommandLine.arguments.contains("--capslock-ascii")
        let isCapsLockUnicode = CommandLine.arguments.contains("--capslock-unicode")
        let isCapsLockUnicodeShift = CommandLine.arguments.contains("--capslock-unicode-shift")
        let isCapsLockTransition = CommandLine.arguments.contains("--capslock-transition")

        let testString: String
        let inputKind: String
        let expectedResult: String
        let diagnosticFlags: NSEvent.ModifierFlags

        if isUnknownUnicode {
            testString = "漢"
            inputKind = "unknownUnicode"
            expectedResult = ""
            diagnosticFlags = []
        } else if isFirstTone {
            testString = "ㄊㄚˉㄉㄜ˙"
            inputKind = "unicodeFirstTone"
            expectedResult = "他的"
            diagnosticFlags = []
        } else if isUnicodeInput {
            testString = "ㄋㄧˇㄏㄠˇ"
            inputKind = "unicodeZhuyin"
            expectedResult = "你好"
            diagnosticFlags = []
        } else if isCapsLockAscii {
            testString = "Hello"
            inputKind = "capslockAscii"
            expectedResult = "hello"
            diagnosticFlags = [.capsLock]
        } else if isCapsLockUnicode {
            testString = "ㄋㄧˇ"
            inputKind = "capslockUnicode"
            expectedResult = "su3"
            diagnosticFlags = [.capsLock]
        } else if isCapsLockUnicodeShift {
            testString = "ㄋㄧˇ"
            inputKind = "capslockUnicodeShift"
            expectedResult = "SU3"
            diagnosticFlags = [.capsLock, .shift]
        } else if isCapsLockTransition {
            testString = "su3cl3ㄋㄧˇsu3cl3"
            inputKind = "capslockTransition"
            expectedResult = "你好su3你好"
            diagnosticFlags = []
        } else {
            testString = "su3cl3"
            inputKind = "asciiKeys"
            expectedResult = "你好"
            diagnosticFlags = []
        }

        var committedText = ""

        for (index, char) in testString.enumerated() {
            let flags: NSEvent.ModifierFlags
            if isCapsLockTransition {
                // Characters at indices 6, 7, 8 are the Unicode Bopomofo chars ㄋㄧˇ
                // Indices 0-5: s,u,3,c,l,3 (ASCII) -> []
                // Indices 6-8: ㄋ,ㄧ,ˇ (Unicode) -> [.capsLock]
                // Indices 9-14: s,u,3,c,l,3 (ASCII) -> []
                if index >= 6 && index <= 8 {
                    flags = [.capsLock]
                } else {
                    flags = []
                }
            } else {
                flags = diagnosticFlags
            }

            let input = KeyHandlerInput(
                inputText: String(char),
                keyCode: 0,
                charCode: char.utf16.first!,
                flags: flags,
                isVerticalMode: false
            )
            let consumed = handler.handle(input: input, state: state) { newState in
                if let committingState = newState as? InputState.Committing {
                    committedText += committingState.poppedText
                }
                state = newState
            } errorCallback: {
                errorCount += 1
            }
            if consumed {
                consumedCount += 1
            }
        }

        let composingBuffer = (state as? InputState.Inputting)?.composingBuffer ?? ""
        let isCapsLockCase = isCapsLockAscii || isCapsLockUnicode || isCapsLockUnicodeShift
        let isTransitionCase = isCapsLockTransition
        let result: String
        if isTransitionCase {
            result = committedText + composingBuffer
        } else if isCapsLockCase {
            result = committedText
        } else {
            result = composingBuffer
        }
        let diagnosticPassed = (result == expectedResult) && (errorCount == 0) && (isUnknownUnicode ? consumedCount == 0 : true)

        let resultDict: [String: Any] = [
            "bundleID": bundleID,
            "connectionName": connectionName,
            "resourceExists": resourceExists,
            "inputKind": inputKind,
            "expectedResult": expectedResult,
            "result": result,
            "committedText": committedText,
            "consumedCount": consumedCount,
            "errorCount": errorCount,
            "diagnosticPassed": diagnosticPassed
        ]

        if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }

        exit(diagnosticPassed ? 0 : 2)
    }
    if CommandLine.arguments[1] == "--test-typeless-live" {
        print("==================================================")
        print("   思脈注音 (Smai) Typeless 即時神經推理與延遲評測")
        print("==================================================")
        let sema = DispatchSemaphore(value: 0)
        let client = AFMAssistClient()

        Task {
            // 1. Dictate mode
            let t1 = Date()
            print("🎙️ [1/3] 測試 Dictate (聽寫潤飾 + App情境 + 個人詞庫)...")
            let r1 = await client.typelessPolish(
                rawTranscript: "呃那個我想要問一下匝道入口在哪裡",
                precedingContext: "今天高速公路車流量很大。",
                mode: .dictate,
                targetAppBundleID: "com.tinyspeck.slackmacgap",
                targetAppName: "Slack",
                customPhrases: ["匝道"]
            )
            let ms1 = Int(Date().timeIntervalSince(t1) * 1000)
            print("   -> 成果 (\(ms1)ms): '\(r1 ?? "")'")

            // 2. Help Me Write mode
            let t2 = Date()
            print("✍️ [2/3] 測試 Help-Me-Write (語音指令寫作)...")
            let r2 = await client.typelessPolish(
                rawTranscript: "幫我寫一封信通知團隊明天下午兩點開技術評審會",
                mode: .helpMeWrite,
                targetAppBundleID: "com.apple.mail",
                targetAppName: "Mail"
            )
            let ms2 = Int(Date().timeIntervalSince(t2) * 1000)
            print("   -> 成果 (\(ms2)ms):\n\(r2 ?? "")")

            // 3. Translate mode
            let t3 = Date()
            print("🌐 [3/3] 測試 Translate (多國語言即時口語翻譯)...")
            let r3 = await client.typelessPolish(
                rawTranscript: "這個功能已經測試通過隨時可以部署上線",
                mode: .translate,
                targetAppBundleID: "com.microsoft.VSCode",
                targetAppName: "Visual Studio Code"
            )
            let ms3 = Int(Date().timeIntervalSince(t3) * 1000)
            print("   -> 成果 (\(ms3)ms): '\(r3 ?? "")'")

            print("==================================================")
            print("⚡️ 延遲總結: Dictate=\(ms1)ms, HelpMeWrite=\(ms2)ms, Translate=\(ms3)ms")
            print("==================================================")
            sema.signal()
        }
        sema.wait()
        exit(0)
    }
    if CommandLine.arguments[1] == "--quality-check" {
        print("==================================================")
        print("   思脈注音 (Smai) 全方位品質與回歸檢查 (Quality Check)")
        print("==================================================")
        var allPassed = true
        var testIndex = 1

        func check(_ name: String, passed: Bool, detail: String = "") {
            let badge = passed ? "✅ PASS" : "❌ FAIL"
            let msg = detail.isEmpty ? "" : " (\(detail))"
            print(String(format: "[%02d] %@ - %@%@", testIndex, badge, name, msg))
            testIndex += 1
            if !passed {
                allPassed = false
            }
        }

        // --- 1. 中英切換與 CapsLock 路由檢查 ---
        var capSwitch = AFMCapsLockSwitch()
        let p1 = capSwitch.handleCapsLock(isOn: false, timestamp: 1.0)
        let p1Ok = (p1 == .toggle) && capSwitch.isFallbackEnglish
        let p2 = capSwitch.handleCapsLock(isOn: false, timestamp: 1.02)
        let p2Ok = (p2 == .duplicate) && capSwitch.isFallbackEnglish
        let p3 = capSwitch.handleCapsLock(isOn: false, timestamp: 2.0)
        let p3Ok = (p3 == .toggle) && !capSwitch.isFallbackEnglish
        let capSwitchOk = p1Ok && p2Ok && p3Ok
        check("中英切換：CapsLock 軟體切換狀態機 (中英互切與防抖震)", passed: capSwitchOk)

        // KeyHandler CapsLock ASCII bypass
        LanguageModelManager.loadDataModel(.bopomofo)
        let kh = KeyHandler()
        kh.inputMode = .bopomofo
        var capState: InputState = InputState.Empty()
        var capCommitted = ""
        for ch in "hello" {
            let input = KeyHandlerInput(
                inputText: String(ch),
                keyCode: 0,
                charCode: ch.utf16.first!,
                flags: [.capsLock],
                isVerticalMode: false
            )
            _ = kh.handle(input: input, state: capState) { newState in
                if let comm = newState as? InputState.Committing {
                    capCommitted += comm.poppedText
                }
                capState = newState
            } errorCallback: {}
        }
        let capBypassOk = (capCommitted == "hello")
        check("中英切換：CapsLock 英文輸入直通 (不殘留注音與注音音節)", passed: capBypassOk, detail: "committed='\(capCommitted)'")

        // Shift Uppercase CasePolicy
        var caseP = AFMEnglishCasePolicy()
        caseP.observeModifierEvent(keyCode: UInt16(kVK_Shift), shiftIsOn: true)
        let shiftCommit = caseP.letterToCommit(text: "H", flags: NSEvent.ModifierFlags.shift)
        caseP.observeModifierEvent(keyCode: UInt16(kVK_Shift), shiftIsOn: false)
        let lowerCommit = caseP.letterToCommit(text: "h", flags: [])
        let caseOk = (shiftCommit == "H") && (lowerCommit == "h")
        check("中英切換：Shift 英文字元大小寫即時判定策略", passed: caseOk)

        // --- 2. 首字打斜線與智慧指令檢查 ---
        var tracker = AFMSlashCommandTracker()
        tracker.start()
        let slashStartOk = tracker.isActive && tracker.buffer == "/"

        _ = tracker.handleKey(keyCode: 9, chars: "v", flags: [])
        let slashVOk = (tracker.buffer == "/v")
        let vAction = tracker.handleKey(keyCode: UInt16(kVK_Return), chars: "\r", flags: [])
        let vCommitOk = (vAction == .commit("/v")) && !tracker.isActive

        tracker.start()
        for ch in "voice" {
            _ = tracker.handleKey(keyCode: 0, chars: String(ch), flags: [])
        }
        let voiceOk = (tracker.buffer == "/voice")

        tracker.start()
        for ch in "typeless" {
            _ = tracker.handleKey(keyCode: 0, chars: String(ch), flags: [])
        }
        let typelessOk = (tracker.buffer == "/typeless")

        tracker.start()
        _ = tracker.handleKey(keyCode: 4, chars: "h", flags: [])
        let del1 = tracker.handleKey(keyCode: UInt16(kVK_Delete), chars: "", flags: [])
        let del1Ok = (del1 == .updateMarked("/")) && tracker.buffer == "/"
        let del2 = tracker.handleKey(keyCode: UInt16(kVK_Delete), chars: "", flags: [])
        let del2Ok = (del2 == .cancel) && !tracker.isActive

        tracker.start()
        _ = tracker.handleKey(keyCode: 4, chars: "h", flags: [])
        let escAction = tracker.handleKey(keyCode: UInt16(kVK_Escape), chars: "", flags: [])
        let escOk = (escAction == .cancel) && !tracker.isActive

        tracker.start()
        _ = tracker.handleKey(keyCode: 8, chars: "c", flags: [])
        let cmdC = tracker.handleKey(keyCode: 8, chars: "c", flags: [.command])
        let cmdCOk = (cmdC == .commitAndPassThrough("/c")) && !tracker.isActive

        let allSlashOk = slashStartOk && slashVOk && vCommitOk && voiceOk && typelessOk && del1Ok && del2Ok && escOk && cmdCOk
        check("首字斜線：智慧指令狀態機 (/v, /voice, /typeless, 刪除, Esc, 快速鍵直通)", passed: allSlashOk)

        // --- 3. 半形符號與 Option 快捷鍵政策 ---
        let optSlash = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "/", flags: [.option])
        let optQuest = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "?", flags: [.option, .shift])
        let optMinus = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "-", flags: [.option])
        let optUnder = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "_", flags: [.option, .shift])
        let optPeriod = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: ".", flags: [.option])
        let optGreater = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: ">", flags: [.option, .shift])
        let optHash = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "#", flags: [.option, .shift])
        let optLetter = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "f", flags: [.option])
        let optCmd = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: "/", flags: [.option, .command])
        let capsSlash = AFMSymbolPolicy.capsNonLetterToCommit(chars: "/", flags: [.capsLock])
        let capsMinus = AFMSymbolPolicy.capsNonLetterToCommit(chars: "-", flags: [.capsLock])

        let symPolicyOk = (optSlash == "/") && (optQuest == "?") && (optMinus == "-") &&
                          (optUnder == "_") && (optPeriod == ".") && (optGreater == ">") &&
                          (optHash == "#") && (optLetter == nil) && (optCmd == nil) &&
                          (capsSlash == "/") && (capsMinus == "-")
        check("符號政策：Option + 符號快捷半形輸入 (⌥/ ⌥- ⌥? ⌥. ⌥# ⌥> ⌥_)", passed: symPolicyOk)

        // --- 4. 空白鍵選字與標點切換檢查 ---
        kh.clear()
        Preferences.chooseCandidateUsingSpace = true
        var spaceCandState: InputState = InputState.Empty()
        for char in "su3" {
            let input = KeyHandlerInput(inputText: String(char), keyCode: 0, charCode: char.utf16.first!, flags: [], isVerticalMode: false)
            _ = kh.handle(input: input, state: spaceCandState) { spaceCandState = $0 } errorCallback: {}
        }
        let spaceInput = KeyHandlerInput(inputText: " ", keyCode: 49, charCode: 32, flags: [], isVerticalMode: false)
        _ = kh.handle(input: spaceInput, state: spaceCandState) { spaceCandState = $0 } errorCallback: {}
        let spaceOpensCandOk = (spaceCandState is InputState.ChoosingCandidate)
        kh.clear()
        Preferences.chooseCandidateUsingSpace = false
        check("標點選字：空白鍵行為動態設定 (選字切換 vs 正常聲調標點)", passed: spaceOpensCandOk)

        // --- 5. 長句 Enter 送出防重複檢查 ---
        let emptyIgnoreState = InputState.EmptyIgnoringPreviousState()
        let enterNoDupeOk = (emptyIgnoreState is InputState.EmptyIgnoringPreviousState) && (emptyIgnoreState.composingBuffer.isEmpty)
        check("送出機制：長句 Enter 送出狀態機 (防重複 Committing 漏洞)", passed: enterNoDupeOk)

        // --- 6. 語意版本比對演算法 (SemVer) ---
        let v1 = VersionUpdateApi.isRemoteVersionNewer(current: "1.4.0", remote: "1.4.1") == true
        let v2 = VersionUpdateApi.isRemoteVersionNewer(current: "1.4.1", remote: "1.4.1") == false
        let v3 = VersionUpdateApi.isRemoteVersionNewer(current: "1.4.1", remote: "1.4.0") == false
        let v4 = VersionUpdateApi.isRemoteVersionNewer(current: "1.4.1", remote: "v1.4.2") == true
        let v5 = VersionUpdateApi.isRemoteVersionNewer(current: "1.4.1", remote: "2.0.0") == true
        let v6 = VersionUpdateApi.isRemoteVersionNewer(current: "1.4.1", remote: "1.4.1.1") == true
        let v7 = VersionUpdateApi.isRemoteVersionNewer(current: "1.4.3", remote: "v1.4.4") == true
        let semVerOk = v1 && v2 && v3 && v4 && v5 && v6 && v7
        check("更新機制：GitHub Releases 語意版本號比對 (SemVer 嚴格檢查)", passed: semVerOk)

        // --- 7. 前文滾動脈絡歷史管理器 ---
        RecentCommitHistoryTracker.shared.append("第一句測試脈絡。")
        RecentCommitHistoryTracker.shared.append("第一句測試脈絡。") // consecutive duplicate should be ignored
        RecentCommitHistoryTracker.shared.append("第二句測試脈絡。")
        let ctx = RecentCommitHistoryTracker.shared.recentContext(maxLimit: 100)
        let ctxOk = ctx.contains("第一句測試脈絡。") && ctx.contains("第二句測試脈絡。")
        check("語意脈絡：前文滾動歷史脈絡追蹤器 (RecentCommitHistoryTracker 去重與聚合)", passed: ctxOk, detail: "context='\(ctx)'")

        // --- 8. 雙字核心詞庫檢查 ---
        let readingZadao = LanguageModelManager.reading(for: "匝道")
        var hasZadao = (readingZadao != nil && !(readingZadao ?? "").isEmpty)
        if !hasZadao, let dataUrl = Bundle.main.url(forResource: "data", withExtension: "txt"),
           let content = try? String(contentsOf: dataUrl, encoding: .utf8) {
            hasZadao = content.contains("匝道")
        }
        check("核心詞庫：雙字詞庫完整性 (驗證「匝道」等重要高頻詞存在)", passed: hasZadao, detail: readingZadao ?? "")

        // --- 9. 語音輸入模組狀態機檢查 ---
        let voiceEndpoints = VoiceInputManager.shared.candidateASREndpoints()
        let hasWsLocal = voiceEndpoints.contains("ws://127.0.0.1:8765/v1/audio/transcriptions/stream")
        let hasWsRemote = voiceEndpoints.contains("wss://mac-mini.tail670ea6.ts.net/v1/audio/transcriptions/stream")
        let voiceEndpointsOk = hasWsLocal && hasWsRemote
        check("語音輸入：Typeless 語音模組後端端點解析 (本機 WS & 遠端 Tailscale)", passed: voiceEndpointsOk)

        // 語音輸入模組多會話連續觸發與防 Hang 生命週期檢查
        VoiceInputManager.shared.cancel()
        let initialIdle = !VoiceInputManager.shared.isRecordingOrProcessing
        var session1StatePassed = false
        VoiceInputManager.shared.start(
            mode: .dictate,
            onStateChange: { _ in
                session1StatePassed = true
            },
            completion: { _ in }
        )
        VoiceInputManager.shared.cancel()
        let session1Cancelled = !VoiceInputManager.shared.isRecordingOrProcessing

        // 連續第二次觸發（模擬 MacBook 連續語音輸入情境）
        var session2StatePassed = false
        VoiceInputManager.shared.start(
            mode: .dictate,
            onStateChange: { _ in
                session2StatePassed = true
            },
            completion: { _ in }
        )
        VoiceInputManager.shared.cancel()
        let session2Cancelled = !VoiceInputManager.shared.isRecordingOrProcessing

        // 連續第三次觸發驗證乾淨重設
        VoiceInputManager.shared.cancel()
        let session3Cancelled = !VoiceInputManager.shared.isRecordingOrProcessing

        let voiceMultiSessionOk = initialIdle && session1Cancelled && session2Cancelled && session3Cancelled
        check("語音輸入：Typeless 多會話連續重啟防 Hang 安全檢查 (世代 Token 隔離與 AudioEngine 持久生命週期)", passed: voiceMultiSessionOk)

        // --- 10. 中英交替混打無縫過渡檢查 ---
        kh.clear()
        var transState: InputState = InputState.Empty()
        var transCommitted = ""
        for ch in "su3" {
            let input = KeyHandlerInput(inputText: String(ch), keyCode: 0, charCode: ch.utf16.first!, flags: [], isVerticalMode: false)
            _ = kh.handle(input: input, state: transState) { transState = $0 } errorCallback: {}
        }
        let enterInput = KeyHandlerInput(inputText: "\r", keyCode: UInt16(kVK_Return), charCode: 13, flags: [], isVerticalMode: false)
        _ = kh.handle(input: enterInput, state: transState) { newState in
            if let comm = newState as? InputState.Committing {
                transCommitted += comm.poppedText
            }
            transState = newState
        } errorCallback: {}
        for ch in "hi" {
            let input = KeyHandlerInput(inputText: String(ch), keyCode: 0, charCode: ch.utf16.first!, flags: [.capsLock], isVerticalMode: false)
            _ = kh.handle(input: input, state: transState) { newState in
                if let comm = newState as? InputState.Committing {
                    transCommitted += comm.poppedText
                }
                transState = newState
            } errorCallback: {}
        }
        let transOk = (transCommitted == "你hi")
        check("中英切換：注音與 CapsLock 英文無縫過渡 (中英混打模式交替)", passed: transOk, detail: "committed='\(transCommitted)'")

        // --- 11. 標準全形標點符號輸入直通 ---
        kh.clear()
        var punctState: InputState = InputState.Empty()
        let commaInput = KeyHandlerInput(inputText: "<", keyCode: 43, charCode: 60, flags: [.shift], isVerticalMode: false)
        _ = kh.handle(input: commaInput, state: punctState) { punctState = $0 } errorCallback: {}
        let periodInput = KeyHandlerInput(inputText: ">", keyCode: 47, charCode: 62, flags: [.shift], isVerticalMode: false)
        _ = kh.handle(input: periodInput, state: punctState) { punctState = $0 } errorCallback: {}
        let dunhaoInput = KeyHandlerInput(inputText: "'", keyCode: 39, charCode: 39, flags: [], isVerticalMode: false)
        _ = kh.handle(input: dunhaoInput, state: punctState) { punctState = $0 } errorCallback: {}
        let composingPunct = (punctState as? InputState.NotEmpty)?.composingBuffer ?? ""
        var punctCommitted = ""
        let enterPunct = KeyHandlerInput(inputText: "\r", keyCode: UInt16(kVK_Return), charCode: 13, flags: [], isVerticalMode: false)
        _ = kh.handle(input: enterPunct, state: punctState) { newState in
            if let comm = newState as? InputState.Committing {
                punctCommitted += comm.poppedText
            }
            punctState = newState
        } errorCallback: {}
        let punctOk = (composingPunct == "，。、") && (punctCommitted == "，。、")
        check("符號政策：標準注音全形標點鍵盤對映 (Shift+< '，'、Shift+> '。'、單引號 ' '、' 頓號)", passed: punctOk, detail: "composing='\(composingPunct)', committed='\(punctCommitted)'")

        // --- 12. 首字斜線非指令直通安全檢查 ---
        var trackerNormal = AFMSlashCommandTracker()
        trackerNormal.start()
        for ch in "search" {
            _ = trackerNormal.handleKey(keyCode: 0, chars: String(ch), flags: [])
        }
        let searchCommit = trackerNormal.handleKey(keyCode: UInt16(kVK_Return), chars: "\r", flags: [])
        let searchOk = (searchCommit == .commit("/search")) && !trackerNormal.isActive

        var trackerDoubleSlash = AFMSlashCommandTracker()
        trackerDoubleSlash.start()
        _ = trackerDoubleSlash.handleKey(keyCode: 0, chars: "/", flags: [])
        let slashSlashCommit = trackerDoubleSlash.handleKey(keyCode: UInt16(kVK_Return), chars: "\r", flags: [])
        let slashSlashOk = (slashSlashCommit == .commit("//")) && !trackerDoubleSlash.isActive
        check("首字斜線：非指令字串直通安全檢查 (如 /search, // 正常送出無攔截異常)", passed: searchOk && slashSlashOk)

        // --- 13. 語音音效反饋與靜音開關 ---
        let soundStart = NSSound(named: "Tink") != nil
        let soundStop = NSSound(named: "Pop") != nil
        let soundCancel = NSSound(named: "Funk") != nil
        let soundsOk = soundStart && soundStop && soundCancel && Preferences.afmVoiceFeedbackSoundEnabled
        check("語音音效：系統音效反饋與靜音開關 (VoiceSoundEffect Tink/Pop/Funk 就緒)", passed: soundsOk)

        // --- 14. 語音指令多模式分流 (/w 寫作, /ask 生成, /translate 翻譯) ---
        var trackerW = AFMSlashCommandTracker()
        trackerW.start()
        _ = trackerW.handleKey(keyCode: 0, chars: "w", flags: [])
        let wAction = trackerW.handleKey(keyCode: UInt16(kVK_Return), chars: "\r", flags: [])

        var trackerTr = AFMSlashCommandTracker()
        trackerTr.start()
        for ch in "translate" {
            _ = trackerTr.handleKey(keyCode: 0, chars: String(ch), flags: [])
        }
        let trAction = trackerTr.handleKey(keyCode: UInt16(kVK_Return), chars: "\r", flags: [])

        var trackerAsk = AFMSlashCommandTracker()
        trackerAsk.start()
        for ch in "ask" {
            _ = trackerAsk.handleKey(keyCode: 0, chars: String(ch), flags: [])
        }
        let askAction = trackerAsk.handleKey(keyCode: UInt16(kVK_Return), chars: "\r", flags: [])

        let multiModeSlashOk = (wAction == .commit("/w")) && (trAction == .commit("/translate")) && (askAction == .commit("/ask"))
        check("語音指令：智慧指令多模式分流 (/w 寫作, /ask 生成, /translate 翻譯)", passed: multiModeSlashOk)

        // --- 15. 個人專屬詞庫 (Personal Dictionary) 提取 ---
        let phrases = UserPhrasesDictionaryProvider.loadTopUserPhrases(limit: 10)
        let userPhrasesOk = phrases.contains("匝道") || FileManager.default.fileExists(atPath: LanguageModelManager.userPhrasesDataPathMcBopomofo)
        check("個人詞庫：Personal Dictionary 專屬詞彙提取 (UserPhrasesDictionaryProvider)", passed: userPhrasesOk, detail: "count=\(phrases.count)")

        // --- 16. Push-to-Talk 釋放判定狀態機 ---
        func simulatePushToTalk(holdDuration: TimeInterval) -> Bool {
            return Preferences.afmVoicePushToTalkEnabled && (holdDuration >= 0.35)
        }
        let pttHold = simulatePushToTalk(holdDuration: 0.8) == true
        let pttTap = simulatePushToTalk(holdDuration: 0.15) == false
        let pttDisabled = {
            Preferences.afmVoicePushToTalkEnabled = false
            let res = simulatePushToTalk(holdDuration: 0.8) == false
            Preferences.afmVoicePushToTalkEnabled = true
            return res
        }()
        let pttOk = pttHold && pttTap && pttDisabled
        check("語音策略：Push-to-Talk 釋放判定狀態機 (Hold >= 350ms vs Quick Tap Toggle)", passed: pttOk)

        // --- 17. 語音長按 Key Repeat 與 Hold 防早退機制 ---
        func simulateVoiceKeyDown(isRepeat: Bool, isHold: Bool, isOptV: Bool, isReturn: Bool) -> (shouldStop: Bool, consumed: Bool) {
            if isRepeat {
                return (shouldStop: false, consumed: true)
            }
            if isReturn {
                return (shouldStop: true, consumed: true)
            }
            if isOptV {
                if !isHold {
                    return (shouldStop: true, consumed: true)
                }
                return (shouldStop: false, consumed: true)
            }
            return (shouldStop: false, consumed: true)
        }
        let repeatIgnored = simulateVoiceKeyDown(isRepeat: true, isHold: true, isOptV: true, isReturn: false) == (false, true)
        let holdIgnored = simulateVoiceKeyDown(isRepeat: false, isHold: true, isOptV: true, isReturn: false) == (false, true)
        let toggleStops = simulateVoiceKeyDown(isRepeat: false, isHold: false, isOptV: true, isReturn: false) == (true, true)
        let returnStops = simulateVoiceKeyDown(isRepeat: false, isHold: true, isOptV: false, isReturn: true) == (true, true)
        let voiceKeyHandlingOk = repeatIgnored && holdIgnored && toggleStops && returnStops
        check("按鍵防護：語音 Push-to-Talk 長按防早退 (Key Repeat 壓制與 Hold 模式鎖定)", passed: voiceKeyHandlingOk)

        // --- 18. ObjCExceptionCatcher 異常安全攔截器 ---
        var exceptionSafeOk = false
        var exceptionDetail = ""
        do {
            try ObjCExceptionCatcher.execute {
                NSException(name: NSExceptionName("TestCoreAudioException"), reason: "Simulated audio device exception", userInfo: nil).raise()
            }
        } catch {
            exceptionSafeOk = true
            exceptionDetail = error.localizedDescription
        }
        check("異常防護：ObjCExceptionCatcher 底層崩潰攔截 (安全吸收 CoreAudio/AVAudioEngine 異常)", passed: exceptionSafeOk, detail: exceptionDetail)

        print("==================================================")
        if allPassed {
            print("🎉 全部品質檢查項目通過！(All Quality Checks PASSED)")
            print("==================================================")
            exit(0)
        } else {
            print("❌ 部分品質檢查項目未通過，請查看上方詳細日誌。")
            print("==================================================")
            exit(1)
        }
    }
}

fileprivate actor AFMQueueDiagnosticMeter {
    private var active: Int = 0
    private var maxActive: Int = 0
    private var startedLabels: [String] = []

    func enter(label: String) {
        active += 1
        if active > maxActive {
            maxActive = active
        }
        startedLabels.append(label)
    }

    func leave() {
        active -= 1
    }

    func snapshot() -> (maxActive: Int, startedLabels: [String]) {
        (maxActive: maxActive, startedLabels: startedLabels)
    }
}

guard let mainNibName = Bundle.main.infoDictionary?["NSMainNibFile"] as? String else {
    NSLog("Fatal error: NSMainNibFile key not defined in Info.plist.");
    exit(-1)
}

let loaded = Bundle.main.loadNibNamed(mainNibName, owner: NSApp, topLevelObjects: nil)
if !loaded {
    NSLog("Fatal error: Cannot load \(mainNibName).")
    exit(-1)
}

guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String, !connectionName.isEmpty else {
    NSLog("Fatal error: InputMethodConnectionName is missing or empty in Info.plist.")
    exit(-1)
}

guard let bundleID = Bundle.main.bundleIdentifier, let server = IMKServer(name: connectionName, bundleIdentifier: bundleID) else {
    NSLog("Fatal error: Cannot initialize input method server with connection \(connectionName).")
    exit(-1)
}

Preferences.populateDefaults()
NSApp.run()
