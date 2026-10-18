import Foundation

/// A session in another tool that a cursor task can be linked to.
struct LinkableSession {
    /// Stored as the task's `boundThreadID`; unique across sources.
    let threadID: String
    let title: String
    /// Extra picker text such as folder, last activity, or state.
    let detail: String
    let canConnect: Bool
}

/// A tool whose existing sessions the cursor can continue (Connect).
/// Add a source by conforming to this protocol and listing it in `CompanionManager.sessionLinks`.
@MainActor
protocol SessionLink: AnyObject {
    /// Shown before session titles, for example "Codex".
    var sourceName: String { get }
    var isAvailable: Bool { get }
    func owns(threadID: String) -> Bool
    func listSessions() async -> [LinkableSession]
    /// Prepares a live connection before binding; defaults to nothing.
    func connect(threadID: String) async throws
    func transcript(threadID: String) async throws -> [CodexTranscriptEntry]
    func submit(threadID: String, prompt: String, images: [(data: Data, label: String)],
                onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String
}

extension SessionLink {
    func connect(threadID: String) async throws {}
}

/// Live terminal threads on the shared Codex app-server.
@MainActor
final class CodexSessionLinkSource: SessionLink {
    let sourceName = "Codex"
    private let client: () -> CodexSharedSessionClient
    init(client: @escaping () -> CodexSharedSessionClient) { self.client = client }

    var isAvailable: Bool { true }
    /// Codex thread IDs carry no prefix; every other source uses one.
    func owns(threadID: String) -> Bool { !threadID.contains(":") }

    func listSessions() async -> [LinkableSession] {
        let threads = (try? await client().listThreads()) ?? []
        return threads.map { LinkableSession(threadID: $0.id, title: $0.title,
                                             detail: $0.canConnect ? "" : "unavailable", canConnect: $0.canConnect) }
    }

    func connect(threadID: String) async throws {
        if client().connectedThreadID != threadID { try await client().connect(to: threadID) }
    }

    func transcript(threadID: String) async throws -> [CodexTranscriptEntry] {
        try await connect(threadID: threadID)
        return try await client().transcript(for: threadID)
    }

    func submit(threadID: String, prompt: String, images: [(data: Data, label: String)],
                onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        try await client().submit(threadID: threadID, prompt: prompt, images: images, onTextChunk: onText)
    }
}

/// Saved Claude Code sessions, continued in place with `claude -p --resume`.
@MainActor
final class ClaudeCodeSessionLinkSource: SessionLink {
    let sourceName = "Claude Code"
    private let link: ClaudeCodeSessionLink
    init(link: ClaudeCodeSessionLink) { self.link = link }

    var isAvailable: Bool { ClaudeCodeCLIProtocol.findExecutable() != nil }
    func owns(threadID: String) -> Bool { ClaudeCodeCLIProtocol.sessionID(fromLinkedThreadID: threadID) != nil }

    func listSessions() async -> [LinkableSession] {
        let relative = RelativeDateTimeFormatter()
        return await link.listSessions().map { session in
            let folder = URL(fileURLWithPath: session.cwd).lastPathComponent
            let age = relative.localizedString(for: session.modifiedAt, relativeTo: Date())
            let state = session.liveStatus.map { " · open (\($0))" } ?? ""
            return LinkableSession(threadID: ClaudeCodeCLIProtocol.linkedThreadID(sessionID: session.id),
                                   title: session.title, detail: "\(folder) · \(age)\(state)", canConnect: true)
        }
    }

    func transcript(threadID: String) async throws -> [CodexTranscriptEntry] {
        try await link.transcript(for: sessionID(threadID))
    }

    func submit(threadID: String, prompt: String, images: [(data: Data, label: String)],
                onText: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        try await link.submit(sessionID: sessionID(threadID), prompt: prompt, images: images, onTextChunk: onText)
    }

    private func sessionID(_ threadID: String) throws -> String {
        guard let id = ClaudeCodeCLIProtocol.sessionID(fromLinkedThreadID: threadID) else {
            throw ClaudeCodeCLIProtocol.error("This task is not linked to a Claude Code session.")
        }
        return id
    }
}
