//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//
//  The same tap detects type-to-ask: control tapped twice quickly on its
//  own. Any other key, modifier, or click in between cancels it, so ctrl
//  shortcuts (ctrl + C in Terminal, ctrl-click) and push-to-talk never
//  trigger it.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// Sends when control is tapped twice on its own (type-to-ask).
    let typeToAskDoubleTapPublisher = PassthroughSubject<Void, Never>()
    private var isControlCurrentlyDown = false
    /// When the current control press began; nil if it was cancelled.
    private var currentControlPressStartDate: Date?
    /// When a clean first tap ended, waiting for the second.
    private var firstControlTapEndDate: Date?
    /// Longer than this is a hold (like the start of ctrl + option), not a tap.
    private static let maximumControlTapHoldSeconds: TimeInterval = 0.35
    /// The second tap must start this soon after the first one ends.
    private static let maximumSecondsBetweenControlTaps: TimeInterval = 0.4

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        // Mouse downs are watched only so a ctrl-click doesn't count as a
        // type-to-ask tap.
        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        updateTypeToAskDoubleTapDetection(eventType: eventType, modifierFlags: event.flags)

        return Unmanaged.passUnretained(event)
    }

    private func updateTypeToAskDoubleTapDetection(eventType: CGEventType, modifierFlags: CGEventFlags) {
        guard eventType == .flagsChanged else {
            // A key or click means control is being used for something else
            // (ctrl + C, ctrl-click, ...), so neither tap counts.
            if eventType == .keyDown || eventType == .leftMouseDown
                || eventType == .rightMouseDown || eventType == .otherMouseDown {
                cancelTypeToAskDoubleTap()
            }
            return
        }

        let isControlDown = modifierFlags.contains(.maskControl)
        let isAnotherModifierDown = modifierFlags.contains(.maskCommand)
            || modifierFlags.contains(.maskAlternate)
            || modifierFlags.contains(.maskShift)

        if isAnotherModifierDown {
            // ctrl + option is push-to-talk; ctrl + cmd/shift are shortcuts.
            cancelTypeToAskDoubleTap()
            isControlCurrentlyDown = isControlDown
            return
        }

        if isControlDown && !isControlCurrentlyDown {
            // Control went down.
            isControlCurrentlyDown = true
            let currentDate = Date()
            if let firstControlTapEndDate,
               currentDate.timeIntervalSince(firstControlTapEndDate) > Self.maximumSecondsBetweenControlTaps {
                self.firstControlTapEndDate = nil
            }
            currentControlPressStartDate = currentDate
        } else if !isControlDown && isControlCurrentlyDown {
            // Control came up.
            isControlCurrentlyDown = false
            guard let currentControlPressStartDate else { return }
            self.currentControlPressStartDate = nil
            let currentDate = Date()
            guard currentDate.timeIntervalSince(currentControlPressStartDate) <= Self.maximumControlTapHoldSeconds else {
                firstControlTapEndDate = nil
                return
            }
            if firstControlTapEndDate != nil {
                firstControlTapEndDate = nil
                typeToAskDoubleTapPublisher.send()
            } else {
                firstControlTapEndDate = currentDate
            }
        }
    }

    private func cancelTypeToAskDoubleTap() {
        currentControlPressStartDate = nil
        firstControlTapEndDate = nil
    }
}
