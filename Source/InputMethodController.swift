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

import CandidateUI
import Carbon
import Cocoa
import CoreGraphics
import InputMethodKit
import InputSourceHelper
import NotifierUI
import OpenCCBridge
import SystemCharacterInfo
import TooltipUI

extension Bool {
    fileprivate var state: NSControl.StateValue {
        self ? .on : .off
    }
}

private let kMinKeyLabelSize: CGFloat = 10

struct AFMTriggerPolicy {
    static func delayNanoseconds(for text: String) -> UInt64 {
        guard let lastChar = text.last else {
            return 700_000_000
        }
        let punctuationSet: Set<Character> = ["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":", " ", "\u{3000}"]
        if punctuationSet.contains(lastChar) {
            return 0
        }
        return 700_000_000
    }
}

struct AFMCapsLockSwitch {
    enum Decision {
        case native
        case toggle
        case duplicate
    }

    private(set) var isFallbackEnglish: Bool = false
    private var nativeCapsOn: Bool = false
    private var lastZeroCapsTimestamp: TimeInterval?

    mutating func observeNativeCapsOn() {
        nativeCapsOn = true
        isFallbackEnglish = false
        lastZeroCapsTimestamp = nil
    }

    mutating func handleCapsLock(isOn: Bool, timestamp: TimeInterval) -> Decision {
        if isOn {
            observeNativeCapsOn()
            return .native
        }
        if nativeCapsOn {
            nativeCapsOn = false
            isFallbackEnglish = false
            lastZeroCapsTimestamp = timestamp
            return .native
        }
        if let lastTimestamp = lastZeroCapsTimestamp {
            let delta = timestamp - lastTimestamp
            if delta >= 0 && delta < 0.15 {
                return .duplicate
            }
        }
        lastZeroCapsTimestamp = timestamp
        isFallbackEnglish.toggle()
        return .toggle
    }
}

struct AFMEnglishCasePolicy {
    private(set) var physicalShiftIsDown: Bool = false

    mutating func observeModifierEvent(keyCode: UInt16, shiftIsOn: Bool) {
        if keyCode == UInt16(kVK_Shift) || keyCode == UInt16(kVK_RightShift) {
            physicalShiftIsDown = shiftIsOn
        }
    }

    mutating func resetShiftTracking() {
        physicalShiftIsDown = false
    }

    func letterToCommit(text: String?, flags: NSEvent.ModifierFlags) -> String? {
        guard let text = text, text.utf16.count == 1 else {
            return nil
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return nil
        }
        guard let scalar = text.unicodeScalars.first else {
            return nil
        }
        let value = scalar.value
        guard (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A) else {
            return nil
        }
        let useUppercase = physicalShiftIsDown || (flags.contains(.capsLock) && flags.contains(.shift))
        return useUppercase ? text.uppercased() : text.lowercased()
    }
}

internal var gCurrentCandidateController: CandidateController?

extension CandidateController {
    static let horizontal = HorizontalCandidateController()
    static let vertical = VerticalCandidateController()
}

@objc(McBopomofoInputMethodController)
class McBopomofoInputMethodController: IMKInputController {

    private static let tooltipController = TooltipController()

    // MARK: -

    var currentClient: Any?
    var keyHandler: KeyHandler = KeyHandler()
    var state: InputState = InputState.Empty()

    private let afmClient = AFMAssistClient()
    private let afmRequestGate = AFMRequestGate()
    private var afmTask: Task<Void, Never>?

    private let afmDiagnosticsMarkerPath = "/Users/Shared/McBopomofoAFM-diagnostics.enabled"
    private let afmDiagnosticsMaxEvents = 200
    private var afmDiagnosticsEventCount = 0

    private static var capsLockSwitch = AFMCapsLockSwitch()
    private static var casePolicy = AFMEnglishCasePolicy()

    // Share the stored issues, so a set of issues is shown as notification only once.
    static var latestUserFileIssues: [String] = []

    // MARK: - IMKInputController methods

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        keyHandler.delegate = self
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Input Method Menu")

        let chineseConversionItem = menu.addItem(
            withTitle: NSLocalizedString("Convert to Simplified Chinese", comment: ""),
            action: #selector(toggleChineseConverter(_:)), keyEquivalent: "g")
        chineseConversionItem.keyEquivalentModifierMask = [.command, .control]
        chineseConversionItem.state = Preferences.chineseConversionEnabled.state

        let halfWidthPunctuationItem = menu.addItem(
            withTitle: NSLocalizedString("Use Half-Width Punctuations", comment: ""),
            action: #selector(toggleHalfWidthPunctuation(_:)), keyEquivalent: "h")
        halfWidthPunctuationItem.keyEquivalentModifierMask = [.command, .control]
        halfWidthPunctuationItem.state = Preferences.halfWidthPunctuationEnabled.state
        let associatedPhrasesItem = menu.addItem(
            withTitle: NSLocalizedString("Associated Phrases", comment: ""),
            action: #selector(toggleAssociatedPhrasesEnabled(_:)), keyEquivalent: "")
        associatedPhrasesItem.state = Preferences.associatedPhrasesEnabled.state

        let inputMode = keyHandler.inputMode

        // Only Bopomofo mode supports Bopomofo Font Annotation. If support is
        // on, ensure that the user has a way to disable it. Otherwise, only
        // show the item when it is set to show in the input menu.
        if inputMode == .bopomofo
            && (Preferences.showBopomofoFontAnnotationSupportItemInInputMenu
                || Preferences.bopomofoFontAnnotationSupportEnabled)
        {
            let bopomofoFontAnnotationSupportItem = menu.addItem(
                withTitle: NSLocalizedString("Bopomofo Font Annotation Support", comment: ""),
                action: #selector(toggleBopomofoFontAnnotationSupport(_:)), keyEquivalent: "")
            bopomofoFontAnnotationSupportItem.state =
                Preferences.bopomofoFontAnnotationSupportEnabled.state
        }

        let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
        if inputMode == .bopomofo && optionKeyPressed {
            let phaseReplacementItem = menu.addItem(
                withTitle: NSLocalizedString("Use Phrase Replacement", comment: ""),
                action: #selector(togglePhraseReplacement(_:)), keyEquivalent: "")
            phaseReplacementItem.state = Preferences.phraseReplacementEnabled.state
        }

        if inputMode == .bopomofo {
            let afmAssistItem = menu.addItem(
                withTitle: NSLocalizedString("AI-Assisted Candidate Selection", comment: ""),
                action: #selector(toggleAFMAssist(_:)), keyEquivalent: "")
            afmAssistItem.state = Preferences.afmAssistEnabled.state
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: NSLocalizedString("User Phrases", comment: ""), action: nil,
            keyEquivalent: "")

        if inputMode == .plainBopomofo {
            if Preferences.enableUserPhrasesInPlainBopomofo {
                menu.addItem(
                    withTitle: NSLocalizedString("Edit User Phrases", comment: ""),
                    action: #selector(openUserPhrasesPlainBopomofo(_:)), keyEquivalent: "")
            }
            menu.addItem(
                withTitle: NSLocalizedString("Edit Excluded Phrases", comment: ""),
                action: #selector(openExcludedPhrasesPlainBopomofo(_:)), keyEquivalent: "")
        } else {
            menu.addItem(
                withTitle: NSLocalizedString("Edit User Phrases", comment: ""),
                action: #selector(openUserPhrases(_:)), keyEquivalent: "")
            menu.addItem(
                withTitle: NSLocalizedString("Edit Excluded Phrases", comment: ""),
                action: #selector(openExcludedPhrasesMcBopomofo(_:)), keyEquivalent: "")
            if optionKeyPressed {
                menu.addItem(
                    withTitle: NSLocalizedString("Edit Phrase Replacement Table", comment: ""),
                    action: #selector(openPhraseReplacementMcBopomofo(_:)), keyEquivalent: "")
            }
        }

        menu.addItem(
            withTitle: NSLocalizedString("Reload User Phrases", comment: ""),
            action: #selector(reloadUserPhrases(_:)), keyEquivalent: "")

        if !McBopomofoInputMethodController.latestUserFileIssues.isEmpty {
            // Setting menuItem.image does not work in input method menus even on macOS 26,
            // so we just use the alert emoji in the menu item title.
            let menuItem = NSMenuItem(
                title: NSLocalizedString("Show Issues in User Files ⚠️", comment: ""),
                action: #selector(showUserFileIssues(_:)), keyEquivalent: "")
            menu.addItem(menuItem)
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: NSLocalizedString("McBopomofo Preferences", comment: ""),
            action: #selector(showPreferences(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: NSLocalizedString("Check for Updates…", comment: ""),
            action: #selector(checkForUpdate(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: NSLocalizedString("About McBopomofo…", comment: ""),
            action: #selector(showAbout(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - IMKStateSetting protocol methods

    override func activateServer(_ client: Any!) {
        cancelAFMRequest()
        UserDefaults.standard.synchronize()

        // Override the keyboard layout. Use US if not set.
        (client as? IMKTextInput)?.overrideKeyboard(
            withKeyboardNamed: Preferences.basisKeyboardLayout)
        // reset the state
        currentClient = client

        keyHandler.clear()
        keyHandler.syncWithPreferences()

        (NSApp.delegate as? AppDelegate)?.checkForUpdate()
    }

    override func deactivateServer(_ client: Any!) {
        cancelAFMRequest()
        currentClient = nil
        keyHandler.clear()
        Self.casePolicy.resetShiftTracking()
        self.handle(state: .Deactivated(), client: client)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client: Any!) {
        cancelAFMRequest()
        let newInputMode = InputMode(rawValue: value as? String ?? InputMode.bopomofo.rawValue)
        LanguageModelManager.loadDataModel(newInputMode)
        // Restore the client layout even when the internal input mode is unchanged.
        (client as? IMKTextInput)?.overrideKeyboard(
            withKeyboardNamed: Preferences.basisKeyboardLayout)
        if keyHandler.inputMode != newInputMode {
            UserDefaults.standard.synchronize()
            // Remember to override the keyboard layout again -- treat this as an activate event.
            keyHandler.clear()
            keyHandler.inputMode = newInputMode
            self.handle(state: .Empty(), client: client)
        }

        // Since setValue is called after activateServer, show user file issues here, if any.
        checkUserFileIssues()
    }

    // MARK: - IMKServerInput protocol methods

    override func commitComposition(_ client: Any!) {
        cancelAFMRequest()
        keyHandler.handleForceCommit(stateCallback: { newState in
            self.handle(state: newState, client: client)
        })
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        let events: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        return Int(events.rawValue)
    }

    override func handle(_ maybeEvent: NSEvent!, client: Any!) -> Bool {
        // nil may be passed, applefeedback://FB11472618
        guard let event = maybeEvent else {
            commitComposition(client)
            return false
        }

        let isDiagnosticEvent = (event.type == .keyDown || event.type == .flagsChanged)
        let beforeStateLabel = afmDiagnosticsStateLabel(for: state)
        let diagnosticEventKind = (event.type == .keyDown) ? "keydown" : "flags"
        let diagnosticKeyCategory = (event.keyCode == UInt16(kVK_CapsLock)) ? "capslock" : "other"
        let diagnosticCapsLock = event.modifierFlags.contains(.capsLock)
        let diagnosticShift = event.modifierFlags.contains(.shift)
        let diagnosticControl = event.modifierFlags.contains(.control)
        let diagnosticOption = event.modifierFlags.contains(.option)
        let diagnosticCommand = event.modifierFlags.contains(.command)
        let diagnosticTextLength: Int
        let diagnosticClassification: String
        if event.type == .keyDown {
            let chars = event.characters ?? ""
            diagnosticTextLength = chars.utf16.count
            diagnosticClassification = afmDiagnosticsClassify(text: chars)
        } else {
            diagnosticTextLength = 0
            diagnosticClassification = "none"
        }

        // Capture CG/session/HID/global/cap-key/fallback metadata only for eligible
        // keyDown/flags events, and only when the sentinel exists and we are below
        // the 200-event cap. This observes the actual state before any further
        // behavior fix.
        let diagnosticMeta: AFMDiagnosticsMeta?
        if isDiagnosticEvent
            && FileManager.default.fileExists(atPath: afmDiagnosticsMarkerPath)
            && afmDiagnosticsEventCount < afmDiagnosticsMaxEvents
        {
            let cgEvent = event.cgEvent
            let cgPresent = cgEvent != nil
            let cgCaps = cgEvent?.flags.contains(.maskAlphaShift) ?? false
            let cgShift = cgEvent?.flags.contains(.maskShift) ?? false
            let sessionCaps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
            let sessionShift = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
            let hidCaps = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
            let globalCaps = NSEvent.modifierFlags.contains(.capsLock)
            let capKeyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_CapsLock))
            let fallbackEnglish = Self.capsLockSwitch.isFallbackEnglish
            let physicalShiftIsDown = Self.casePolicy.physicalShiftIsDown
            let eventSeconds = Double(event.timestamp)
            let cgKind: String
            switch cgEvent?.type {
            case .keyDown:
                cgKind = "keydown"
            case .keyUp:
                cgKind = "keyup"
            case .flagsChanged:
                cgKind = "flags"
            case .null:
                cgKind = "none"
            default:
                cgKind = "other"
            }
            diagnosticMeta = AFMDiagnosticsMeta(
                cgPresent: cgPresent,
                cgCaps: cgCaps,
                cgShift: cgShift,
                sessionCaps: sessionCaps,
                sessionShift: sessionShift,
                hidCaps: hidCaps,
                globalCaps: globalCaps,
                capKeyDown: capKeyDown,
                fallbackEnglish: fallbackEnglish,
                eventSeconds: eventSeconds,
                cgKind: cgKind,
                physicalShiftIsDown: physicalShiftIsDown
            )
        } else {
            diagnosticMeta = nil
        }

        defer {
            if isDiagnosticEvent {
                let afterStateLabel = afmDiagnosticsStateLabel(for: state)
                afmDiagnosticsLog(
                    eventKind: diagnosticEventKind,
                    keyCategory: diagnosticKeyCategory,
                    capsLock: diagnosticCapsLock,
                    shift: diagnosticShift,
                    control: diagnosticControl,
                    option: diagnosticOption,
                    command: diagnosticCommand,
                    textLength: diagnosticTextLength,
                    classification: diagnosticClassification,
                    beforeState: beforeStateLabel,
                    afterState: afterStateLabel,
                    meta: diagnosticMeta
                )
            }
        }

        if event.type == .keyDown || event.type == .flagsChanged {
            cancelAFMRequest()
        }

        if event.type == .flagsChanged {
            Self.casePolicy.observeModifierEvent(
                keyCode: event.keyCode,
                shiftIsOn: event.modifierFlags.contains(.shift)
            )
            if event.keyCode == UInt16(kVK_CapsLock) {
                let decision = Self.capsLockSwitch.handleCapsLock(
                    isOn: event.modifierFlags.contains(.capsLock),
                    timestamp: event.timestamp
                )
                switch decision {
                case .native:
                    self.commitComposition(client)
                    (client as? IMKTextInput)?.overrideKeyboard(withKeyboardNamed: Preferences.basisKeyboardLayout)
                    return false
                case .duplicate:
                    return true
                case .toggle:
                    self.commitComposition(client)
                    keyHandler.clear()
                    self.handle(state: .Empty(), client: client)
                    (client as? IMKTextInput)?.overrideKeyboard(withKeyboardNamed: Preferences.basisKeyboardLayout)
                    return true
                }
            }

            if Preferences.switchInputSourceUponCommandKeyPressEnabled,
               (event.keyCode == UInt16(kVK_Command) || event.keyCode == UInt16(kVK_RightCommand)),
               event.modifierFlags.contains(.command) {
                keyHandler.clear()
                handle(state: InputState.SwitchingInputSource(sourceID: Preferences.switchInputSourceUponCommandKeyPressInputSourceID), client: client)
                return false
            }

            if state is InputState.Empty {
                return false
            }
            // Handle key up events during active input state.
            //
            // This prevents double-space from affecting the current input.
            // While macOS may normally insert a period on double space, this
            // should be suppressed when there is an active composing buffer or
            // candidate window.
            return true
        }

        if event.type == .flagsChanged {
            let functionKeyKeyboardLayoutID = Preferences.functionKeyboardLayout
            let basisKeyboardLayoutID = Preferences.basisKeyboardLayout

            if functionKeyKeyboardLayoutID == basisKeyboardLayoutID {
                return false
            }

            let includeShift = Preferences.functionKeyKeyboardLayoutOverrideIncludeShiftKey
            let notShift = NSEvent.ModifierFlags(rawValue: ~(NSEvent.ModifierFlags.shift.rawValue))
            if event.modifierFlags.contains(notShift)
                || (event.modifierFlags.contains(.shift) && includeShift)
            {
                (client as? IMKTextInput)?.overrideKeyboard(
                    withKeyboardNamed: functionKeyKeyboardLayoutID)
                return false
            }
            (client as? IMKTextInput)?.overrideKeyboard(withKeyboardNamed: basisKeyboardLayoutID)
            return false
        }

        if event.type == .keyDown {
            if event.modifierFlags.contains(.capsLock) {
                Self.capsLockSwitch.observeNativeCapsOn()
            }
            if event.modifierFlags.contains(.capsLock) || Self.capsLockSwitch.isFallbackEnglish {
                if let client = client as? IMKTextInput,
                   let letter = Self.casePolicy.letterToCommit(
                       text: event.characters,
                       flags: event.modifierFlags
                   ) {
                    self.commit(text: letter, client: client)
                    return true
                }
                if Self.capsLockSwitch.isFallbackEnglish {
                    return false
                }
            }
        }

        var textFrame = NSRect.zero
        let attributes: [AnyHashable: Any]? = (client as? IMKTextInput)?.attributes(
            forCharacterIndex: 0, lineHeightRectangle: &textFrame)
        let useVerticalMode =
            (attributes?["IMKTextOrientation"] as? NSNumber)?.intValue == 0 || false
        let input = KeyHandlerInput(event: event, isVerticalMode: useVerticalMode)

        let result = keyHandler.handle(input: input, state: state) { newState in
            self.handle(state: newState, client: client)
        } errorCallback: {
            if Preferences.beepUponInputError {
                NSSound.beep()
            }
        }

        return result
    }

    private func afmDiagnosticsStateLabel(for state: InputState) -> String {
        if state is InputState.Empty {
            return "Empty"
        } else if state is InputState.Inputting {
            return "Inputting"
        } else if state is InputState.ChoosingCandidate {
            return "ChoosingCandidate"
        } else if state is InputState.Committing {
            return "Committing"
        } else {
            return "other"
        }
    }

    private func afmDiagnosticsClassify(text: String) -> String {
        guard !text.isEmpty else {
            return "none"
        }

        var hasAscii = false
        var hasBpmf = false
        var hasTone = false
        var hasOther = false

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 0x00 && value <= 0x7F {
                hasAscii = true
            } else if value >= 0x3105 && value <= 0x3129 {
                hasBpmf = true
            } else if value == 0x02CA || value == 0x02C7 || value == 0x02CB || value == 0x02D9 || value == 0x02C9 {
                hasTone = true
            } else {
                hasOther = true
            }
        }

        let categories: [Bool] = [hasAscii, hasBpmf, hasTone, hasOther]
        let activeCount = categories.filter { $0 }.count

        if hasBpmf && hasTone && !hasAscii && !hasOther {
            return "bpmfTone"
        }
        if activeCount > 1 {
            return "mixed"
        }
        if hasBpmf {
            return "bpmf"
        }
        if hasTone {
            return "tone"
        }
        if hasAscii {
            return "ascii"
        }
        if hasOther {
            return "other"
        }
        return "none"
    }

    private struct AFMDiagnosticsMeta {
        let cgPresent: Bool
        let cgCaps: Bool
        let cgShift: Bool
        let sessionCaps: Bool
        let sessionShift: Bool
        let hidCaps: Bool
        let globalCaps: Bool
        let capKeyDown: Bool
        let fallbackEnglish: Bool
        let eventSeconds: Double
        let cgKind: String
        let physicalShiftIsDown: Bool
    }

    private func afmDiagnosticsLog(
        eventKind: String,
        keyCategory: String,
        capsLock: Bool,
        shift: Bool,
        control: Bool,
        option: Bool,
        command: Bool,
        textLength: Int,
        classification: String,
        beforeState: String,
        afterState: String,
        meta: AFMDiagnosticsMeta?
    ) {
        guard FileManager.default.fileExists(atPath: afmDiagnosticsMarkerPath) else {
            return
        }
        guard afmDiagnosticsEventCount < afmDiagnosticsMaxEvents else {
            return
        }
        afmDiagnosticsEventCount += 1
        if let meta = meta {
            NSLog(
                "AFM_INPUT_DIAGNOSTIC kind=%@ key=%@ caps=%@ shift=%@ ctrl=%@ opt=%@ cmd=%@ len=%d class=%@ before=%@ after=%@ cgPresent=%@ cgCaps=%@ cgShift=%@ sessionCaps=%@ sessionShift=%@ hidCaps=%@ globalCaps=%@ capKeyDown=%@ fallbackEnglish=%@ eventSeconds=%f cgKind=%@ physicalShiftIsDown=%@",
                eventKind,
                keyCategory,
                capsLock ? "1" : "0",
                shift ? "1" : "0",
                control ? "1" : "0",
                option ? "1" : "0",
                command ? "1" : "0",
                textLength,
                classification,
                beforeState,
                afterState,
                meta.cgPresent ? "1" : "0",
                meta.cgCaps ? "1" : "0",
                meta.cgShift ? "1" : "0",
                meta.sessionCaps ? "1" : "0",
                meta.sessionShift ? "1" : "0",
                meta.hidCaps ? "1" : "0",
                meta.globalCaps ? "1" : "0",
                meta.capKeyDown ? "1" : "0",
                meta.fallbackEnglish ? "1" : "0",
                meta.eventSeconds,
                meta.cgKind,
                meta.physicalShiftIsDown ? "1" : "0"
            )
        } else {
            NSLog(
                "AFM_INPUT_DIAGNOSTIC kind=%@ key=%@ caps=%@ shift=%@ ctrl=%@ opt=%@ cmd=%@ len=%d class=%@ before=%@ after=%@",
                eventKind,
                keyCategory,
                capsLock ? "1" : "0",
                shift ? "1" : "0",
                control ? "1" : "0",
                option ? "1" : "0",
                command ? "1" : "0",
                textLength,
                classification,
                beforeState,
                afterState
            )
        }
    }

    // MARK: - Menu Items

    @objc override func showPreferences(_ sender: Any?) {
        super.showPreferences(sender)
    }

    @objc func toggleChineseConverter(_ sender: Any?) {
        let enabled = Preferences.toggleChineseConversionEnabled()
        NotifierController.notify(
            message: enabled
                ? NSLocalizedString("Chinese Conversion On", comment: "")
                : NSLocalizedString("Chinese Conversion Off", comment: ""))
        if let currentClient = currentClient {
            keyHandler.clear()
            self.handle(state: InputState.Empty(), client: currentClient)
        }
    }

    @objc func toggleHalfWidthPunctuation(_ sender: Any?) {
        let enabled = Preferences.toggleHalfWidthPunctuationEnabled()
        NotifierController.notify(
            message: enabled
                ? NSLocalizedString("Half-Width Punctuation On", comment: "")
                : NSLocalizedString("Half-Width Punctuation Off", comment: ""))
        if let currentClient = currentClient {
            keyHandler.clear()
            self.handle(state: InputState.Empty(), client: currentClient)
        }
    }

    @objc func toggleAssociatedPhrasesEnabled(_ sender: Any?) {
        _ = Preferences.toggleAssociatedPhrasesEnabled()
    }

    @objc func toggleBopomofoFontAnnotationSupport(_ sender: Any?) {
        let enabled = Preferences.toggleBopomofoFontAnnotationSupportEnabled()
        NotifierController.notify(
            message: enabled
                ? NSLocalizedString("Bopomofo Font Annotation Support On", comment: "")
                : NSLocalizedString("Bopomofo Font Annotation Support Off", comment: ""))
    }

    @objc func togglePhraseReplacement(_ sender: Any?) {
        let enabled = Preferences.togglePhraseReplacementEnabled()
        LanguageModelManager.phraseReplacementEnabled = enabled
    }

    @objc func toggleAFMAssist(_ sender: Any?) {
        Preferences.afmAssistEnabled = !Preferences.afmAssistEnabled
        cancelAFMRequest()
    }

    @objc func checkForUpdate(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.checkForUpdate(forced: true)
    }

    @objc func openUserPhrases(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openUserPhrases(sender)
    }

    @objc func openUserPhrasesPlainBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openUserPhrasesPlainBopomofo(sender)
    }

    @objc func openExcludedPhrasesPlainBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openExcludedPhrasesPlainBopomofo(sender)
    }

    @objc func openExcludedPhrasesMcBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openExcludedPhrasesMcBopomofo(sender)
    }

    @objc func openPhraseReplacementMcBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openPhraseReplacementMcBopomofo(sender)
    }

    @objc func reloadUserPhrases(_ sender: Any?) {
        LanguageModelManager.loadUserPhrases(
            enableForPlainBopomofo: Preferences.enableUserPhrasesInPlainBopomofo)
        LanguageModelManager.loadUserPhraseReplacement()

        // Empty the issues so that if there are still the same issues, a
        // notification will be shown.
        McBopomofoInputMethodController.latestUserFileIssues = []
        checkUserFileIssues()
    }

    @objc func showUserFileIssues(_ sender: Any?) {
        let header = NSLocalizedString(
            "Issues were found in the following user phrase files:", comment: "")
        let report =
            header + "\n\n"
            + McBopomofoInputMethodController.latestUserFileIssues.joined(separator: "\n")
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let dateString = formatter.string(from: now)
        let fileName = "UserFileIssues-\(dateString).txt"
        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(fileURL)
        } catch {
            NSLog("Failed to write report to temporary file: \(error)")
            return
        }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

}

// MARK: - State Handling

extension McBopomofoInputMethodController {

    func handle(state newState: InputState, client: Any?) {
        cancelAFMRequest()
        let previous = state
        state = newState

        switch newState {
        case let newState as InputState.Deactivated:
            handle(state: newState, previous: previous, client: client)
            state = .Empty()
        case let newState as InputState.SwitchingInputSource:
            handle(state: newState, previous: previous, client: client)
            state = .Empty()
            if !InputSourceHelper.selectInputSource(withID: newState.sourceID) {
                NSLog("Unable to switch to input source: %@", newState.sourceID)
            }
        case let newState as InputState.Empty:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.EmptyIgnoringPreviousState:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Committing:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Inputting:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Marking:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.ChoosingCandidate:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.AssociatedPhrases:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.AssociatedPhrasesPlain:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.SelectingFeature:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.SelectingDateMacro:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Number:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.IcuTransform:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Big5:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.SelectingDictionary:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.ShowingCharInfo:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.CustomMenu:
            handle(state: newState, previous: previous, client: client)
        default:
            break
        }
    }

    private func cancelAFMRequest() {
        afmTask?.cancel()
        afmTask = nil
        afmRequestGate.invalidate()
    }

    private func scheduleAFMRequest(
        inputting: InputState.Inputting, client: Any?
    ) {
        guard Preferences.afmAssistEnabled,
              keyHandler.inputMode == .bopomofo,
              let client = client as? IMKTextInput
        else {
            return
        }

        guard let afmState = keyHandler.buildAFMCandidateState() as? InputState.ChoosingCandidate,
              !afmState.candidates.isEmpty
        else {
            AFMAssistDiagnostics.shared.record(.ineligible)
            return
        }

        let capturedInputting = inputting
        let capturedClient = client
        let token = afmRequestGate.token()
        let context = String(capturedInputting.composingBuffer.suffix(256))
        let candidateValues = afmState.candidates.map { $0.value }
        let afmClient = self.afmClient
        let delay = AFMTriggerPolicy.delayNanoseconds(for: capturedInputting.composingBuffer)

        afmTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled,
                  self?.afmRequestGate.isCurrent(token) == true,
                  Preferences.afmAssistEnabled,
                  self?.state === capturedInputting,
                  (self?.currentClient as AnyObject?) === (capturedClient as AnyObject)
            else {
                AFMAssistDiagnostics.shared.record(.debounced_cancelled)
                return
            }
            let selectedIndex = await afmClient.select(
                context: context, candidates: candidateValues)
            guard !Task.isCancelled,
                  let self = self,
                  self.afmRequestGate.isCurrent(token),
                  Preferences.afmAssistEnabled,
                  self.state === capturedInputting,
                  (self.currentClient as AnyObject?) === (capturedClient as AnyObject)
            else {
                AFMAssistDiagnostics.shared.record(.stale)
                return
            }
            guard let selectedIndex = selectedIndex,
                  selectedIndex >= 0,
                  selectedIndex < afmState.candidates.count
            else {
                return
            }
            let candidate = afmState.candidates[selectedIndex]
            guard let newState = self.keyHandler.applyAFMCandidate(
                reading: candidate.reading, value: candidate.value
            ) as? InputState.Inputting else {
                AFMAssistDiagnostics.shared.record(.unchanged_or_rejected)
                return
            }
            AFMAssistDiagnostics.shared.record(.applied)
            self.handle(state: newState, client: capturedClient)
        }
    }

    private func commit(text: String, client: Any!) {

        func convertToSimplifiedChineseIfRequired(_ text: String) -> String {
            if !Preferences.chineseConversionEnabled {
                return text
            }
            if Preferences.chineseConversionStyle == .model {
                return text
            }
            return OpenCCBridge.shared.convertToSimplified(text) ?? ""
        }

        let buffer = convertToSimplifiedChineseIfRequired(text)
        if buffer.isEmpty {
            return
        }
        (client as? IMKTextInput)?.insertText(
            buffer, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func handle(state: InputState.Deactivated, previous: InputState, client: Any?) {
        currentClient = nil

        gCurrentCandidateController?.delegate = nil
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        switch previous {
        case let previous as InputState.NotEmpty:
            commit(text: previous.composingBuffer, client: client)
        case is InputState.Big5,
            is InputState.Number,
            is InputState.IcuTransform:
            client.setMarkedText(
                "", selectionRange: NSMakeRange(0, 0), replacementRange: NSMakeRange(0, 0))
        default:
            break
        }

        // Unlike the Empty state handler, we don't call client.setMarkedText() here:
        // there's no point calling setMarkedText() with an empty string as the session
        // is being deactivated anyway, and we have found issues with how certains app
        // could not handle setMarkedText() at this point (see GitHub issue #346).
    }

    private func handle(state: InputState.Empty, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        if let previous = previous as? InputState.NotEmpty {
            commit(text: previous.composingBuffer, client: client)
        }
        client.setMarkedText(
            "", selectionRange: NSMakeRange(0, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
    }

    private func handle(
        state: InputState.EmptyIgnoringPreviousState, previous: InputState, client: Any!
    ) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        client.setMarkedText(
            "", selectionRange: NSMakeRange(0, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
    }

    private func handle(state: InputState.Committing, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        let poppedText = state.poppedText
        if !poppedText.isEmpty {
            commit(text: poppedText, client: client)
        }
        client.setMarkedText(
            "", selectionRange: NSMakeRange(0, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
    }

    private func handle(state: InputState.Inputting, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        client.setMarkedText(
            state.attributedString, selectionRange: NSMakeRange(Int(state.cursorIndex), 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        if !state.tooltip.isEmpty {
            show(
                tooltip: state.tooltip, composingBuffer: state.composingBuffer,
                cursorIndex: state.cursorIndex, client: client)
        }
        scheduleAFMRequest(inputting: state, client: client)
    }

    private func handle(state: InputState.Marking, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        guard let client = client as? IMKTextInput else {
            hideTooltip()
            return
        }

        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        client.setMarkedText(
            state.attributedString, selectionRange: NSMakeRange(Int(state.cursorIndex), 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))

        if state.tooltip.isEmpty {
            hideTooltip()
        } else {
            show(
                tooltip: state.tooltip, composingBuffer: state.composingBuffer,
                cursorIndex: state.markerIndex, client: client)
        }
    }

    private func handle(state: InputState.ChoosingCandidate, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }

        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        client.setMarkedText(
            state.attributedString, selectionRange: NSMakeRange(Int(state.cursorIndex), 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.AssociatedPhrases, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }

        let previousState = state.previousState
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        switch previousState {
        case let previousState as InputState.ChoosingCandidate:
            client.setMarkedText(
                previousState.attributedString,
                selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0),
                replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        case let previousState as InputState.Inputting:
            client.setMarkedText(
                previousState.attributedString,
                selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0),
                replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        default:
            break
        }
        show(candidateWindowWith: state, client: client)
    }

    private func handle(
        state: InputState.AssociatedPhrasesPlain, previous: InputState, client: Any?
    ) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        client.setMarkedText(
            "", selectionRange: NSMakeRange(0, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.SelectingFeature, previous: InputState, client: Any?) {
        handleStateWithSimpleCandidateWindow(state: state, previous: previous, client: client)
    }

    private func handle(state: InputState.SelectingDateMacro, previous: InputState, client: Any?) {
        handleStateWithSimpleCandidateWindow(state: state, previous: previous, client: client)
    }

    private func handleSpecialInputWithCandidateWindow(state: InputState, composingBuffer: String, candidateCount: Int, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        client.setMarkedText(
            composingBuffer,
            selectionRange: NSMakeRange(
                (composingBuffer as NSString).length,
                0
            ),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound)
        )
        if candidateCount > 0 {
            show(candidateWindowWith: state, client: client)
        }
    }


    private func handle(state: InputState.Number, previous: InputState, client: Any?) {
        handleSpecialInputWithCandidateWindow(state: state, composingBuffer: state.composingBuffer, candidateCount: state.candidateCount, client: client)
    }

    private func handle(state: InputState.IcuTransform, previous: InputState, client: Any?) {
        handleSpecialInputWithCandidateWindow(state: state, composingBuffer: state.composingBuffer, candidateCount: state.candidateCount, client: client)
    }

    private func handle(state: InputState.Big5, previous: InputState, client: Any?) {
        handleStateForCustomInput(
            composingBuffer: state.composingBuffer, previous: previous, client: client)
    }

    private func handle(state: InputState.SelectingDictionary, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        let previousState = state.previousState
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer

        switch previousState {
        case let previousState as InputState.ChoosingCandidate:
            client.setMarkedText(
                previousState.attributedString,
                selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0),
                replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        case let previousState as InputState.Marking:
            client.setMarkedText(
                previousState.attributedString,
                selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0),
                replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        default:
            break
        }
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.ShowingCharInfo, previous: InputState, client: Any?) {

        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        let previousState = state.previousState.previousState
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        switch previousState {
        case let previousState as InputState.ChoosingCandidate:
            client.setMarkedText(
                previousState.attributedString,
                selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0),
                replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        case let previousState as InputState.Marking:
            client.setMarkedText(
                previousState.attributedString,
                selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0),
                replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        default:
            break
        }
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.CustomMenu, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        show(candidateWindowWith: state, client: client)
    }
}

// MARK: -

extension McBopomofoInputMethodController {
    private func handleStateForCustomInput(
        composingBuffer: String, previous: InputState, client: Any?
    ) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        if let previous = previous as? InputState.NotEmpty {
            commit(text: previous.composingBuffer, client: client)
        }
        client.setMarkedText(
            composingBuffer, selectionRange: NSMakeRange(composingBuffer.utf16.count, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
    }

    private func handleStateWithSimpleCandidateWindow(
        state: InputState, previous: InputState, client: Any?
    ) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        if let previous = previous as? InputState.NotEmpty {
            commit(text: previous.composingBuffer, client: client)
        }
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        client.setMarkedText(
            "", selectionRange: NSMakeRange(0, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
        show(candidateWindowWith: state, client: client)
    }

    private func show(candidateWindowWith state: InputState, client: Any!) {
        let useVerticalMode: Bool = {
            var useVerticalMode = false
            var candidates: [InputState.Candidate] = []
            switch state {
            case let state as InputState.ChoosingCandidate:
                useVerticalMode = state.useVerticalMode
                candidates = state.candidates
            case let state as InputState.AssociatedPhrasesPlain:
                useVerticalMode = state.useVerticalMode
                candidates = state.candidates
            case let state as InputState.AssociatedPhrases:
                useVerticalMode = state.useVerticalMode
                candidates = state.candidates
            case is InputState.SelectingFeature,
                is InputState.SelectingDateMacro,
                is InputState.SelectingDictionary,
                is InputState.ShowingCharInfo,
                is InputState.Number,
                is InputState.IcuTransform:
                return true
            default:
                break
            }

            if useVerticalMode == true {
                return true
            }
            candidates.sort {
                return $0.displayText.count > $1.displayText.count
            }
            // If there is a candidate which is too long, we use the vertical
            // candidate list window automatically.
            if candidates.first?.displayText.count ?? 0 > 8 {
                return true
            }
            return false
        }()

        gCurrentCandidateController?.delegate = nil
        gCurrentCandidateController?.visible = false

        if useVerticalMode {
            gCurrentCandidateController = .vertical
        } else if Preferences.useHorizontalCandidateList {
            gCurrentCandidateController = .horizontal
        } else {
            gCurrentCandidateController = .vertical
        }

        gCurrentCandidateController?.tooltip =
            switch state {
            case let state as InputState.SelectingDictionary:
                String(format: NSLocalizedString("Look up %@", comment: ""), state.selectedPhrase)
            case let state as InputState.AssociatedPhrases:
                String(format: NSLocalizedString("%@…", comment: ""), state.prefixValue)
            case let state as InputState.CustomMenu:
                state.title
            default:
                ""
            }

        // set the attributes for the candidate panel (which uses NSAttributedString)
        let textSize = Preferences.candidateListTextSize
        let keyLabelSize = max(textSize / 2, kMinKeyLabelSize)

        func font(name: String?, size: CGFloat) -> NSFont {
            if let name = name {
                return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
            }
            return NSFont.systemFont(ofSize: size)
        }

        gCurrentCandidateController?.keyLabelFont = font(
            name: Preferences.candidateKeyLabelFontName, size: keyLabelSize)
        gCurrentCandidateController?.candidateFont = font(
            name: Preferences.candidateTextFontName, size: textSize)

        let candidateKeys = Preferences.candidateKeys
        let keyLabels =
            candidateKeys.count >= 4
            ? Array(candidateKeys) : Array(Preferences.defaultCandidateKeys)

        let keyLabelFormat: (String)->String = switch state {
        case let state as InputState.AssociatedPhrases where state.autoTriggered:
            { _ in "⇧ ⏎" }
        case is InputState.AssociatedPhrasesPlain,
            is InputState.Number,
            is InputState.IcuTransform:
            { "⇧ " + $0 }
        default:
            { $0 }
        }
        gCurrentCandidateController?.keyLabels = keyLabels.map {
            CandidateKeyLabel(key: String($0), displayedText: keyLabelFormat(String($0)))
        }

        gCurrentCandidateController?.delegate = self
        gCurrentCandidateController?.reloadData()
        currentClient = client

        var lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
        var cursor: Int = 0

        if let state = state as? InputState.NotEmpty {
            cursor = Int(state.cursorIndex)
            if cursor == state.composingBuffer.count && cursor != 0 {
                cursor -= 1
            }
        }

        while lineHeightRect.origin.x == 0 && lineHeightRect.origin.y == 0 && cursor >= 0 {
            (client as? IMKTextInput)?.attributes(
                forCharacterIndex: cursor, lineHeightRectangle: &lineHeightRect)
            cursor -= 1
        }

        if useVerticalMode {
            gCurrentCandidateController?.set(
                windowTopLeftPoint: NSMakePoint(
                    lineHeightRect.origin.x + lineHeightRect.size.width + 4.0,
                    lineHeightRect.origin.y - 4.0),
                bottomOutOfScreenAdjustmentHeight: lineHeightRect.size.height + 4.0)
        } else {
            gCurrentCandidateController?.set(
                windowTopLeftPoint: NSMakePoint(
                    lineHeightRect.origin.x, lineHeightRect.origin.y - 4.0),
                bottomOutOfScreenAdjustmentHeight: lineHeightRect.size.height + 4.0)
        }

        gCurrentCandidateController?.visible = true
    }

    private func show(tooltip: String, composingBuffer: String, cursorIndex: UInt, client: Any!) {
        var lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
        var cursor: Int = Int(cursorIndex)
        if cursor == composingBuffer.count && cursor != 0 {
            cursor -= 1
        }

        var isVerticalMode = false
        while lineHeightRect.origin.x == 0 && lineHeightRect.origin.y == 0 && cursor >= 0 {
            let attributes: [AnyHashable: Any]? = (client as? IMKTextInput)?.attributes(
                forCharacterIndex: cursor, lineHeightRectangle: &lineHeightRect)
            let useVerticalMode =
                (attributes?["IMKTextOrientation"] as? NSNumber)?.intValue == 0 || false
            isVerticalMode = isVerticalMode || useVerticalMode
            cursor -= 1
        }

        // Make sure that tooltip hovers next to the vertical text.
        if isVerticalMode && lineHeightRect.size.height > 0 {
            lineHeightRect.origin.x += (lineHeightRect.size.width + 1.0)
        }

        McBopomofoInputMethodController.tooltipController.show(
            tooltip: tooltip, at: lineHeightRect.origin)
    }

    private func hideTooltip() {
        McBopomofoInputMethodController.tooltipController.hide()
    }

    private func checkUserFileIssues() {
        let issues: [String] = keyHandler.collectUserFileIssues()

        // McBopomofoLM caps the maximum number of issues collected, and so
        // we'll just do this O(n) comparison since n is small.
        if McBopomofoInputMethodController.latestUserFileIssues != issues {
            McBopomofoInputMethodController.latestUserFileIssues = issues

            if !McBopomofoInputMethodController.latestUserFileIssues.isEmpty {
                NotifierController.notify(
                    message: NSLocalizedString(
                        "Check McBopomofo menu for user file issues", comment: ""), stay: true)
            }
        }
    }
}
