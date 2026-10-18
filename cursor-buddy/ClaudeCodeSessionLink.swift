import Darwin
import Foundation

nonisolated struct SharedClaudeSession {
    let id: String
    let title: String
    let cwd: String
    let modifiedAt: Date
    /// Status reported by a live interactive Claude Code process that has this session open.
    let liveStatus: String?
}

/// Links a cursor task to an existing Claude Code session. Each cursor question continues that
/// session with `claude -p --resume`, so the exchange is saved in the session's own history and
/// appears when the user resumes it in Claude Code.
@MainActor
final class ClaudeCodeSessionLink {
    var onStatus: ((String) -> Void)?
    private var submitting = false
    /// Turns the user stopped watching; they finish in the session and are released afterwards.
    private var detached: [ClaudeCodeCLITurnProcess] = []
    private static let turnTimeout: Duration = .seconds(600)

    func listSessions(limit: Int = 30) async -> [SharedClaudeSession] {
        await Task.detached(priority: .userInitiated) { Self.readSessions(limit: limit) }.value
    }

    func transcript(for sessionID: String) async throws -> [CodexTranscriptEntry] {
        let messages = try await Task.detached(priority: .userInitiated) { () throws -> [ClaudeCodeCLIProtocol.SessionMessage] in
            let file = try Self.sessionFile(for: sessionID)
            return Self.parse(file: file, id: sessionID).messages
        }.value
        return messages.suffix(200).map {
            CodexTranscriptEntry(id: $0.id, role: $0.isUser ? .user : .assistant, text: $0.text, createdAt: $0.createdAt)
        }
    }

    func submit(sessionID: String, prompt: String, images: [(data: Data, label: String)],
                onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard !submitting else { throw ClaudeCodeCLIProtocol.error("A cursor request is already pending for this session.") }
        guard let executable = ClaudeCodeCLIProtocol.findExecutable() else {
            throw ClaudeCodeCLIProtocol.error("Claude Code is not installed. Install it, sign in with `claude`, then reconnect.")
        }
        submitting = true
        defer { submitting = false }
        detached.removeAll { !$0.isRunning }

        let (summary, liveStatus) = try await Task.detached(priority: .userInitiated) { () throws -> (ClaudeCodeCLIProtocol.SessionSummary?, String?) in
            let file = try Self.sessionFile(for: sessionID)
            return (Self.parse(file: file, id: sessionID).summary, Self.liveOwners()[sessionID])
        }.value
        guard let summary, FileManager.default.fileExists(atPath: summary.cwd) else {
            throw ClaudeCodeCLIProtocol.error("The session's project folder is unavailable, so Claude Code cannot resume it.")
        }
        if let liveStatus, liveStatus != "idle" {
            throw ClaudeCodeCLIProtocol.error("This Claude Code session is busy in another window. Ask again when its turn finishes.")
        }

        let message = try ClaudeCodeCLIProtocol.userMessageLine(
            textBlocks: [ClaudeCodeCLIProtocol.linkedUserText(prompt, screenLabels: images.map(\.label))], images: images)
        let process = try ClaudeCodeCLITurnProcess(
            executable: executable,
            arguments: ClaudeCodeCLIProtocol.resumeArguments(sessionID: sessionID,
                                                             appendedSystemPrompt: CursorResponseContract.instructions),
            workingDirectory: URL(fileURLWithPath: summary.cwd, isDirectory: true),
            environment: ClaudeCodeCLIProtocol.environment(
                base: ProcessInfo.processInfo.environment, executable: executable,
                maxOutputTokens: nil, customBaseURL: nil, customAPIKey: nil))
        onStatus?("Running in Claude Code")
        do {
            let text = try await process.run(message: message, timeout: Self.turnTimeout, keepsRunningOnCancel: true,
                                             onText: onTextChunk)
            onStatus?("Connected")
            return text
        } catch is CancellationError {
            if process.isRunning { detached.append(process) }
            onStatus?("Connected")
            throw CancellationError()
        } catch {
            onStatus?("Connected")
            throw error
        }
    }

    // MARK: Files

    nonisolated private static var configDirectory: URL {
        ClaudeCodeCLIProtocol.configDirectory(home: FileManager.default.homeDirectoryForCurrentUser.path,
                                              environment: ProcessInfo.processInfo.environment)
    }

    nonisolated private static func sessionFiles() -> [(url: URL, modifiedAt: Date)] {
        let projects = configDirectory.appendingPathComponent("projects", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap { folder -> [(url: URL, modifiedAt: Date)] in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return files.filter { $0.pathExtension == "jsonl" && ClaudeCodeCLIProtocol.isValidSessionID($0.deletingPathExtension().lastPathComponent) }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        }
    }

    nonisolated private static func sessionFile(for sessionID: String) throws -> (url: URL, modifiedAt: Date) {
        guard let file = sessionFiles().filter({ $0.url.deletingPathExtension().lastPathComponent == sessionID })
            .max(by: { $0.modifiedAt < $1.modifiedAt }) else {
            throw ClaudeCodeCLIProtocol.error("Claude Code session \(sessionID.prefix(8)) was not found.")
        }
        return file
    }

    nonisolated private static func parse(file: (url: URL, modifiedAt: Date), id: String)
        -> (summary: ClaudeCodeCLIProtocol.SessionSummary?, messages: [ClaudeCodeCLIProtocol.SessionMessage]) {
        let text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        return ClaudeCodeCLIProtocol.parseSession(lines: text.split(separator: "\n"), id: id, modifiedAt: file.modifiedAt)
    }

    nonisolated private static func liveOwners() -> [String: String] {
        let registry = configDirectory.appendingPathComponent("sessions", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? []
        let records = files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        return ClaudeCodeCLIProtocol.liveOwners(registryRecords: records) { kill($0, 0) == 0 }
    }

    nonisolated private static func readSessions(limit: Int) -> [SharedClaudeSession] {
        let owners = liveOwners()
        return sessionFiles().sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).compactMap { file in
            let id = file.url.deletingPathExtension().lastPathComponent
            guard let summary = parse(file: file, id: id).summary else { return nil }
            return SharedClaudeSession(id: id, title: summary.title, cwd: summary.cwd,
                                       modifiedAt: summary.modifiedAt, liveStatus: owners[id])
        }
    }
}
