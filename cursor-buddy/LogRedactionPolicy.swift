import Foundation

/// Decides which log field names hold credentials.
/// Matches names that end in a secret noun, so `refreshToken` and `openAIAPIKey` are hidden
/// while measurements such as `maxOutputTokens`, `firstTokenLatencyMs`, and `apiKeyFallback` stay readable.
nonisolated enum LogRedactionPolicy {
    private static let secretSuffixes = ["token", "apikey", "secretkey", "privatekey", "accesskey", "authorization", "password", "secret", "credential", "cookie"]

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().filter { $0.isLetter || $0.isNumber }
        return secretSuffixes.contains { normalized.hasSuffix($0) } || normalized == "xapikey"
    }
}
