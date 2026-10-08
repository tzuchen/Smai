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
        let isPromptOpt = text.hasPrefix(">>") || text.hasPrefix("》》") || text.hasPrefix("。。") || text.hasPrefix("..") || text.hasPrefix("$$")
            || text.hasSuffix(">>") || text.hasSuffix("》》") || text.hasSuffix("。。") || text.hasSuffix("..") || text.hasSuffix("$$")
        if isPromptOpt {
            var clean = text
            for trig in [">>", "》》", "。。", "..", "$$"] {
                if clean.hasPrefix(trig) {
                    clean = String(clean.dropFirst(trig.count))
                }
                if clean.hasSuffix(trig) {
                    clean = String(clean.dropLast(trig.count))
                }
            }
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

            // If user only typed the trigger alone with no prompt text yet (e.g. "。。" or ">>"), do not trigger immediately!
            guard clean.count >= 2 else {
                return 600_000_000
            }

            if text.hasSuffix(">>") || text.hasSuffix("》》") || text.hasSuffix("。。") || text.hasSuffix("..") || text.hasSuffix("$$") {
                return 0
            }
            if let lastChar = text.last {
                let punctuationSet: Set<Character> = ["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":", " ", "\u{3000}"]
                if punctuationSet.contains(lastChar) {
                    return 0
                }
            }
            return 600_000_000
        }
        if text.contains("??") || text.contains("？？") {
            return 0
        }
        guard let lastChar = text.last else {
            return 350_000_000
        }
        let punctuationSet: Set<Character> = ["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":", " ", "\u{3000}"]
        if punctuationSet.contains(lastChar) {
            return 0
        }
        return 350_000_000
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

    mutating func reset() {
        isFallbackEnglish = false
        nativeCapsOn = false
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

struct AFMSymbolPolicy {
    /// Returns the ASCII symbol to commit when Option is held with punctuation/symbol key.
    /// Returns nil if it should not be intercepted (e.g. letters for Emacs navigation, or command/control held).
    static func optionSymbolToCommit(charsNoMod: String?, flags: NSEvent.ModifierFlags) -> String? {
        guard let charsNoMod = charsNoMod, charsNoMod.utf16.count == 1 else { return nil }
        if flags.contains(.command) || flags.contains(.control) { return nil }
        guard flags.contains(.option) else { return nil }
        guard let scalar = charsNoMod.unicodeScalars.first else { return nil }
        let v = scalar.value
        // Only printable ASCII characters (0x20...0x7E)
        guard v >= 0x20 && v <= 0x7E else { return nil }
        // Do not intercept letters (A-Z, a-z), preserving Option+F, Option+B, Option+D, etc.
        let isLetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
        guard !isLetter else { return nil }
        return charsNoMod
    }

    /// Returns the character to commit when Caps Lock is active for non-letter ASCII (symbols, punctuation, digits).
    static func capsNonLetterToCommit(chars: String?, flags: NSEvent.ModifierFlags) -> String? {
        guard let chars = chars, chars.utf16.count == 1 else { return nil }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return nil }
        guard let scalar = chars.unicodeScalars.first else { return nil }
        let v = scalar.value
        // Non-letter printable ASCII (0x21...0x7E excluding A-Z, a-z)
        guard v >= 0x21 && v <= 0x7E else { return nil }
        let isLetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
        guard !isLetter else { return nil }
        return chars
    }
}

struct AFMSlashCommandTracker {
    enum Action: Equatable {
        case ignore
        case updateMarked(String)
        case commit(String)
        case commitAndPassThrough(String)
        case cancel
    }

    private(set) var isActive: Bool = false
    private(set) var buffer: String = ""

    mutating func reset() {
        isActive = false
        buffer = ""
    }

    mutating func start() {
        isActive = true
        buffer = "/"
    }

    mutating func handleKey(
        keyCode: UInt16,
        chars: String,
        flags: NSEvent.ModifierFlags
    ) -> Action {
        guard isActive else { return .ignore }

        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)

        // Shortcut modifiers (Cmd+C, Ctrl+C, etc.): commit command typed so far and pass shortcut to client
        if hasCmd || hasCtrl {
            let text = buffer
            reset()
            return .commitAndPassThrough(text)
        }

        // Return / Enter -> commit command
        if keyCode == UInt16(kVK_Return) {
            let text = buffer
            reset()
            return .commit(text)
        }

        // Space -> commit command with trailing space
        if keyCode == UInt16(kVK_Space) {
            let text = buffer + " "
            reset()
            return .commit(text)
        }

        // Delete / Backspace
        if keyCode == UInt16(kVK_Delete) {
            if buffer.count > 1 {
                buffer.removeLast()
                return .updateMarked(buffer)
            } else {
                reset()
                return .cancel
            }
        }

        // Escape -> cancel
        if keyCode == UInt16(kVK_Escape) {
            reset()
            return .cancel
        }

        // Arrow keys (123 = Left, 124 = Right, 125 = Down, 126 = Up) -> commit and pass through
        if keyCode >= 123 && keyCode <= 126 {
            let text = buffer
            reset()
            return .commitAndPassThrough(text)
        }

        // Valid printable ASCII character (letters, numbers, symbols)
        if chars.utf16.count == 1, let scalar = chars.unicodeScalars.first, scalar.value >= 0x21 && scalar.value <= 0x7E {
            buffer += chars
            return .updateMarked(buffer)
        }

        // Any other key (e.g. Tab, Function keys, non-ASCII): commit and let client handle
        let text = buffer
        reset()
        return .commitAndPassThrough(text)
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


    private let afmDiagnosticsMarkerPath = "/Users/Shared/Smai-diagnostics.enabled"
    private let afmDiagnosticsMaxEvents = 200
    private var afmDiagnosticsEventCount = 0

    private static var capsLockSwitch = AFMCapsLockSwitch()
    private static var casePolicy = AFMEnglishCasePolicy()
    private var slashTracker = AFMSlashCommandTracker()

    private func resetSlashMarkedText(client: Any?) {
        (client as? IMKTextInput)?.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

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
            let afmAssistItem = NSMenuItem(
                title: NSLocalizedString("AI-Assisted Candidate Selection", comment: ""),
                action: nil,
                keyEquivalent: "")
            afmAssistItem.isEnabled = true

            let afmSubmenu = NSMenu(title: "AI Assist")
            afmSubmenu.autoenablesItems = false

            let punctItem = afmSubmenu.addItem(
                withTitle: NSLocalizedString("Punctuation Normalization", comment: ""),
                action: #selector(toggleAFMPunctuationFix(_:)), keyEquivalent: "")
            punctItem.target = self
            punctItem.state = Preferences.afmPunctuationFixEnabled.state

            let phoneticItem = afmSubmenu.addItem(
                withTitle: NSLocalizedString("Near-Homophone & Tone Correction", comment: ""),
                action: #selector(toggleAFMNearPhoneticFix(_:)), keyEquivalent: "")
            phoneticItem.target = self
            phoneticItem.state = Preferences.afmNearPhoneticFixEnabled.state

            let fluencyItem = afmSubmenu.addItem(
                withTitle: NSLocalizedString("Semantic Fluency Rewrite", comment: ""),
                action: #selector(toggleAFMSemanticFluencyRewrite(_:)), keyEquivalent: "")
            fluencyItem.target = self
            fluencyItem.state = Preferences.afmSemanticFluencyRewriteEnabled.state

            let clozeItem = afmSubmenu.addItem(
                withTitle: NSLocalizedString("Cloze Filling (??)", comment: ""),
                action: #selector(toggleAFMClozeFilling(_:)), keyEquivalent: "")
            clozeItem.target = self
            clozeItem.state = Preferences.afmClozeFillingEnabled.state

            let promptOptItem = afmSubmenu.addItem(
                withTitle: NSLocalizedString("LLM Prompt Optimization (>> or ..)", comment: ""),
                action: #selector(toggleAFMPromptOptimizer(_:)), keyEquivalent: "")
            promptOptItem.target = self
            promptOptItem.state = Preferences.afmPromptOptimizerEnabled.state

            afmAssistItem.submenu = afmSubmenu
            menu.addItem(afmAssistItem)
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
            withTitle: NSLocalizedString("Restart Smai", comment: ""),
            action: #selector(restartSmai(_:)), keyEquivalent: "")
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
        slashTracker.reset()
        Self.capsLockSwitch.reset()
        Self.casePolicy.resetShiftTracking()

        (NSApp.delegate as? AppDelegate)?.checkForUpdate()
    }

    override func deactivateServer(_ client: Any!) {
        cancelAFMRequest()
        if slashTracker.isActive {
            let text = slashTracker.buffer
            slashTracker.reset()
            resetSlashMarkedText(client: client)
            if let client = client as? IMKTextInput {
                commit(text: text, client: client)
            }
        }
        currentClient = nil
        keyHandler.clear()
        slashTracker.reset()
        Self.capsLockSwitch.reset()
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
        if slashTracker.isActive {
            let text = slashTracker.buffer
            slashTracker.reset()
            resetSlashMarkedText(client: client)
            if let client = client as? IMKTextInput {
                commit(text: text, client: client)
            }
            return
        }
        if let inputting = state as? InputState.Inputting {
            let text = inputting.composingBuffer
            keyHandler.clear()
            if let client = client as? IMKTextInput {
                commit(text: text, client: client)
            }
            handle(state: InputState.EmptyIgnoringPreviousState(), client: client)
            return
        }
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

        if event.type == .keyDown {
            cancelAFMRequest()
        }

        if event.type == .flagsChanged {
            Self.casePolicy.observeModifierEvent(
                keyCode: event.keyCode,
                shiftIsOn: event.modifierFlags.contains(.shift)
            )
            if event.keyCode == UInt16(kVK_CapsLock) {
                // If there is pending composition when user touches CapsLock, commit it immediately
                if slashTracker.isActive {
                    let text = slashTracker.buffer
                    slashTracker.reset()
                    resetSlashMarkedText(client: client)
                    if let client = client as? IMKTextInput {
                        commit(text: text, client: client)
                    }
                } else if state is InputState.NotEmpty {
                    self.commitComposition(client)
                }

                let isCaps = event.modifierFlags.contains(.capsLock)
                    || NSEvent.modifierFlags.contains(.capsLock)
                    || CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
                _ = Self.capsLockSwitch.handleCapsLock(isOn: isCaps, timestamp: event.timestamp)
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
            let chars = event.characters ?? ""
            let charsNoMod = event.charactersIgnoringModifiers ?? ""
            let flagsStr = [
                event.modifierFlags.contains(.shift) ? "shift" : nil,
                event.modifierFlags.contains(.control) ? "ctrl" : nil,
                event.modifierFlags.contains(.option) ? "opt" : nil,
                event.modifierFlags.contains(.command) ? "cmd" : nil,
                event.modifierFlags.contains(.capsLock) ? "caps" : nil
            ].compactMap { $0 }.joined(separator: "|")
            AFMDevLogger.shared.log("KEY DOWN keyCode=\(event.keyCode), chars='\(chars)', charsNoMod='\(charsNoMod)', flags=[\(flagsStr)]")

            let isCapsActive = event.modifierFlags.contains(.capsLock)
                || NSEvent.modifierFlags.contains(.capsLock)
                || CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)

            let hasCmd = event.modifierFlags.contains(.command)
            let hasCtrl = event.modifierFlags.contains(.control)
            let hasOpt = event.modifierFlags.contains(.option)
            let hasShift = event.modifierFlags.contains(.shift)

            // 1. If Smart Slash Command mode is active, intercept all keystrokes
            if slashTracker.isActive {
                let action = slashTracker.handleKey(keyCode: event.keyCode, chars: chars, flags: event.modifierFlags)
                switch action {
                case .updateMarked(let marked):
                    (client as? IMKTextInput)?.setMarkedText(
                        marked,
                        selectionRange: NSRange(location: marked.utf16.count, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
                    )
                    return true
                case .commit(let text):
                    self.resetSlashMarkedText(client: client)
                    if let client = client as? IMKTextInput {
                        self.commit(text: text, client: client)
                    }
                    AFMDevLogger.shared.log("SLASH COMMAND COMMITTED: '\(text)'")
                    return true
                case .commitAndPassThrough(let text):
                    self.resetSlashMarkedText(client: client)
                    if let client = client as? IMKTextInput {
                        self.commit(text: text, client: client)
                    }
                    AFMDevLogger.shared.log("SLASH COMMAND PASSED THROUGH: '\(text)'")
                    return false
                case .cancel:
                    self.resetSlashMarkedText(client: client)
                    AFMDevLogger.shared.log("SLASH COMMAND CANCELLED")
                    return true
                case .ignore:
                    break
                }
            }

            // 2. Option + symbol shortcut (universal half-width punctuation / symbols)
            if let optionSymbol = AFMSymbolPolicy.optionSymbolToCommit(charsNoMod: charsNoMod, flags: event.modifierFlags) {
                if let client = client as? IMKTextInput {
                    if state is InputState.NotEmpty {
                        self.commitComposition(client)
                    }
                    AFMDevLogger.shared.log("OPTION SYMBOL COMMITTED: '\(optionSymbol)'")
                    self.commit(text: optionSymbol, client: client)
                    return true
                }
            }

            // 3. Caps Lock active: letters and non-letter ASCII (symbols/digits)
            if isCapsActive && !hasCmd && !hasCtrl && !hasOpt {
                let isLetter = (chars.utf16.count == 1) && {
                    guard let scalar = chars.unicodeScalars.first else { return false }
                    let v = scalar.value
                    return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                }()
                if isLetter {
                    if let client = client as? IMKTextInput,
                       let letter = Self.casePolicy.letterToCommit(text: chars, flags: event.modifierFlags) {
                        if state is InputState.NotEmpty {
                            self.commitComposition(client)
                        }
                        AFMDevLogger.shared.log("CAPS COMMITTED (LETTER): orig='\(chars)' -> '\(letter)'")
                        self.commit(text: letter, client: client)
                        return true
                    }
                } else if let nonLetter = AFMSymbolPolicy.capsNonLetterToCommit(chars: chars, flags: event.modifierFlags) {
                    if let client = client as? IMKTextInput {
                        if state is InputState.NotEmpty {
                            self.commitComposition(client)
                        }
                        AFMDevLogger.shared.log("CAPS COMMITTED (SYMBOL/DIGIT): '\(nonLetter)'")
                        self.commit(text: nonLetter, client: client)
                        return true
                    }
                }
            } else {
                // Caps Lock NOT active: uppercase letter via shift if applicable
                let isLetter = (chars.utf16.count == 1) && {
                    guard let scalar = chars.unicodeScalars.first, !hasCmd, !hasCtrl, !hasOpt else { return false }
                    let v = scalar.value
                    return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                }()
                let isUpper = isLetter && (chars.unicodeScalars.first!.value <= 0x5A)
                if isLetter && isUpper && !Self.casePolicy.physicalShiftIsDown {
                    if let client = client as? IMKTextInput,
                       let letter = Self.casePolicy.letterToCommit(text: chars, flags: event.modifierFlags) {
                        if state is InputState.NotEmpty {
                            self.commitComposition(client)
                        }
                        self.commit(text: letter, client: client)
                        return true
                    }
                }
            }

            // 4. Trigger Smart Slash Command Mode when buffer is empty and user presses '/'
            let isSlashKey = event.keyCode == UInt16(kVK_ANSI_Slash) && !hasShift && !hasCmd && !hasCtrl && !hasOpt && !isCapsActive
            if isSlashKey && (state is InputState.Empty) {
                slashTracker.start()
                (client as? IMKTextInput)?.setMarkedText(
                    slashTracker.buffer,
                    selectionRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
                )
                AFMDevLogger.shared.log("SMART SLASH COMMAND ACTIVATED: '/'")
                return true
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

    private func updateAFMAssistMasterState() {
        let anySubFeature = Preferences.afmPunctuationFixEnabled
            || Preferences.afmNearPhoneticFixEnabled
            || Preferences.afmSemanticFluencyRewriteEnabled
            || Preferences.afmClozeFillingEnabled
            || Preferences.afmPromptOptimizerEnabled
        Preferences.afmAssistEnabled = anySubFeature
        if !anySubFeature {
            cancelAFMRequest()
        }
    }

    @objc func toggleAFMPunctuationFix(_ sender: Any?) {
        Preferences.afmPunctuationFixEnabled = !Preferences.afmPunctuationFixEnabled
        updateAFMAssistMasterState()
    }

    @objc func toggleAFMNearPhoneticFix(_ sender: Any?) {
        Preferences.afmNearPhoneticFixEnabled = !Preferences.afmNearPhoneticFixEnabled
        updateAFMAssistMasterState()
    }

    @objc func toggleAFMSemanticFluencyRewrite(_ sender: Any?) {
        Preferences.afmSemanticFluencyRewriteEnabled = !Preferences.afmSemanticFluencyRewriteEnabled
        updateAFMAssistMasterState()
    }

    @objc func toggleAFMClozeFilling(_ sender: Any?) {
        Preferences.afmClozeFillingEnabled = !Preferences.afmClozeFillingEnabled
        updateAFMAssistMasterState()
    }

    @objc func toggleAFMPromptOptimizer(_ sender: Any?) {
        Preferences.afmPromptOptimizerEnabled = !Preferences.afmPromptOptimizerEnabled
        updateAFMAssistMasterState()
    }

    @objc func restartSmai(_ sender: Any?) {
        cancelAFMRequest()
        let bundlePath = Bundle.main.bundlePath
        let execPath = Bundle.main.executablePath ?? (bundlePath + "/Contents/MacOS/Smai")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = [
            "-c",
            "sleep 0.3; /usr/bin/open \"\(bundlePath)\" 2>/dev/null || nohup \"\(execPath)\" >/dev/null 2>&1 &"
        ]
        try? task.run()
        NSApp.terminate(nil)
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

    private func findChangedRange(old: NSString, new: NSString) -> NSRange {
        let oldLen = old.length
        let newLen = new.length
        var prefixLen = 0
        while prefixLen < oldLen && prefixLen < newLen && old.character(at: prefixLen) == new.character(at: prefixLen) {
            prefixLen += 1
        }
        var suffixLen = 0
        while suffixLen < (oldLen - prefixLen) && suffixLen < (newLen - prefixLen)
                && old.character(at: oldLen - 1 - suffixLen) == new.character(at: newLen - 1 - suffixLen) {
            suffixLen += 1
        }
        let changedLen = newLen - prefixLen - suffixLen
        if changedLen > 0 {
            return NSRange(location: prefixLen, length: changedLen)
        }
        return NSRange(location: 0, length: newLen)
    }

    private static func containsBopomofoOrTone(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Bopomofo block: U+3105 to U+312F
            // Bopomofo Extended: U+31A0 to U+31BF
            // Tone marks: U+02CA, U+02C7, U+02CB, U+02D9, U+02C9
            if (v >= 0x3105 && v <= 0x312F) ||
               (v >= 0x31A0 && v <= 0x31BF) ||
               v == 0x02CA || v == 0x02C7 || v == 0x02CB || v == 0x02D9 || v == 0x02C9 {
                return true
            }
        }
        return false
    }

    static func isTerminalApp(_ client: Any?) -> Bool {
        var bundleID: String? = nil
        if let textInput = client as? IMKTextInput {
            bundleID = textInput.bundleIdentifier()
        }
        if bundleID == nil || bundleID?.isEmpty == true {
            bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        guard let bid = bundleID?.lowercased() else { return false }
        return bid.contains("terminal") ||
               bid.contains("iterm") ||
               bid.contains("ghostty") ||
               bid.contains("warp") ||
               bid.contains("wezterm") ||
               bid.contains("kitty") ||
               bid.contains("alacritty") ||
               bid.contains("hyper") ||
               bid.contains("tabby") ||
               bid.contains("rio")
    }

    static func containsAlphaNumericOrChinese(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                return true
            }
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                return true
            }
        }
        return false
    }

    static func getProcessCommandLine(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { ptr -> String? in
            guard let base = ptr.baseAddress else { return nil }
            let strData = Data(bytes: base + 4, count: size - 4)
            return String(data: strData, encoding: .utf8)?.replacingOccurrences(of: "\0", with: " ")
        }
    }

    static func isAiCliInForeground() -> Bool {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let actualCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, count)
        let aiKeywords = ["agy", "codex", "claude", "chatgpt", "gemini", "copilot"]

        let numPids = Int(actualCount) / MemoryLayout<pid_t>.size
        var pathBuf = [CChar](repeating: 0, count: 4096)

        for i in 0..<numPids {
            let p = pids[i]
            guard p > 0 else { continue }

            // 1. Get process executable path via proc_pidpath (works reliably across all UIDs without privilege issues)
            let pathLen = proc_pidpath(p, &pathBuf, UInt32(pathBuf.count))
            guard pathLen > 0 else { continue }
            let execPath = String(cString: pathBuf).lowercased()

            var matchesAi = false
            for kw in aiKeywords {
                if execPath.hasSuffix("/" + kw) || execPath.contains("/" + kw + "/") || execPath.contains("/" + kw + "-") {
                    matchesAi = true
                    break
                }
            }

            if !matchesAi {
                if let cmdline = getProcessCommandLine(pid: p)?.lowercased() {
                    for kw in aiKeywords {
                        if cmdline.contains("/" + kw + " ") || cmdline.contains(" " + kw + " ") || cmdline.hasPrefix(kw + " ") {
                            matchesAi = true
                            break
                        }
                    }
                }
            }

            guard matchesAi else { continue }

            // 2. Verify if this AI CLI is currently in the foreground of a terminal session
            // sysctl(KERN_PROC_PID) returns kinfo_proc across users without EPERM
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
            var proc = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            if sysctl(&mib, 4, &proc, &size, nil, 0) == 0 {
                let pgid = proc.kp_eproc.e_pgid
                let tpgid = proc.kp_eproc.e_tpgid
                let pid = proc.kp_proc.p_pid
                if tpgid > 0 && (pgid == tpgid || pid == tpgid) {
                    AFMDevLogger.shared.log("AI CLI DETECTED IN FOREGROUND: pid=\(p), path='\(execPath)', pgid=\(pgid), tpgid=\(tpgid)")
                    return true
                }
            }
        }
        return false
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

        // If the composing buffer was already highlighted by AFM, do not re-dispatch
        // until the user actually types new keys.
        if !inputting.afmHighlightedRanges.isEmpty || inputting.afmHighlightedRange.location != NSNotFound {
            return
        }

        var sentence = inputting.composingBuffer
        let sentenceLen = (sentence as NSString).length
        guard sentenceLen >= 2 else {
            return
        }

        // If composing buffer contains uncompleted Bopomofo/tone symbols (e.g. ㄋ, ㄧ, ㄝ),
        // do not schedule an LLM request until the character has been fully assembled.
        if Self.containsBopomofoOrTone(sentence) {
            return
        }

        // Check if preceding text in the client document should be included for prompt optimization
        struct PrecedingPromptContext {
            let prefixText: String
            let replaceRange: NSRange
        }

        let precedingContext: PrecedingPromptContext? = {
            guard Preferences.afmPromptOptimizerEnabled else { return nil }
            let marked = client.markedRange()
            let sel = client.selectedRange()
            let startLoc = (marked.location != NSNotFound) ? marked.location : sel.location
            guard startLoc != NSNotFound && startLoc > 0 else { return nil }

            let checkLen = min(startLoc, 180)
            let searchRange = NSRange(location: startLoc - checkLen, length: checkLen)
            guard let attr = client.attributedSubstring(from: searchRange) else { return nil }
            let fullPreceding = attr.string
            guard !fullPreceding.isEmpty else { return nil }

            // Strictly bound preceding context to the current line (never cross \n or \r into scrollback or previous output)
            let lineStartIndex: String.Index
            if let lastNewline = fullPreceding.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
                lineStartIndex = fullPreceding.index(after: lastNewline)
            } else {
                lineStartIndex = fullPreceding.startIndex
            }

            let precedingText = String(fullPreceding[lineStartIndex...])
            let lineOffsetInPreceding = (fullPreceding[..<lineStartIndex] as NSString).length
            let lineStartLoc = (startLoc - checkLen) + lineOffsetInPreceding
            let lineCheckLen = (precedingText as NSString).length
            guard lineCheckLen > 0 else { return nil }

            let triggers = [">>", "》》", "。。", "..", "$$"]

            // Case 1: Preceding document text on current line contains an explicit trigger prefix (e.g. ">> " or "。。")
            for trigger in triggers {
                if precedingText.contains(trigger) {
                    let nsPreceding = precedingText as NSString
                    let triggerNSRange = nsPreceding.range(of: trigger, options: .backwards)
                    if triggerNSRange.location != NSNotFound {
                        let replaceLen = lineCheckLen - triggerNSRange.location
                        let textSlice = (nsPreceding.substring(from: triggerNSRange.location) as String)
                        return PrecedingPromptContext(
                            prefixText: textSlice,
                            replaceRange: NSRange(location: lineStartLoc + triggerNSRange.location, length: replaceLen)
                        )
                    }
                }
            }

            // Case 2: Composing buffer has prompt optimization suffix/prefix (e.g. "。。" or ">>")
            // In this case, capture preceding text up to the start of the current sentence/line
            let isComposingTriggered = sentence.hasSuffix("。。") || sentence.hasSuffix(">>") || sentence.hasSuffix("》》") || sentence.hasSuffix("..") || sentence.hasSuffix("$$")
                || sentence.hasPrefix(">>") || sentence.hasPrefix("》》") || sentence.hasPrefix("。。") || sentence.hasPrefix("..") || sentence.hasPrefix("$$")

            if isComposingTriggered {
                let delimiters: [Character] = ["\n", "\r", "\t", "。", "！", "？", "!", "?", ";", "；", "$", "%", "#", "›", ">", "》"]
                var searchSlice = precedingText[...]
                // Drop trailing punctuation or whitespace from the preceding committed text
                while let last = searchSlice.last, delimiters.contains(last) || last.isWhitespace {
                    searchSlice = searchSlice.dropLast()
                }

                // If nothing remains after dropping delimiters/spaces, preceding text was only prompt/delimiter symbols!
                guard !searchSlice.isEmpty else { return nil }

                var boundaryIndex = precedingText.startIndex
                if let lastDelim = searchSlice.lastIndex(where: { delimiters.contains($0) }) {
                    boundaryIndex = precedingText.index(after: lastDelim)
                }

                let textSlice = String(precedingText[boundaryIndex...])
                let trimmed = textSlice.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.allSatisfy({ delimiters.contains($0) }) {
                    let sliceNSRange = (precedingText as NSString).range(of: textSlice, options: .backwards)
                    let sliceStartLoc = (sliceNSRange.location != NSNotFound) ? (lineStartLoc + sliceNSRange.location) : (startLoc - (textSlice as NSString).length)
                    return PrecedingPromptContext(
                        prefixText: textSlice,
                        replaceRange: NSRange(location: sliceStartLoc, length: (textSlice as NSString).length)
                    )
                }
            }

            return nil
        }()

        // If sentence contains only punctuation/symbols and has no preceding context,
        // do not dispatch to phonetic correction (which would eat duplicate punctuation like 。。).
        if precedingContext == nil && !Self.containsAlphaNumericOrChinese(sentence) {
            return
        }

        let clientPrecedingRange = precedingContext?.replaceRange
        if let context = precedingContext {
            sentence = context.prefixText + sentence
        }

        let capturedInputting = inputting
        let capturedClient = client
        let token = afmRequestGate.token()
        let afmClient = self.afmClient
        let delay = AFMTriggerPolicy.delayNanoseconds(for: sentence)

        AFMDevLogger.shared.log("AFM WHOLE-SENTENCE SCHEDULED delay=\(delay/1_000_000)ms, sentence='\(sentence)', clientPreceding=\(clientPrecedingRange != nil)")

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

            // Visual feedback: While AFM is running, turn the entire composing buffer Indigo!
            let markLen = (capturedInputting.composingBuffer as NSString).length
            capturedInputting.afmPendingRange = NSRange(location: 0, length: markLen)
            capturedClient.setMarkedText(
                capturedInputting.attributedString,
                selectionRange: NSMakeRange(Int(capturedInputting.cursorIndex), 0),
                replacementRange: NSMakeRange(NSNotFound, NSNotFound)
            )
            AFMDevLogger.shared.log("AFM IN FLIGHT (COLOR CHANGED to INDIGO) sentence='\(sentence)'")

            let isTerminal = Self.isTerminalApp(capturedClient)
            let isAiCli = isTerminal ? Self.isAiCliInForeground() : false
            AFMDevLogger.shared.log("CONTEXT EVAL: isTerminal=\(isTerminal), isAiCli=\(isAiCli)")
            let correctedSentence = await afmClient.correctSentence(sentence: sentence, isTerminal: isTerminal, isAiCli: isAiCli)

            guard !Task.isCancelled,
                  let self = self,
                  self.afmRequestGate.isCurrent(token),
                  Preferences.afmAssistEnabled,
                  self.state === capturedInputting,
                  (self.currentClient as AnyObject?) === (capturedClient as AnyObject)
            else {
                if self?.state === capturedInputting {
                    capturedInputting.afmPendingRange = NSMakeRange(NSNotFound, 0)
                    capturedClient.setMarkedText(
                        capturedInputting.attributedString,
                        selectionRange: NSMakeRange(Int(capturedInputting.cursorIndex), 0),
                        replacementRange: NSMakeRange(NSNotFound, NSNotFound)
                    )
                }
                AFMAssistDiagnostics.shared.record(.stale)
                AFMDevLogger.shared.log("AFM STALE or CANCELLED token=\(token)")
                return
            }

            // Clear pending range
            capturedInputting.afmPendingRange = NSMakeRange(NSNotFound, 0)

            guard let correctedSentence = correctedSentence,
                  correctedSentence != sentence
            else {
                // No correction made or unchanged
                capturedClient.setMarkedText(
                    capturedInputting.attributedString,
                    selectionRange: NSMakeRange(Int(capturedInputting.cursorIndex), 0),
                    replacementRange: NSMakeRange(NSNotFound, NSNotFound)
                )
                AFMAssistDiagnostics.shared.record(.unchanged_or_rejected)
                AFMDevLogger.shared.log("AFM WHOLE-SENTENCE UNCHANGED: '\(sentence)'")
                return
            }

            let origNS = sentence as NSString
            let corrNS = correctedSentence as NSString
            let hasCloze = sentence.contains("??") || sentence.contains("？？")
            let isPromptOptimization = (
                sentence.hasPrefix(">>") || sentence.hasPrefix("》》") || sentence.hasPrefix("。。") || sentence.hasPrefix("..") || sentence.hasPrefix("$$") ||
                sentence.hasSuffix(">>") || sentence.hasSuffix("》》") || sentence.hasSuffix("。。") || sentence.hasSuffix("..") || sentence.hasSuffix("$$")
            ) && Preferences.afmPromptOptimizerEnabled
            let allowsLengthChange = (hasCloze && Preferences.afmClozeFillingEnabled) || Preferences.afmSemanticFluencyRewriteEnabled || isPromptOptimization

            if !allowsLengthChange {
                guard origNS.length == corrNS.length else {
                    capturedClient.setMarkedText(
                        capturedInputting.attributedString,
                        selectionRange: NSMakeRange(Int(capturedInputting.cursorIndex), 0),
                        replacementRange: NSMakeRange(NSNotFound, NSNotFound)
                    )
                    AFMDevLogger.shared.log("AFM WHOLE-SENTENCE LENGTH MISMATCH: orig='\(sentence)', corr='\(correctedSentence)'")
                    return
                }
            }

            // Find all changed ranges
            let changedRanges: [NSRange]
            let newCursorIndex: UInt

            if isPromptOptimization {
                changedRanges = [NSRange(location: 0, length: corrNS.length)]
                newCursorIndex = UInt(corrNS.length)
            } else if origNS.length == corrNS.length {
                var ranges: [NSRange] = []
                var currentStart: Int? = nil

                for i in 0..<origNS.length {
                    let origChar = origNS.character(at: i)
                    let corrChar = corrNS.character(at: i)
                    if origChar != corrChar {
                        if currentStart == nil {
                            currentStart = i
                        }
                    } else {
                        if let start = currentStart {
                            ranges.append(NSRange(location: start, length: i - start))
                            currentStart = nil
                        }
                    }
                }
                if let start = currentStart {
                    ranges.append(NSRange(location: start, length: origNS.length - start))
                }
                changedRanges = ranges
                newCursorIndex = capturedInputting.cursorIndex
            } else {
                let diffRange = self.findChangedRange(old: origNS, new: corrNS)
                changedRanges = [diffRange]
                newCursorIndex = UInt(corrNS.length)
            }

            guard !changedRanges.isEmpty else {
                capturedClient.setMarkedText(
                    capturedInputting.attributedString,
                    selectionRange: NSMakeRange(Int(capturedInputting.cursorIndex), 0),
                    replacementRange: NSMakeRange(NSNotFound, NSNotFound)
                )
                return
            }

            // Create new inputting state with corrected text and highlights!
            let newState = InputState.Inputting(
                composingBuffer: correctedSentence,
                cursorIndex: newCursorIndex
            )
            newState.afmHighlightedRanges = changedRanges.map { NSValue(range: $0) }
            if let firstRange = changedRanges.first {
                newState.afmHighlightedRange = firstRange
            }

            if isPromptOptimization, let preceding = precedingContext {
                let marked = capturedClient.markedRange()
                let markedLen = (marked.location != NSNotFound && marked.length != NSNotFound)
                    ? marked.length
                    : (capturedInputting.composingBuffer as NSString).length
                let totalReplaceRange = NSRange(
                    location: preceding.replaceRange.location,
                    length: preceding.replaceRange.length + markedLen
                )
                newState.afmReplacementRange = totalReplaceRange
                AFMDevLogger.shared.log("AFM PROMPT-OPT TOTAL REPLACEMENT RANGE set to \(totalReplaceRange) (preceding=\(preceding.replaceRange), markedLen=\(markedLen))")
            }

            AFMAssistDiagnostics.shared.record(.applied)
            AFMDevLogger.shared.log("AFM WHOLE-SENTENCE APPLIED & HIGHLIGHTED: '\(sentence)' -> '\(correctedSentence)', changedRanges=\(changedRanges)")

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

        AFMDevLogger.shared.log("COMMIT text='\(buffer)'")

        (client as? IMKTextInput)?.insertText(
            buffer, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func handle(state: InputState.Deactivated, previous: InputState, client: Any?) {
        if slashTracker.isActive {
            slashTracker.reset()
        }
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

        let replacementRange = state.afmReplacementRange
        client.setMarkedText(
            state.attributedString, selectionRange: NSMakeRange(Int(state.cursorIndex), 0),
            replacementRange: replacementRange)

        if replacementRange.location != NSNotFound && replacementRange.length > 0 {
            // Verify if client honored replacementRange
            let actualMarked = client.markedRange()
            if actualMarked.location != NSNotFound && actualMarked.location > replacementRange.location {
                // Client ignored replacementRange outside composition!
                // Fallback direct insert: replaces the entire range (preceding committed text + composing buffer) directly
                AFMDevLogger.shared.log("FALLBACK DIRECT INSERT: client ignored replacementRange \(replacementRange), actualMarked=\(actualMarked)")
                client.insertText(state.composingBuffer, replacementRange: replacementRange)
                keyHandler.clear()
                self.state = InputState.Empty()
                return
            }
        }

        if !state.tooltip.isEmpty {
            show(
                tooltip: state.tooltip, composingBuffer: state.composingBuffer,
                cursorIndex: state.cursorIndex, client: client)
        }
        if replacementRange.location == NSNotFound {
            scheduleAFMRequest(inputting: state, client: client)
        }
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
