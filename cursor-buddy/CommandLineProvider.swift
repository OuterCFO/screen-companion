import Foundation

/// Runs configured command-line tools; plain standard output is streamed as the answer.
@MainActor
final class CommandLineAnswerProvider: AnswerProvider {
    let id = "command_line"
    private let configs: () -> [CommandLineProviderConfig]
    init(configs: @escaping () -> [CommandLineProviderConfig]) { self.configs = configs }

    var billing: AnswerBilling { .subscription }
    var isAvailable: Bool { !configs().isEmpty }

    func supports(_ model: OpenClickyModelOption) -> Bool { config(for: model)?.executableURL() != nil }

    func answer(_ request: AnswerRequest, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard let config = config(for: request.model), let executable = config.executableURL() else {
            throw ClaudeCodeCLIProtocol.error("\(request.model.label) is not installed or its command could not be found.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var imagePaths: [String] = []
        if config.sendsImages {
            for (index, image) in request.images.enumerated() {
                let ext = ClaudeCodeCLIProtocol.mediaType(for: image.data) == "image/png" ? "png" : "jpg"
                let url = directory.appendingPathComponent("screen-\(index).\(ext)")
                try image.data.write(to: url)
                imagePaths.append(url.path)
            }
        }
        let prompt = CommandLineProviderConfig.flattenedPrompt(
            systemPrompt: request.systemPrompt, history: request.history, imageLabels: request.images.map(\.label),
            prompt: request.prompt, sendsImages: config.sendsImages)
        let invocation = config.invocation(prompt: prompt, imagePaths: imagePaths)
        return try await CommandLineRun.run(executable: executable, arguments: invocation.arguments,
                                            standardInput: invocation.standardInput, workingDirectory: directory,
                                            timeout: .seconds(config.timeoutSeconds ?? 120), onText: onText)
    }

    private func config(for model: OpenClickyModelOption) -> CommandLineProviderConfig? {
        configs().first { $0.modelID == model.id }
    }
}

/// Runs one command, streaming standard output as accumulated text.
@MainActor
enum CommandLineRun {
    static func run(executable: URL, arguments: [String], standardInput: String?, workingDirectory: URL,
                    timeout: Duration, onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        let process = Process()
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ClaudeCodeCLIProtocol.environment(base: ProcessInfo.processInfo.environment, executable: executable,
                                                                maxOutputTokens: nil, customBaseURL: nil, customAPIKey: nil)
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        let state = CommandLineRunState()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                state.output.append(data)
                if let text = String(data: state.output, encoding: .utf8) { onText(text) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            Task { @MainActor in state.errors = String((state.errors + (String(data: data, encoding: .utf8) ?? "")).suffix(2_000)) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                state.continuation = continuation
                guard !Task.isCancelled else { state.finish(.failure(CancellationError())); return }
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        output.fileHandleForReading.readabilityHandler = nil
                        errors.fileHandleForReading.readabilityHandler = nil
                        if let rest = try? output.fileHandleForReading.readToEnd() { state.output.append(rest) }
                        let text = (String(data: state.output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if status == 0, !text.isEmpty {
                            state.finish(.success(text))
                        } else {
                            let detail = state.errors.trimmingCharacters(in: .whitespacesAndNewlines)
                            state.finish(.failure(ClaudeCodeCLIProtocol.error(
                                "\(executable.lastPathComponent) exited with status \(status)" + (detail.isEmpty ? "." : ": " + detail))))
                        }
                    }
                }
                do {
                    try process.run()
                    if let standardInput { try input.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8)) }
                    try input.fileHandleForWriting.close()
                } catch {
                    state.finish(.failure(error))
                    return
                }
                state.timeout = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, process.isRunning else { return }
                    process.terminate()
                    state.finish(.failure(ClaudeCodeCLIProtocol.error("\(executable.lastPathComponent) did not finish in time.")))
                }
            }
        } onCancel: {
            Task { @MainActor in
                if process.isRunning { process.terminate() }
                state.finish(.failure(CancellationError()))
            }
        }
    }
}

@MainActor
private final class CommandLineRunState {
    var output = Data()
    var errors = ""
    var continuation: CheckedContinuation<String, Error>?
    var timeout: Task<Void, Never>?

    func finish(_ result: Result<String, Error>) {
        timeout?.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
