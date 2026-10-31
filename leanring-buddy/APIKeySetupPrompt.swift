//
//  APIKeySetupPrompt.swift
//  leanring-buddy
//
//  On launch, asks for any API key that isn't saved in the Keychain yet.
//  This is the only way keys get into the app until a settings screen exists.
//

import AppKit

@MainActor
enum APIKeySetupPrompt {
    static func promptForMissingAPIKeysIfNeeded() {
        let missingAPIKeyKinds = StoredAPIKeyKind.allCases.filter { apiKeyKind in
            APIKeyKeychainStore.readAPIKey(for: apiKeyKind) == nil
        }

        guard !missingAPIKeyKinds.isEmpty else { return }

        // The app has no Dock icon or main window, so it must activate itself
        // or the alert would open behind whatever app is in front.
        NSApp.activate(ignoringOtherApps: true)

        for missingAPIKeyKind in missingAPIKeyKinds {
            promptForAPIKey(missingAPIKeyKind)
        }
    }

    private static func promptForAPIKey(_ apiKeyKind: StoredAPIKeyKind) {
        let apiKeyAlert = NSAlert()
        apiKeyAlert.messageText = "Enter your \(apiKeyKind.serviceDisplayName) API key"

        var informativeText = "heySona saves it in your macOS Keychain and sends it only to that service.\n\nGet one at \(apiKeyKind.whereToGetKeyURL)."
        if !apiKeyKind.isRequired {
            informativeText += "\n\nOptional: skip it and heySona uses Apple's built-in speech recognition instead."
        }
        apiKeyAlert.informativeText = informativeText

        let apiKeyTextField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        apiKeyTextField.placeholderString = "Paste API key"
        apiKeyAlert.accessoryView = apiKeyTextField

        apiKeyAlert.addButton(withTitle: "Save")
        apiKeyAlert.addButton(withTitle: "Skip")
        apiKeyAlert.window.initialFirstResponder = apiKeyTextField

        let userResponse = apiKeyAlert.runModal()
        guard userResponse == .alertFirstButtonReturn else { return }

        APIKeyKeychainStore.saveAPIKey(apiKeyTextField.stringValue, for: apiKeyKind)
    }
}
