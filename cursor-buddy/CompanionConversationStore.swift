import Foundation

nonisolated struct CompanionConversationStore: Codable {
    struct Conversation: Codable, Identifiable {
        var id: UUID
        var entries: [CodexTranscriptEntry]
        var summary: String?
        var archived = false
        var boundThreadID: String?
        var boundThreadTitle: String?
        var title: String { boundThreadTitle ?? entries.first(where: { $0.role == .user }).map { String($0.text.prefix(42)) } ?? "New task" }
    }
    static let defaultsKey = "openclicky.companionConversations"
    var conversations: [Conversation]
    var activeID: UUID
    var active: Conversation { conversations.first(where: { $0.id == activeID })! }
    init(legacyEntries: [CodexTranscriptEntry] = [], summary: String? = nil) {
        let id = UUID(uuidString: "039BB5B3-6D99-481C-80E4-FC4B5AF86A43")!
        conversations = [Conversation(id: id, entries: legacyEntries, summary: summary)]
        activeID = id
    }
    static func load(from defaults: UserDefaults = .standard, legacyEntries: [CodexTranscriptEntry] = [], summary: String? = nil) -> Self {
        if let data = defaults.data(forKey: defaultsKey), var value = try? JSONDecoder().decode(Self.self, from: data),
           value.conversations.contains(where: { $0.id == value.activeID && !$0.archived }) { value.collapseDuplicateLinks(); return value }
        return Self(legacyEntries: legacyEntries, summary: summary)
    }
    mutating func update(entries: [CodexTranscriptEntry], summary: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == activeID }) else { return }
        conversations[index].entries = entries
        conversations[index].summary = summary
    }
    mutating func startNew() {
        let task = Conversation(id: UUID(), entries: [], summary: nil)
        conversations.append(task)
        activeID = task.id
    }
    /// A live backend thread has one local identity, regardless of invocation or reconnect.
    mutating func bind(threadID: String, title: String, entries: [CodexTranscriptEntry]) {
        let existing = conversations.first(where: { $0.id == activeID && !$0.archived && $0.boundThreadID == threadID })
            ?? conversations.first(where: { !$0.archived && $0.boundThreadID == threadID })
        if let existing { activeID = existing.id } else { startNew() }
        guard let index = conversations.firstIndex(where: { $0.id == activeID }) else { return }
        conversations[index].boundThreadID = threadID
        conversations[index].boundThreadTitle = title
        conversations[index].entries = entries
        conversations[index].summary = nil
        collapseDuplicateLinks()
    }

    mutating func collapseDuplicateLinks() {
        var canonical: [String: UUID] = [:]
        if let selected = conversations.first(where: { $0.id == activeID && !$0.archived }), let thread = selected.boundThreadID {
            canonical[thread] = selected.id
        }
        for index in conversations.indices where !conversations[index].archived {
            guard let thread = conversations[index].boundThreadID else { continue }
            if let keeper = canonical[thread], keeper != conversations[index].id {
                // Archive duplicate links, retaining their cached history for recovery.
                conversations[index].archived = true
            } else { canonical[thread] = conversations[index].id }
        }
    }

    @discardableResult mutating func select(_ id: UUID) -> Bool {
        guard conversations.contains(where: { $0.id == id && !$0.archived }) else { return false }
        activeID = id
        return true
    }
    /// Archives chats untouched for `idle` (7 days by default), except the active one. History is kept.
    mutating func archiveIdle(for idle: TimeInterval = 7 * 24 * 3600, now: Date = Date()) {
        for index in conversations.indices where !conversations[index].archived && conversations[index].id != activeID {
            let lastActivity = conversations[index].entries.last?.createdAt ?? .distantPast
            if now.timeIntervalSince(lastActivity) > idle { conversations[index].archived = true }
        }
    }
    /// Archives every chat except the active one. History is kept.
    mutating func archiveAllButActive() {
        for index in conversations.indices where conversations[index].id != activeID { conversations[index].archived = true }
    }
    mutating func removeActive() {
        if let index = conversations.firstIndex(where: { $0.id == activeID }) { conversations[index].archived = true }
        if let next = conversations.last(where: { !$0.archived }) { activeID = next.id } else { startNew() }
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
