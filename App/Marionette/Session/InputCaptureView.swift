// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import UIKit
import MarionetteKit

/// The UIKit view that takes raw touches, pointer events and key input for a session.
///
/// Touches are not run through gesture recognisers: every event is handed, whole, to the session
/// model, whose interpreters decide what it means. On the remote display the view is also the first
/// responder, so text from the software keyboard, input methods and dictation arrives here, and so do
/// the presses of a hardware keyboard.
struct InputCapture: UIViewRepresentable {
    let session: SessionModel
    let surface: SessionModel.TouchSurface
    /// Whether the view should hold first responder (remote display only).
    var takesKeyboard = false
    var showsKeyboard = false
    var accessibilityLabel = ""
    var accessibilityHint = ""
    /// UI tests read what was sent from the view's accessibility value. Nobody else may: it holds
    /// what was last typed.
    var reportsDiagnostics = false

    func makeUIView(context: Context) -> InputCaptureView {
        InputCaptureView(surface: surface)
    }

    func updateUIView(_ view: InputCaptureView, context: Context) {
        view.session = session
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityHint = accessibilityHint.isEmpty ? nil : accessibilityHint
        view.reportsDiagnostics = reportsDiagnostics
        // Read so that this view is refreshed when the status changes; the value itself is computed
        // on demand in the view.
        _ = session.statusLine
        // After this update, not inside it: showing or hiding the keyboard makes UIKit move its
        // keyboard-tracking layout at once, which re-renders SwiftUI from within this update. On
        // iOS 27.1 (iPhone Duo) that re-entry traps the view graph in a cycle and the app freezes
        // when the keyboard is hidden.
        let wanted = takesKeyboard, visible = showsKeyboard
        DispatchQueue.main.async { [weak view] in
            view?.setKeyboard(wanted: wanted, visible: visible)
        }
    }

    static func dismantleUIView(_ view: InputCaptureView, coordinator: ()) {
        view.session?.releaseAllInput()
        view.session = nil
    }
}

final class InputCaptureView: UIView, UIKeyInput, UIPointerInteractionDelegate {
    weak var session: SessionModel? {
        didSet {
            if session !== oldValue { accessory = nil }
        }
    }

    private let surface: SessionModel.TouchSurface
    var reportsDiagnostics = false
    private var touchIDs: [UITouch: Int] = [:]
    private var nextTouchID = 0
    private var wantsKeyboardFocus = false
    private var showsSoftwareKeyboard = false
    /// Stands in for the keyboard while it should be hidden: the view stays first responder, so a
    /// hardware keyboard keeps working, but nothing appears on screen.
    private let emptyInputView = UIView(frame: .zero)
    private var accessory: KeyboardAccessoryView?
    /// The characters of the last hardware key that went down, and when, to recognise the same text
    /// arriving a second time through the text-input path.
    private var lastHardwareText: (text: String, time: TimeInterval)?
    /// Files dragged in from other apps, on the remote display.
    private var fileDrops: FileDropHandler?

    init(surface: SessionModel.TouchSurface) {
        self.surface = surface
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = true
        // VoiceOver users operate the remote machine by touching through, as with any canvas.
        accessibilityTraits = .allowsDirectInteraction
        // The whole screen is the picture: feeling for the controls must not click on the Mac. The
        // trackpad below is a surface of its own and is touched at once, like the real thing.
        if surface == .stage { accessibilityDirectTouchOptions = .requiresActivation }
        accessibilityIdentifier = surface == .stage ? "remote-display" : "deck-trackpad"
        if surface == .stage {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            installPointerSupport()
            let fileDrops = FileDropHandler(view: self)
            addInteraction(UIDropInteraction(delegate: fileDrops))
            self.fileDrops = fileDrops
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The connection status and, for UI tests only, the zoom and a tally of what has been sent.
    /// Computed when asked for, so it is always the current state.
    override var accessibilityValue: String? {
        get {
            guard let session else { return nil }
            guard surface == .stage else { return nil }
            guard reportsDiagnostics else { return session.statusLine }
            let zoom = Int((session.uiState.viewport.magnification * 100).rounded())
            let mode = session.uiState.inputMode == .touch ? "touch mode" : "trackpad mode"
            let display = session.selectedDisplay.map { "display \($0.pixelSize.width)×\($0.pixelSize.height)" } ?? "no display"
            return "\(session.statusLine), \(mode), zoom \(zoom) %, \(display), \(session.inputTally.summary), \(session.clipboard.sendCount) clipboard sends, \(isFirstResponder ? "has keyboard focus" : "no keyboard focus")"
        }
        set {}
    }

    // MARK: Touches, Pencil and mouse buttons

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .began, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .moved, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .ended, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .cancelled, event: event)
    }

    /// One call per UIKit event, with all of its finger touches: two-finger gestures depend on seeing
    /// both fingers move together. The Pencil and the mouse are each a pointer of their own.
    private func forward(_ touches: Set<UITouch>, phase: TouchSample.Phase, event: UIEvent?) {
        var samples: [TouchSample] = []
        for touch in touches {
            let location = ViewPoint(touch.preciseLocation(in: self))
            switch touch.type {
            case .indirectPointer where surface == .stage:
                // A mouse or trackpad click: the touch lasts as long as a button is held.
                let ended = phase == .ended || phase == .cancelled
                session?.pointerButtons(ended ? [] : Self.buttons(event?.buttonMask ?? .primary), at: location)
            case .pencil where surface == .stage:
                session?.pencil(TouchSample(id: 0, phase: phase, location: location, timestamp: touch.timestamp))
            case .direct, .pencil:
                let id: Int
                if let known = touchIDs[touch] {
                    id = known
                } else {
                    nextTouchID += 1
                    id = nextTouchID
                    touchIDs[touch] = id
                }
                samples.append(TouchSample(id: id, phase: phase, location: location, timestamp: touch.timestamp))
                if phase == .ended || phase == .cancelled { touchIDs[touch] = nil }
            default:
                break
            }
        }
        guard !samples.isEmpty else { return }
        session?.handleTouches(samples.sorted { $0.id < $1.id }, on: surface)
    }

    private static func buttons(_ mask: UIEvent.ButtonMask) -> PointerButtons {
        var buttons: PointerButtons = []
        if mask.contains(.primary) { buttons.insert(.primary) }
        if mask.contains(.secondary) { buttons.insert(.secondary) }
        if mask.contains(.button(3)) { buttons.insert(.middle) }
        return buttons.isEmpty ? .primary : buttons
    }

    // MARK: Mouse and trackpad

    private func installPointerSupport() {
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        // The remote machine draws the pointer; ours would only sit on top of it.
        addInteraction(UIPointerInteraction(delegate: self))
        // Wheel and two-finger trackpad scrolling arrive as a pan that no finger on the screen can start.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = []
        addGestureRecognizer(pinch)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        session?.phase == .connected ? .hidden() : nil
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        session?.pointerMoved(to: ViewPoint(recognizer.location(in: self)))
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        let phase: ScrollEvent.Phase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        session?.pointerScrolled(
            by: ViewVector(dx: translation.x, dy: translation.y),
            at: ViewPoint(recognizer.location(in: self)),
            phase: phase
        )
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        session?.pointerMagnified(by: recognizer.scale, at: ViewPoint(recognizer.location(in: self)))
        recognizer.scale = 1
    }

    // MARK: Hardware keyboard

    // Every key goes to the remote machine as a key code with its modifiers, so combinations the
    // text system would otherwise interpret (⌘C, ⌥←, ⌃A …) arrive there intact. Not passing a press
    // on to `super` is what stops the system from also treating it as text input.

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, isDown: true) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, isDown: false) }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, isDown: false) }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func handle(_ press: UIPress, isDown: Bool) -> Bool {
        guard surface == .stage, let session, session.acceptsInput, let key = press.key else { return false }
        // ⌃⌥⌘ with one of the app's letters is this app's menu command, not for the remote machine.
        if AppShortcut.isAppShortcut(key) {
            if isDown { AppShortcut.perform(key, in: session) }
            return true
        }
        // ⌘V is left to UIKit, which turns it into the Paste key command (see `keyCommands`).
        if key.keyCode == .keyboardV, key.modifierFlags.intersection([.command, .control, .alternate, .shift]) == .command {
            return false
        }
        let code = KeyCode(rawValue: UInt16(truncatingIfNeeded: key.keyCode.rawValue))
        session.setCapsLock(key.modifierFlags.contains(.alphaShift))
        session.synchronizeHardwareModifiers(Self.modifiers(key.modifierFlags))
        if isDown {
            let characters = Self.printable(key.characters)
            session.keyDown(code, characters: characters, charactersIgnoringModifiers: Self.printable(key.charactersIgnoringModifiers), source: .hardware)
            if let characters { lastHardwareText = (characters, press.timestamp) }
        } else {
            session.keyUp(code, source: .hardware)
        }
        return true
    }

    /// UIKit's modifier flags, which do not tell left from right, as both sides of each kind.
    private static func modifiers(_ flags: UIKeyModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.formUnion(.shift) }
        if flags.contains(.control) { modifiers.formUnion(.control) }
        if flags.contains(.alternate) { modifiers.formUnion(.option) }
        if flags.contains(.command) { modifiers.formUnion(.command) }
        return modifiers
    }

    /// UIKit names keys that type nothing with strings such as "UIKeyInputUpArrow"; those are not text.
    private static func printable(_ text: String) -> String? {
        guard !text.isEmpty, !text.hasPrefix("UIKeyInput"), text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return text
    }

    // MARK: Paste

    // ⌘V on a hardware keyboard is taken as the Paste command rather than as two key presses: a paste
    // the user asked for lets iOS hand over the clipboard without a prompt. The contents go to the
    // remote clipboard and ⌘V follows. ⌘ itself went down through `pressesBegan` like any modifier
    // and is already held on the remote machine.
    //
    // The V press reaches `pressesBegan` first even with this key command declared; UIKit performs
    // the command only when the press is passed on to `super` (iOS 26.1).

    override var keyCommands: [UIKeyCommand]? {
        guard surface == .stage else { return nil }
        let paste = UIKeyCommand(title: String(localized: "Paste"), action: #selector(paste(_:)), input: "v", modifierFlags: .command)
        paste.wantsPriorityOverSystemBehavior = true
        return [paste]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return surface == .stage && session?.acceptsInput == true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard surface == .stage, let session else { return }
        guard session.routesHardwarePaste else {
            // Clipboard sharing is off: ⌘V reaches the remote machine as keys and pastes what it has.
            session.pasteFromHardwareKeyboard(nil)
            return
        }
        // Read inside the action: that is when the system allows it without a prompt.
        let text = UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil
        session.pasteFromHardwareKeyboard(text)
    }

    // MARK: Software keyboard

    func setKeyboard(wanted: Bool, visible: Bool) {
        wantsKeyboardFocus = wanted
        if showsSoftwareKeyboard != visible {
            showsSoftwareKeyboard = visible
            if isFirstResponder { reloadInputViews() }
        }
        updateFirstResponder()
    }

    private func updateFirstResponder() {
        guard window != nil else { return }
        if wantsKeyboardFocus, !isFirstResponder {
            becomeFirstResponder()
        } else if !wantsKeyboardFocus, isFirstResponder {
            resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { surface == .stage && wantsKeyboardFocus }

    override var inputView: UIView? { showsSoftwareKeyboard ? nil : emptyInputView }

    /// The bar of Mac keys rides on top of the system keyboard and goes away with it.
    override var inputAccessoryView: UIView? {
        guard showsSoftwareKeyboard, surface == .stage, let session else { return nil }
        if accessory == nil { accessory = KeyboardAccessoryView(session: session) }
        return accessory
    }

    /// The system's three-finger undo, copy and paste gestures would swallow touches meant for the
    /// remote machine.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        // A hardware key already went out as a key event; if the system delivers its text as well,
        // typing it again would double every character.
        if let last = lastHardwareText, last.text == text, ProcessInfo.processInfo.systemUptime - last.time < 0.05 {
            lastHardwareText = nil
            return
        }
        session?.insertText(text)
    }

    func deleteBackward() {
        session?.deleteBackward()
    }

    // What is typed goes to another computer verbatim: nothing may be corrected, capitalised,
    // substituted or suggested on the way.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    /// Whether the system's keyboard frame excludes the bar of Mac keys (iOS 27 floats the bar above
    /// the keyboard; iOS 26 includes it). Learned from where the bar really is.
    private var keyboardFrameOmitsAccessory = false

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let window, let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let hidden = notification.name == UIResponder.keyboardWillHideNotification
        let keyboard = convert(end, from: window.screen.coordinateSpace)
        guard !hidden, keyboard.height > 0 else {
            session?.setKeyboardOverlap(0)
            return
        }
        var top = max(keyboard.minY, bounds.minY)
        // The bar comes with this view's keyboard only, not with one another field brought up.
        if let accessory, showsSoftwareKeyboard, isFirstResponder {
            if notification.name == UIResponder.keyboardDidChangeFrameNotification, let accessoryWindow = accessory.window {
                let frame = convert(accessory.convert(accessory.bounds, to: accessoryWindow.screen.coordinateSpace), from: window.screen.coordinateSpace)
                keyboardFrameOmitsAccessory = frame.minY < keyboard.minY - 1
                top = min(top, max(frame.minY, bounds.minY))
            } else if keyboardFrameOmitsAccessory {
                top -= KeyboardAccessoryView.height
            }
        }
        session?.setKeyboardOverlap(max(0, bounds.maxY - top))
    }
}
