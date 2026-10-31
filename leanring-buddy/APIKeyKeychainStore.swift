//
//  APIKeyKeychainStore.swift
//  leanring-buddy
//
//  Stores the API keys for Anthropic, AssemblyAI, and ElevenLabs in the
//  macOS login Keychain. The app calls these services directly with the
//  keys, so nothing sensitive lives in source code or the app bundle.
//

import Foundation
import Security

/// Each external service the app needs a key for. The raw value is used as
/// the Keychain account name, so it must stay stable once keys are saved.
enum StoredAPIKeyKind: String, CaseIterable {
    case anthropic = "anthropic-api-key"
    case assemblyAI = "assemblyai-api-key"
    case elevenLabs = "elevenlabs-api-key"

    var serviceDisplayName: String {
        switch self {
        case .anthropic:
            return "Anthropic (Claude)"
        case .assemblyAI:
            return "AssemblyAI (speech-to-text)"
        case .elevenLabs:
            return "ElevenLabs (text-to-speech)"
        }
    }

    var whereToGetKeyURL: String {
        switch self {
        case .anthropic:
            return "console.anthropic.com/settings/keys"
        case .assemblyAI:
            return "assemblyai.com/dashboard"
        case .elevenLabs:
            return "elevenlabs.io/app/settings/api-keys"
        }
    }

    /// AssemblyAI is optional because the app falls back to Apple Speech
    /// when no AssemblyAI key is saved.
    var isRequired: Bool {
        self != .assemblyAI
    }
}

struct MissingAPIKeyError: LocalizedError {
    let missingAPIKeyKind: StoredAPIKeyKind

    var errorDescription: String? {
        "No \(missingAPIKeyKind.serviceDisplayName) API key is saved. Relaunch heySona to enter it."
    }
}

enum APIKeyKeychainStore {
    /// Groups all heySona keys under one Keychain service name so they are
    /// easy to find in Keychain Access.
    private static let keychainServiceName = "heySona"

    static func readAPIKey(for apiKeyKind: StoredAPIKeyKind) -> String? {
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: apiKeyKind.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var keychainResult: AnyObject?
        let readStatus = SecItemCopyMatching(keychainQuery as CFDictionary, &keychainResult)

        guard readStatus == errSecSuccess,
              let apiKeyData = keychainResult as? Data,
              let apiKeyString = String(data: apiKeyData, encoding: .utf8) else {
            return nil
        }

        let trimmedAPIKey = apiKeyString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAPIKey.isEmpty ? nil : trimmedAPIKey
    }

    /// Same as `readAPIKey`, but throws a readable error when the key is
    /// missing so API clients can surface it instead of sending a bad request.
    static func requireAPIKey(for apiKeyKind: StoredAPIKeyKind) throws -> String {
        guard let apiKey = readAPIKey(for: apiKeyKind) else {
            throw MissingAPIKeyError(missingAPIKeyKind: apiKeyKind)
        }
        return apiKey
    }

    static func deleteAPIKey(for apiKeyKind: StoredAPIKeyKind) {
        let itemIdentityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: apiKeyKind.rawValue
        ]
        SecItemDelete(itemIdentityQuery as CFDictionary)
    }

    @discardableResult
    static func saveAPIKey(_ apiKey: String, for apiKeyKind: StoredAPIKeyKind) -> Bool {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty, let apiKeyData = trimmedAPIKey.data(using: .utf8) else {
            return false
        }

        let itemIdentityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: apiKeyKind.rawValue
        ]

        // Update the existing item if there is one, otherwise create it.
        let updateStatus = SecItemUpdate(
            itemIdentityQuery as CFDictionary,
            [kSecValueData as String: apiKeyData] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            print("⚠️ Keychain: failed to update \(apiKeyKind.rawValue) (status \(updateStatus))")
            return false
        }

        var newItemAttributes = itemIdentityQuery
        newItemAttributes[kSecValueData as String] = apiKeyData
        newItemAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(newItemAttributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("⚠️ Keychain: failed to save \(apiKeyKind.rawValue) (status \(addStatus))")
        }
        return addStatus == errSecSuccess
    }
}
