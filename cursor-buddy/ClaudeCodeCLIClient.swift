//
//  ClaudeCodeCLIClient.swift
//  OpenClicky
//
//  Drives the user's installed `claude` CLI directly over its stream-json
//  protocol. No Node.js runtime or npm package is required, and the CLI's own
//  sign-in is used. Each turn runs in its own process; one spare process is
//  started ahead of time so the next turn skips CLI startup.
//

import Darwin
import Foundation

/// One `claude -p` process carrying exactly one stream-json turn.
@MainActor
final class ClaudeCodeCLITurnProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private var outputBuffer = Data()
    private var errorTail = ""
    private var state = ClaudeCodeCLIProtocol.StreamState()
    private var continuation: CheckedContinuation<String, Error>?
    private var onText: (@MainActor @Sendable (String) -> Void)?
    private var onSessionStarted: ((String) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    let configurationKey: String
    /// Receives every stream-json line before it is parsed, for callers that need tool events.
    var onLine: ((String) -> Void)?

    var isRunning: Bool { process.isRunning }

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
         configurationKey: String = "") throws {
        self.configurationKey = configurationKey
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consumeOutput(data) }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.errorTail = String(((self?.errorTail ?? "") + text).suffix(2_000)) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            // Let already-delivered output chunks run first so lines stay in order.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                self?.handleTermination(status: status)
            }
        }
        try process.run()
    }

    /// Sends one user message, closes input, and waits for the turn's final result.
    /// With `keepsRunningOnCancel`, cancellation only stops waiting; the turn still completes in its session.
    func run(message: Data, timeout: Duration, keepsRunningOnCancel: Bool = false,
             onSessionStarted: ((String) -> Void)? = nil,
             onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                guard process.isRunning else {
                    pending.resume(throwing: ClaudeCodeCLIProtocol.error("Claude Code exited before the request was sent. " + errorTail))
                    return
                }
                continuation = pending
                self.onText = onText
                self.onSessionStarted = onSessionStarted
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(ClaudeCodeCLIProtocol.error("Claude Code did not finish within \(timeout.components.seconds) seconds.")))
                }
                do {
                    try input.fileHandleForWriting.write(contentsOf: message)
                    try input.fileHandleForWriting.close()
                } catch {
                    finish(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), terminating: !keepsRunningOnCancel) }
        }
    }

    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[outputBuffer.startIndex..<newline]
            outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            onLine?(line)
            switch state.consume(line: line) {
            case .started(let sessionID): onSessionStarted?(sessionID)
            case .text(let text): onText?(text)
            case .finished(let text): finish(.success(text))
            case .failed(let message): finish(.failure(ClaudeCodeCLIProtocol.error(message)))
            case nil: break
            }
        }
    }

    private func handleTermination(status: Int32) {
        // Read whatever the exited process left in the pipe, then flush a final unterminated line.
        output.fileHandleForReading.readabilityHandler = nil
        if let rest = try? output.fileHandleForReading.readToEnd(), !rest.isEmpty { consumeOutput(rest) }
        if !outputBuffer.isEmpty { consumeOutput(Data([0x0A])) }
        let detail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(.failure(ClaudeCodeCLIProtocol.error("Claude Code exited with status \(status) before finishing." + (detail.isEmpty ? "" : " " + detail))))
    }

    private func finish(_ result: Result<String, Error>, terminating: Bool = true) {
        guard let pending = continuation else { return }
        continuation = nil
        onText = nil
        onSessionStarted = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure = result, terminating { terminate() }
        pending.resume(with: result)
    }

}

@MainActor private final class FirstTextFlag { var pending = true }

/// Standalone OpenClicky turns answered by Claude Code with the selected model.
@MainActor
final class ClaudeCodeCLIClient {
    private let executableURL: URL
    private let workingDirectory: URL
    private var spare: ClaudeCodeCLITurnProcess?
    private var running: [ObjectIdentifier: ClaudeCodeCLITurnProcess] = [:]
    var model: String
    var maxOutputTokens: Int
    private static let requestTimeout: Duration = .seconds(120)

    private static let persistentSystemPrompt = """
    You are OpenClicky's local Claude Code voice response session.
    Follow the current OpenClicky voice policy and context supplied with each user turn.
    Answer like a capable coworker over the user's shoulder: one or two natural spoken sentences by default, no bullets, markdown, headings, tables, or code blocks unless explicitly requested.

    \(ThreeDGenerationDispatcher.systemPromptInstruction)
    """

    init?(model: String = OpenClickyModelCatalog.defaultAnthropicResponseModelID,
          maxOutputTokens: Int = 64_000, fileManager: FileManager = .default) {
        guard let executableURL = ClaudeCodeCLIProtocol.findExecutable(fileManager: fileManager) else { return nil }
        self.executableURL = executableURL
        // A neutral directory keeps project instruction files out of screen answers.
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        workingDirectory = support.appendingPathComponent("OpenClicky/ClaudeCode", isDirectory: true)
        try? fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    static func findExecutable(fileManager: FileManager = .default) -> URL? {
        ClaudeCodeCLIProtocol.findExecutable(fileManager: fileManager)
    }

    /// Starts the next turn's process without sending a request or using any quota.
    func warmUp(systemPrompt _: String) {
        let key = configurationKey
        if let spare, spare.isRunning, spare.configurationKey == key { return }
        spare?.terminate()
        spare = try? makeProcess(key: key)
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        // The CLI has no assistant prefill; callers with a strict output contract pass nil.
        assistantPrefill _: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startedAt = Date()
        let message = try ClaudeCodeCLIProtocol.userMessageLine(
            textBlocks: ClaudeCodeCLIProtocol.standaloneTextBlocks(
                systemPrompt: systemPrompt, history: conversationHistory,
                imageLabels: images.map(\.label), prompt: userPrompt),
            images: images)
        let process = try takeProcess()
        let key = ObjectIdentifier(process)
        running[key] = process
        defer { running[key] = nil }
        log("claude_code_cli.request", ["model": model, "imageCount": images.count, "promptLength": userPrompt.count])
        let firstText = FirstTextFlag()
        do {
            let text = try await process.run(message: message, timeout: Self.requestTimeout) { [weak self] text in
                if firstText.pending {
                    firstText.pending = false
                    self?.log("claude_code_cli.first_text_delta",
                              ["firstTokenLatencyMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
                }
                onTextChunk(text)
            }
            let duration = Date().timeIntervalSince(startedAt)
            log("claude_code_cli.response", ["responseLength": text.count, "durationMs": Int(duration * 1000)])
            return (text, duration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("claude_code_cli.error", ["error": error.localizedDescription], direction: "error")
            throw error
        }
    }

    func stop() {
        spare?.terminate()
        spare = nil
        for process in running.values { process.terminate() }
        running.removeAll()
    }

    private var configurationKey: String {
        [model, String(maxOutputTokens), AppBundleConfiguration.anthropicBaseURL()].joined(separator: "|")
    }

    /// Returns the warm spare when it matches the current configuration, otherwise a new process.
    private func takeProcess() throws -> ClaudeCodeCLITurnProcess {
        let key = configurationKey
        let warm = spare.flatMap { $0.isRunning && $0.configurationKey == key ? $0 : nil }
        if warm == nil { spare?.terminate() }
        spare = nil
        let process = try warm ?? makeProcess(key: key)
        spare = try? makeProcess(key: key)
        return process
    }

    private func makeProcess(key: String) throws -> ClaudeCodeCLITurnProcess {
        let customBaseURL = AppBundleConfiguration.anthropicBaseURL()
        let usesCustomProvider = customBaseURL != AppBundleConfiguration.defaultAnthropicBaseURL
        return try ClaudeCodeCLITurnProcess(
            executable: executableURL,
            arguments: ClaudeCodeCLIProtocol.standaloneArguments(model: model, systemPrompt: Self.persistentSystemPrompt),
            workingDirectory: workingDirectory,
            environment: ClaudeCodeCLIProtocol.environment(
                base: ProcessInfo.processInfo.environment, executable: executableURL,
                maxOutputTokens: maxOutputTokens,
                customBaseURL: usesCustomProvider ? customBaseURL : nil,
                customAPIKey: usesCustomProvider ? AppBundleConfiguration.anthropicAPIKey() : nil),
            configurationKey: key)
    }

    private func log(_ event: String, _ fields: [String: Any], direction: String = "incoming") {
        var fields = fields
        fields["executor"] = "voice_response"
        fields["executionMethod"] = "ClaudeCodeCLIClient"
        fields["transport"] = "claude_cli_stream_json"
        fields["claudeExecutable"] = executableURL.path
        OpenClickyMessageLogStore.shared.append(lane: "voice", direction: direction, event: event, fields: fields)
    }
}
