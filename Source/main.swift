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
        let normalIs700ms = (normalDelay == 700_000_000)
        let chineseCommaZero = (AFMTriggerPolicy.delayNanoseconds(for: "，") == 0)
        let chineseFullstopZero = (AFMTriggerPolicy.delayNanoseconds(for: "。") == 0)
        let chineseQuestionZero = (AFMTriggerPolicy.delayNanoseconds(for: "？") == 0)
        let asciiCommaZero = (AFMTriggerPolicy.delayNanoseconds(for: ",") == 0)
        let asciiPeriodZero = (AFMTriggerPolicy.delayNanoseconds(for: ".") == 0)
        let asciiQuestionZero = (AFMTriggerPolicy.delayNanoseconds(for: "?") == 0)
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
            Preferences.chooseCandidateUsingSpace = iteration < 4
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
