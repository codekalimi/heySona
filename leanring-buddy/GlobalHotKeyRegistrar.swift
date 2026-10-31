//
//  GlobalHotKeyRegistrar.swift
//  leanring-buddy
//
//  Registers system-wide key combos (like cmd + shift + space) with Carbon's
//  RegisterEventHotKey. Unlike the listen-only CGEvent tap used for
//  push-to-talk, a Carbon hot key consumes the keystroke, so the app in front
//  never receives it (no stray space typed, no Esc closing someone's dialog).
//  It also needs no Accessibility permission.
//

import Carbon
import Foundation

/// Handle for one registered hot key. Pass it back to `unregister` to free it.
struct RegisteredGlobalHotKey {
    fileprivate let hotKeyIdentifier: UInt32
    fileprivate let carbonHotKeyReference: EventHotKeyRef
}

@MainActor
final class GlobalHotKeyRegistrar {
    /// Four-character code that tags every hot key this app registers ("hSna").
    private static let hotKeySignature: OSType = 0x68536E61

    private var actionsByHotKeyIdentifier: [UInt32: () -> Void] = [:]
    private var nextHotKeyIdentifier: UInt32 = 1
    private var carbonEventHandlerReference: EventHandlerRef?

    /// Registers a hot key. `carbonKeyCode` is a `kVK_*` constant and
    /// `carbonModifierFlags` combines `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    /// Returns nil if another app already owns the same combo.
    func register(
        carbonKeyCode: Int,
        carbonModifierFlags: Int,
        action: @escaping () -> Void
    ) -> RegisteredGlobalHotKey? {
        installCarbonEventHandlerIfNeeded()

        let hotKeyIdentifier = nextHotKeyIdentifier
        nextHotKeyIdentifier += 1

        var carbonHotKeyReference: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(carbonKeyCode),
            UInt32(carbonModifierFlags),
            EventHotKeyID(signature: Self.hotKeySignature, id: hotKeyIdentifier),
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyReference
        )

        guard registrationStatus == noErr, let carbonHotKeyReference else {
            print("⚠️ Hot key: could not register key code \(carbonKeyCode) (status \(registrationStatus))")
            return nil
        }

        actionsByHotKeyIdentifier[hotKeyIdentifier] = action
        return RegisteredGlobalHotKey(
            hotKeyIdentifier: hotKeyIdentifier,
            carbonHotKeyReference: carbonHotKeyReference
        )
    }

    func unregister(_ registeredGlobalHotKey: RegisteredGlobalHotKey) {
        UnregisterEventHotKey(registeredGlobalHotKey.carbonHotKeyReference)
        actionsByHotKeyIdentifier[registeredGlobalHotKey.hotKeyIdentifier] = nil
    }

    fileprivate func handleHotKeyPressed(hotKeyIdentifier: UInt32) {
        actionsByHotKeyIdentifier[hotKeyIdentifier]?()
    }

    /// Carbon delivers every hot key press through one application-level
    /// event handler, which looks up the action by the hot key's identifier.
    private func installCarbonEventHandlerIfNeeded() {
        guard carbonEventHandlerReference == nil else { return }

        var hotKeyPressedEventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let registrarPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, carbonEvent, userData in
                guard let carbonEvent, let userData else { return OSStatus(eventNotHandledErr) }

                var pressedHotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    carbonEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedHotKeyID
                )
                guard parameterStatus == noErr,
                      pressedHotKeyID.signature == GlobalHotKeyRegistrar.hotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }

                let registrar = Unmanaged<GlobalHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                // Carbon application events are dispatched on the main thread.
                MainActor.assumeIsolated {
                    registrar.handleHotKeyPressed(hotKeyIdentifier: pressedHotKeyID.id)
                }
                return noErr
            },
            1,
            &hotKeyPressedEventType,
            registrarPointer,
            &carbonEventHandlerReference
        )
    }
}
