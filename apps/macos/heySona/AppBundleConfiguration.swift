import Foundation

enum AppBundleConfiguration {
    static var serverBaseURL: String {
        stringValue(forKey: "HeySonaServerBaseURL") ?? "http://localhost:8787"
    }

    static var clerkPublishableKey: String? {
        stringValue(forKey: "ClerkPublishableKey")
    }

    static var clerkCallbackScheme: String {
        stringValue(forKey: "ClerkCallbackScheme") ?? Bundle.main.bundleIdentifier ?? "heysona"
    }

    static var clerkRedirectURL: String {
        stringValue(forKey: "ClerkRedirectURL") ?? "\(clerkCallbackScheme)://callback"
    }

    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedValue = normalizedBuildSettingValue(trimmedValue) {
                return normalizedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedBuildSettingValue(trimmedValue)
    }

    private static func normalizedBuildSettingValue(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        // Xcode leaves unresolved build settings as literal strings like
        // "$(HEYSONA_SERVER_BASE_URL)". Treat those as missing so callers use
        // their local defaults instead of building invalid URLs.
        if trimmedValue.hasPrefix("$(") && trimmedValue.hasSuffix(")") {
            return nil
        }

        return trimmedValue
    }
}
