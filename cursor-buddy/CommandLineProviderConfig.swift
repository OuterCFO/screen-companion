import Foundation

/// A user-configured command-line tool that answers questions, such as Gemini CLI or `ollama run`.
/// Configured in `~/Library/Application Support/OpenClicky/command-line-providers.json`; see docs/PROVIDERS.md.
nonisolated struct CommandLineProviderConfig: Codable, Equatable, Sendable {
    /// Short identifier; the model ID becomes `cli:<id>`.
    var id: String
    var label: String
    /// An absolute path, or a name found in the usual install folders and PATH.
    var executable: String
    /// `{prompt}` is replaced by the full prompt; without it the prompt goes to standard input.
    /// `{images}` expands to one argument per screenshot file path; without it screenshots are not sent.
    var arguments: [String]
    var timeoutSeconds: Int?

    static let modelPrefix = "cli:"
    var modelID: String { Self.modelPrefix + id }

    static func fileURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return support.appendingPathComponent("OpenClicky/command-line-providers.json")
    }

    /// Valid entries only: unique, filename-safe IDs and a non-empty executable.
    static func decode(_ data: Data) -> [CommandLineProviderConfig] {
        guard let entries = try? JSONDecoder().decode([CommandLineProviderConfig].self, from: data) else { return [] }
        var seen = Set<String>()
        return entries.filter { entry in
            let validID = !entry.id.isEmpty && entry.id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return validID && !entry.executable.isEmpty && seen.insert(entry.id).inserted
        }
    }

    static func load(fileManager: FileManager = .default) -> [CommandLineProviderConfig] {
        (try? Data(contentsOf: fileURL(fileManager: fileManager))).map(decode) ?? []
    }

    /// The process arguments and standard input for one question.
    func invocation(prompt: String, imagePaths: [String]) -> (arguments: [String], standardInput: String?) {
        var arguments: [String] = []
        for argument in self.arguments {
            if argument == "{images}" { arguments += imagePaths; continue }
            arguments.append(argument.replacingOccurrences(of: "{prompt}", with: prompt))
        }
        let usesPromptArgument = self.arguments.contains { $0.contains("{prompt}") }
        return (arguments, usesPromptArgument ? nil : prompt)
    }

    var sendsImages: Bool { arguments.contains("{images}") }

    func executableURL(fileManager: FileManager = .default,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let expanded = (executable as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return fileManager.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let folders = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/etc/profiles/per-user/" + NSUserName() + "/bin",
                       home + "/.nix-profile/bin", "/run/current-system/sw/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return folders.map { $0 + "/" + expanded }.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    var modelOption: OpenClickyModelOption {
        OpenClickyModelOption(id: modelID, label: label, provider: .commandLine, maxOutputTokens: 64_000)
    }

    /// One prompt for tools that take a single text input: policy, history, screens, then the question.
    static func flattenedPrompt(systemPrompt: String, history: [(userPlaceholder: String, assistantResponse: String)],
                                imageLabels: [String], prompt: String, sendsImages: Bool) -> String {
        var blocks = ClaudeCodeCLIProtocol.standaloneTextBlocks(systemPrompt: systemPrompt, history: history,
                                                                 imageLabels: sendsImages ? imageLabels : [], prompt: prompt)
        if !sendsImages, !imageLabels.isEmpty {
            blocks.insert("Screenshots are not available to this tool; answer from the text and say if you need to see the screen.",
                          at: blocks.count - 1)
        }
        return blocks.joined(separator: "\n\n")
    }
}
