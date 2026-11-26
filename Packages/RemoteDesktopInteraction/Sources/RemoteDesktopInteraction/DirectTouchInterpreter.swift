// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// Touch screen: every finger goes to the remote machine as it is, and the remote machine's own
/// touch handling decides what it means (``InputEvent/touch(_:)``). For a remote machine that takes
/// touches (``SessionCapabilities/touch``); nothing is turned into pointer input or viewport changes
/// here.
///
/// Fingers beyond ``maximumContacts`` are left out until they lift. A finger keeps its contact id
/// from landing to lifting; a lifted finger's id goes to the next one to land.
public struct DirectTouchInterpreter: GestureInterpreter, Hashable {
    private struct Finger: Hashable {
        var contact: Int
        var position: PixelPoint
        var phase: TouchEvent.Contact.Phase
    }

    public var maximumContacts: Int
    /// By ``TouchSample/id``.
    private var fingers: [Int: Finger] = [:]
    /// The display the fingers are on, as it was when the first landed.
    private var target: PointerTarget?

    public init(maximumContacts: Int) {
        self.maximumContacts = maximumContacts
    }

    public mutating func handle(_ samples: [TouchSample], context: inout InteractionContext) -> [InteractionEffect] {
        var effects: [InteractionEffect] = []
        // Fingers on a display that is no longer the one in front of them are let go there.
        if !fingers.isEmpty, context.target != target {
            effects += cancel(context: &context)
        }
        guard let current = context.target else { return effects }
        var changed = false
        for sample in samples {
            let position = current.clamp(context.viewport.remotePoint(for: sample.location))
            switch sample.phase {
            case .began:
                let taken = Set(fingers.values.map(\.contact))
                guard fingers[sample.id] == nil, let free = (0..<maximumContacts).first(where: { !taken.contains($0) }) else { continue }
                if fingers.isEmpty { target = current }
                fingers[sample.id] = Finger(contact: free, position: position, phase: .touching)
            case .moved, .ended, .cancelled:
                guard var finger = fingers[sample.id] else { continue }
                if sample.phase != .cancelled { finger.position = position }
                finger.phase = switch sample.phase {
                case .ended: .lifted
                case .cancelled: .cancelled
                default: .touching
                }
                fingers[sample.id] = finger
            }
            changed = true
        }
        guard changed else { return effects }
        effects.append(event(for: current))
        fingers = fingers.filter { $0.value.phase == .touching }
        if fingers.isEmpty { target = nil }
        return effects
    }

    public mutating func advance(to time: Double, context: inout InteractionContext) -> [InteractionEffect] {
        []
    }

    public var nextDeadline: Double? { nil }

    public mutating func cancel(context: inout InteractionContext) -> [InteractionEffect] {
        guard let target, !fingers.isEmpty else { return [] }
        for id in fingers.keys { fingers[id]?.phase = .cancelled }
        let effect = event(for: target)
        fingers.removeAll()
        self.target = nil
        return [effect]
    }

    public var isIdle: Bool { fingers.isEmpty }

    private func event(for target: PointerTarget) -> InteractionEffect {
        let contacts = fingers.values
            .sorted { $0.contact < $1.contact }
            .map { TouchEvent.Contact(id: $0.contact, position: $0.position, phase: $0.phase) }
        return .input(.touch(TouchEvent(display: target.display, contacts: contacts, layoutGeneration: target.layoutGeneration)))
    }
}
