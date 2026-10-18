import Foundation

nonisolated enum SharedCodexSessionContract {
    // Increment when the linked-thread contract changes. Acknowledged registrations survive reconnects.
    static let responseContractVersion = 1
    static let responseContractDefaultsKey = "OpenClicky.sharedResponseContracts"
    static let responseInstructions = """
    OpenClicky response contract (supersedes older response-format rules):
    Start every answer with [POINT:x,y:label] on its own first line, optionally adding :screenN inside the bracket. Coordinates are verified pixels in the current attached screenshot, origin top-left. Use [POINT:none] when no current screenshot target is verifiable; never invent a target or reuse an older screenshot.
    Next write the full answer. Finish with a concise summary (at most 60 words and 600 characters) enclosed in <cursor_reply> and </cursor_reply>, each tag on its own separate line. Nothing follows the closing tag. Control tags must not be inline, quoted, or fenced. Order: POINT, full answer, final cursor_reply block.
    """

    static func instructionParameters(threadID: String) -> [String: Any] {
        ["threadId": threadID, "items": [["type": "message", "role": "developer",
            "content": [["type": "input_text", "text": responseInstructions]]]]]
    }

    static func userText(_ prompt: String, screenLabels: [String]) -> String {
        guard !screenLabels.isEmpty else { return prompt }
        return prompt + "\n\n[OpenClicky current screenshots: " + screenLabels.joined(separator: "; ") + "]"
    }

    static func needsInstructions(threadID: String, defaults: UserDefaults) -> Bool {
        let versions = defaults.dictionary(forKey: responseContractDefaultsKey) ?? [:]
        return versions[threadID] as? Int != responseContractVersion
    }

    static func acknowledgeInstructions(threadID: String, defaults: UserDefaults) {
        var versions = defaults.dictionary(forKey: responseContractDefaultsKey) ?? [:]
        versions[threadID] = responseContractVersion
        defaults.set(versions, forKey: responseContractDefaultsKey)
    }

    static func isLive(_ status: String) -> Bool { status == "idle" || status == "active" }
    static func isValidScreenshotPoint(_ point: CGPoint, width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && point.x.isFinite && point.y.isFinite
            && point.x >= 0 && point.y >= 0 && point.x <= CGFloat(width) && point.y <= CGFloat(height)
    }
    static func turnParameters(threadID: String, input: [[String: Any]]) -> [String: Any] {
        // Session settings belong to the original Codex client.
        ["threadId": threadID, "input": input]
    }
}
