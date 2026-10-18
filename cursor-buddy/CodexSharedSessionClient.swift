import Foundation
import AppKit

nonisolated struct SharedCodexThread: Identifiable {
    let id: String
    let title: String
    let status: String
    var canConnect: Bool { SharedCodexSessionContract.isLive(status) }
}

@MainActor
final class CodexSharedSessionClient {
    private let rpc = CodexProcessManager()
    private var initialized = false
    private(set) var connectedThreadID: String?
    private var turnID: String?
    private var text = ""
    private var finalText: String?
    private var handledRequests = Set<String>()
    private var continuation: CheckedContinuation<String, Error>?
    private var earlyEvents: [[String: Any]] = []
    private var awaitingStart = false
    private var submitting = false
    private var imagesDirectory: URL?
    private var onText: (@MainActor @Sendable (String) -> Void)?
    var onStatus: ((String) -> Void)?

    init() {
        rpc.onNotification = { [weak self] message in Task { @MainActor in self?.handle(message) } }
        rpc.onTermination = { [weak self] in Task { @MainActor in
            guard let self else { return }
            self.initialized = false
            self.continuation?.resume(throwing: CodexRPCError(message: "The shared Codex connection closed. Check the original session before retrying."))
            self.continuation = nil
            self.onStatus?("Disconnected")
        } }
    }

    private func initialize() async throws {
        if initialized && rpc.isRunning { return }
        initialized = false
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
        guard FileManager.default.fileExists(atPath: socket.path) else {
            throw CodexRPCError(message: "The shared Codex server is unavailable. Open a compatible Codex terminal session first.")
        }
        let script = Bundle.main.url(forResource: "shared-session-bridge", withExtension: "py")
        try rpc.start(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), codexHome: home,
                      sharedSocket: socket, bridgeScript: script)
        do {
            _ = try await rpc.sendRequest(request: CodexProcessManager.makeInitializeRequest(clientName: "open-clicky-shared"), timeout: 10)
            try rpc.sendNotification(method: "initialized")
            initialized = true
        } catch { rpc.stop(); throw error }
    }

    func listThreads() async throws -> [SharedCodexThread] {
        try await initialize()
        let result = try await rpc.sendRequest(method: "thread/list", params: ["limit": 40], timeout: 10)
        let loaded = try await rpc.sendRequest(method: "thread/loaded/list", params: [:], timeout: 10)
        let ids = Set(loaded["data"] as? [String] ?? [])
        var records = result["data"] as? [[String: Any]] ?? []
        // Read loaded threads directly; thread/list can report stale summaries.
        for id in ids {
            let response = try await rpc.sendRequest(method: "thread/read", params: ["threadId": id], timeout: 10)
            if let current = response["thread"] as? [String: Any] {
                records.removeAll { $0["id"] as? String == id }
                records.insert(current, at: 0)
            }
        }
        return records.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let state = (item["status"] as? [String: Any])?["type"] as? String ?? "notLoaded"
            let preview = String((item["preview"] as? String ?? "").prefix(60))
            let folder = URL(fileURLWithPath: item["cwd"] as? String ?? "/").lastPathComponent
            let title = item["name"] as? String ?? (preview.isEmpty ? folder + " · " + String(id.suffix(8)) : preview)
            return SharedCodexThread(id: id, title: title, status: ids.contains(id) ? state : "notLoaded")
        }
    }

    func connect(to id: String) async throws {
        try await initialize()
        let loaded = try await rpc.sendRequest(method: "thread/loaded/list", params: [:], timeout: 10)
        guard (loaded["data"] as? [String] ?? []).contains(id) else {
            throw CodexRPCError(message: "This chat is not live in the shared server. Its desktop host uses a separate server; attaching its saved copy would create another worker, so OpenClicky did not attach.")
        }
        // Rejoin the live thread. Do not override its tools, instructions, model, or permissions.
        _ = try await rpc.sendRequest(method: "thread/resume", params: ["threadId": id], timeout: 15)
        connectedThreadID = id
        onStatus?("Connected")
    }

    func transcript(for id: String) async throws -> [CodexTranscriptEntry] {
        try await initialize()
        let result = try await rpc.sendRequest(method: "thread/read", params: ["threadId": id, "includeTurns": true], timeout: 15)
        let thread = result["thread"] as? [String: Any] ?? [:]
        return (thread["turns"] as? [[String: Any]] ?? []).flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap { item in
                let type = item["type"] as? String
                let content: String
                if type == "userMessage" {
                    content = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else if type == "agentMessage" { content = item["text"] as? String ?? "" }
                else { return nil }
                guard !content.isEmpty else { return nil }
                return CodexTranscriptEntry(id: item["id"] as? String ?? UUID().uuidString,
                                            role: type == "userMessage" ? .user : .assistant, text: content)
            }
        }
    }

    func submit(threadID: String, prompt: String, images: [(data: Data, label: String)],
                onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard !submitting else { throw CodexRPCError(message: "A cursor request is already pending for this session.") }
        submitting = true
        defer { submitting = false }
        return try await withTaskCancellationHandler {
            if connectedThreadID != threadID { try await connect(to: threadID) }
            while true {
                try Task.checkCancellation()
                let result = try await rpc.sendRequest(method: "thread/read", params: ["threadId": threadID], timeout: 10)
                let thread = result["thread"] as? [String: Any] ?? [:]
                let status = (thread["status"] as? [String: Any])?["type"] as? String
                guard status == "idle" || status == "active" else {
                    throw CodexRPCError(message: "The shared session is no longer live. Reconnect before submitting.")
                }
                if status == "idle" { break }
                onStatus?("Waiting for the current Codex turn")
                try await Task.sleep(for: .seconds(1))
            }
            try Task.checkCancellation()
            if SharedCodexSessionContract.needsInstructions(threadID: threadID, defaults: .standard) {
                // Add the presentation contract once, without replacing the original client's instructions
                // or launching an inference turn. Older servers fail explicitly before submitting input.
                _ = try await rpc.sendRequest(method: "thread/inject_items",
                    params: SharedCodexSessionContract.instructionParameters(threadID: threadID), timeout: 15)
                SharedCodexSessionContract.acknowledgeInstructions(threadID: threadID, defaults: .standard)
            }
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-shared-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            imagesDirectory = directory
            var input: [[String: Any]] = [["type": "text", "text": SharedCodexSessionContract.userText(prompt, screenLabels: images.map(\.label))]]
            for (index, image) in images.enumerated() {
                let path = directory.appendingPathComponent("screen-\(index)." + (image.data.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? "png" : "jpg"))
                try image.data.write(to: path, options: .atomic)
                input.append(["type": "localImage", "path": path.path])
            }
            text = ""; finalText = nil; onText = onTextChunk; earlyEvents = []; awaitingStart = true
            let result: [String: Any]
            do {
                // No model, cwd, sandbox, instruction, or approval-policy overrides.
                result = try await rpc.sendRequest(method: "turn/start", params: SharedCodexSessionContract.turnParameters(threadID: threadID, input: input), timeout: 30)
            } catch {
                awaitingStart = false
                // A timed-out submission may have been accepted. Never retry it automatically.
                onStatus?("Submission uncertain. Check Codex before retrying.")
                throw error
            }
            guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else {
                throw CodexRPCError(message: "Codex did not acknowledge a turn. Check its history before retrying.")
            }
            turnID = id; awaitingStart = false; onStatus?("Running in Codex")
            return try await withCheckedThrowingContinuation { pending in
                continuation = pending
                let events = earlyEvents; earlyEvents = []
                for event in events { handle(event) }
                if Task.isCancelled { cancelDisplayWait() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDisplayWait() }
        }
    }

    // Dismissal and disconnect never interrupt the original Codex task.
    func cancelDisplayWait() {
        continuation?.resume(throwing: CancellationError()); continuation = nil
        onText = nil
    }
    func disconnect() {
        cancelDisplayWait()
        connectedThreadID = nil
        initialized = false
        rpc.stop()
    }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any],
              params["threadId"] as? String == connectedThreadID else { return }
        if let id = message["id"] {
            let requestedTurn = params["turnId"] as? String
            guard awaitingStart || (turnID != nil && requestedTurn == turnID) else { return }
            handleRequest(id: id, method: method, params: params)
            return
        }
        if awaitingStart { earlyEvents.append(message); return }
        let eventTurn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        guard eventTurn == turnID else { return }
        if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
            text += delta; onText?(text)
        } else if method == "item/completed", let item = params["item"] as? [String: Any],
                  item["type"] as? String == "agentMessage", let final = item["text"] as? String {
            if item["phase"] as? String == "final_answer" || item["phase"] as? String == "final" { finalText = final }
            if text.isEmpty { text = final; onText?(final) }
        } else if method == "turn/completed" {
            let turn = params["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "completed" { continuation?.resume(returning: finalText ?? text) }
            else { continuation?.resume(throwing: CodexRPCError(message: (turn["error"] as? [String: Any])?["message"] as? String ?? "The Codex turn did not complete.")) }
            continuation = nil; turnID = nil; onText = nil
            if let directory = imagesDirectory { try? FileManager.default.removeItem(at: directory) }
            imagesDirectory = nil
            onStatus?("Connected")
        }
    }

    private func handleRequest(id: Any, method: String, params: [String: Any]) {
        guard handledRequests.insert(String(describing: id)).inserted else { return }
        let alert = NSAlert()
        alert.messageText = "Codex needs your response"
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            alert.informativeText = (params["command"] as? String ?? params["reason"] as? String ?? "Allow the requested file change in the connected Codex session?")
            alert.addButton(withTitle: "Allow once"); alert.addButton(withTitle: "Deny"); alert.addButton(withTitle: "Cancel task")
            let choice = alert.runModal()
            let decision = choice == .alertFirstButtonReturn ? "accept" : choice == .alertSecondButtonReturn ? "decline" : "cancel"
            try? rpc.sendResponse(id: id, result: ["decision": decision])
        } else if method == "item/tool/requestUserInput" {
            var answers: [String: Any] = [:]
            for question in params["questions"] as? [[String: Any]] ?? [] {
                guard let questionID = question["id"] as? String else { continue }
                let dialog = NSAlert()
                dialog.messageText = question["header"] as? String ?? "Codex question"
                dialog.informativeText = question["question"] as? String ?? "Enter your response."
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
                let choices = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                if !choices.isEmpty { dialog.informativeText += "\nOptions: " + choices.joined(separator: "; ") }
                dialog.accessoryView = input; dialog.addButton(withTitle: "Submit"); dialog.addButton(withTitle: "Skip")
                let answer = dialog.runModal() == .alertFirstButtonReturn ? input.stringValue : ""
                answers[questionID] = ["answers": answer.isEmpty ? [] : [answer]]
            }
            try? rpc.sendResponse(id: id, result: ["answers": answers])
        } else if method == "item/tool/call" {
            onStatus?("A client-owned tool is unavailable in this cursor connection")
            try? rpc.sendResponse(id: id, result: ["success": false, "contentItems": [["type": "inputText", "text": "This tool belongs to another Codex client. OpenClicky cannot execute it. Use the original client; no action was performed."]]])
        } else if method == "item/permissions/requestApproval" {
            let requested = params["permissions"] as? [String: Any] ?? [:]
            alert.informativeText = "Grant these requested permissions for this turn only?\n" +
                (String(data: (try? JSONSerialization.data(withJSONObject: requested, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? "No permission details available")
            alert.addButton(withTitle: "Allow once"); alert.addButton(withTitle: "Deny")
            let granted = alert.runModal() == .alertFirstButtonReturn ? requested : [:]
            try? rpc.sendResponse(id: id, result: ["permissions": granted, "scope": "turn"])
        } else {
            onStatus?("Unsupported Codex request: " + method)
            try? rpc.sendResponse(id: id, result: ["action": "decline"])
        }
    }

}
