import Foundation

/// Pure helpers for Google's Antigravity CLI (`agy`), which answers with the user's Google sign-in.
/// Each turn is a fresh, stateless `agy -p` run in its own folder, so OpenClicky never shares
/// conversations with the Antigravity app. See docs/ANTIGRAVITY.md.
nonisolated enum AntigravityCLIProtocol {
    static let executableOverrideKey = "OPENCLICKY_AGY_EXECUTABLE"
    /// Optional folder the model may read for project context, such as the user's Antigravity workspace.
    static let contextFolderDefaultsKey = "openClickyAntigravityContextFolder"
    static let defaultTimeoutSeconds = 120

    static func error(_ message: String) -> NSError {
        NSError(domain: "AntigravityCLI", code: -40, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Discovery

    static func executableCandidates(home: String, user: String, environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let override = environment[executableOverrideKey], !override.isEmpty { candidates.append(override) }
        candidates += [home + "/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
                       "/etc/profiles/per-user/" + user + "/bin/agy", home + "/.nix-profile/bin/agy",
                       "/run/current-system/sw/bin/agy"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { $0 + "/agy" }
        return candidates
    }

    static func findExecutable(fileManager: FileManager = .default,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        executableCandidates(home: fileManager.homeDirectoryForCurrentUser.path, user: NSUserName(), environment: environment)
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: Input

    /// Headless, read-mostly arguments: in print mode `agy` soft-denies every tool that needs approval,
    /// so the model can read files but cannot edit them or run commands.
    static func arguments(model: String, prompt: String, contextFolders: [String]) -> [String] {
        var arguments = ["-p", prompt, "--model", model, "--output-format", "stream-json",
                         "--disable-slash-commands", "--print-timeout", "\(defaultTimeoutSeconds)s"]
        for folder in contextFolders where !folder.isEmpty { arguments += ["--add-dir", folder] }
        return arguments
    }

    /// One prompt: OpenClicky's policy and history, the screenshot files to open, then the question.
    static func prompt(systemPrompt: String, history: [(userPlaceholder: String, assistantResponse: String)],
                       screenshots: [(path: String, label: String)], contextFolder: String?, prompt: String) -> String {
        var blocks = ClaudeCodeCLIProtocol.standaloneTextBlocks(systemPrompt: systemPrompt, history: history,
                                                                imageLabels: [], prompt: prompt)
        var rules = ["You are answering inside OpenClicky, a screen companion. Only read: never edit files, run commands, or browse."]
        if !screenshots.isEmpty {
            rules.append("Before answering, open each screenshot of the user's screen with your file viewing tool:")
            rules += screenshots.enumerated().map { "\($0.offset + 1). \($0.element.path) (\($0.element.label))" }
        }
        if let contextFolder, !contextFolder.isEmpty {
            rules.append("The user's current project is in \(contextFolder). If it helps, read its GEMINI.md or files there for context.")
        }
        blocks.insert(rules.joined(separator: "\n"), at: blocks.count - 1)
        return blocks.joined(separator: "\n\n")
    }

    /// PATH includes the CLI's folder; Gemini API keys are removed so answers use the Google sign-in.
    static func environment(base: [String: String], executable: URL) -> [String: String] {
        var environment = base
        let path = [executable.deletingLastPathComponent().path, base["PATH"] ?? "", "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = path.filter { !$0.isEmpty }.joined(separator: ":")
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY"] { environment.removeValue(forKey: key) }
        return environment
    }

    // MARK: Output

    /// Reads `agy --output-format stream-json` output. Shows only the latest answer step, so text the
    /// model writes before opening a screenshot is replaced by the real answer.
    nonisolated struct StreamState {
        private(set) var text = ""
        private(set) var finalText: String?
        private(set) var failure: String?
        private var answerStep = -1

        mutating func consume(line: String) {
            guard finalText == nil, failure == nil, let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String else { return }
            if event == "step_update", let step = object["step_update"] as? [String: Any],
               step["step_type"] as? String == "agent_response", let delta = step["text_delta"] as? String {
                let index = step["step_index"] as? Int ?? answerStep
                if index != answerStep { answerStep = index; text = "" }
                text += delta
            } else if event == "result", let result = object["result"] as? [String: Any] {
                if result["status"] as? String == "SUCCESS" {
                    finalText = (result["response"] as? String ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let message = (result["error"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
                    failure = "Antigravity: " + (message.isEmpty ? "the answer failed (\(result["status"] as? String ?? "unknown"))." : message)
                }
            }
        }

        /// Parses all complete lines of the output so far.
        static func parse(_ output: Data) -> StreamState {
            var state = StreamState()
            String(decoding: output, as: UTF8.self).split(separator: "\n").forEach { state.consume(line: String($0)) }
            return state
        }
    }

    // MARK: Models

    static let models: [(id: String, label: String)] = [
        ("gemini-4-neon-low", "Gemini 4 Neon Low (Antigravity)"),
        ("gemini-4-neon-medium", "Gemini 4 Neon (Antigravity)"),
        ("gemini-4-carbon-medium", "Gemini 4 Carbon (Antigravity)"),
        ("gemini-4-argon-medium", "Gemini 4 Argon (Antigravity)"),
        ("gemini-4-hydrogen-medium", "Gemini 4 Hydrogen (Antigravity)")
    ]
}
