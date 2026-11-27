import Foundation

/// The user's signed-in Antigravity CLI (`agy`); uses their Google plan.
/// Screenshots are written to a per-turn folder that `agy` runs in and reads, then deleted.
@MainActor
final class AntigravityAnswerProvider: AnswerProvider {
    let id = "antigravity_cli"
    let billing = AnswerBilling.subscription

    var isAvailable: Bool { AntigravityCLIProtocol.findExecutable() != nil }

    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard let executable = AntigravityCLIProtocol.findExecutable() else {
            throw AntigravityCLIProtocol.error("Antigravity CLI is not installed. See docs/ANTIGRAVITY.md.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-agy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var screenshots: [(path: String, label: String)] = []
        for (index, image) in request.images.enumerated() {
            let ext = ClaudeCodeCLIProtocol.mediaType(for: image.data) == "image/png" ? "png" : "jpg"
            let url = directory.appendingPathComponent("screen-\(index + 1).\(ext)")
            try image.data.write(to: url)
            screenshots.append((url.path, image.label))
        }
        let contextFolder = Self.contextFolder()
        let prompt = AntigravityCLIProtocol.prompt(systemPrompt: request.systemPrompt, history: request.history,
                                                   screenshots: screenshots, contextFolder: contextFolder, prompt: request.prompt)
        let arguments = AntigravityCLIProtocol.arguments(model: request.model.id, prompt: prompt,
                                                         contextFolders: contextFolder.map { [$0] } ?? [])
        OpenClickyMessageLogStore.shared.append(lane: "voice", direction: "outgoing", event: "antigravity.turn", fields: [
            "model": request.model.id, "screenshots": String(screenshots.count), "context": contextFolder ?? ""
        ])
        return try await CommandLineRun.run(
            executable: executable, arguments: arguments, standardInput: nil, workingDirectory: directory,
            timeout: .seconds(AntigravityCLIProtocol.defaultTimeoutSeconds + 15),
            environment: AntigravityCLIProtocol.environment(base: ProcessInfo.processInfo.environment, executable: executable),
            outputText: { output in
                let state = AntigravityCLIProtocol.StreamState.parse(output)
                if let failure = state.failure { throw AntigravityCLIProtocol.error(failure) }
                return state.finalText ?? state.text
            },
            onText: onText)
    }

    /// The configured project folder, when it exists.
    static func contextFolder() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: AntigravityCLIProtocol.contextFolderDefaultsKey) else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
    }
}
