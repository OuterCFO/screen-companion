@preconcurrency import AVFoundation
import OCComputerUseCore
import AppKit
import Combine
import CoreAudio
import Foundation
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import OCCore
import OCUI
import OCMarkdown
import OCMemory

extension CompanionManager {
    func bindAgentSessionObservation() {
        codexAgentSessions.forEach { observeCodexAgentSession($0) }
    }

    func observeCodexAgentSession(_ session: CodexAgentSession) {
        guard agentStatusCancellables[session.id] == nil else { return }

        session.onOpenableFileFound = { [weak self, weak session] fileURL in
            guard let self, let session else { return }
            self.handleAgentFoundOpenableFile(fileURL, session: session)
        }

        agentStatusCancellables[session.id] = session.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] status in
                guard let self else { return }
                if status != .stopped {
                    self.cancelPendingAgentDockItemRemoval(for: sessionID)
                }
                self.updateAgentDockItem(for: sessionID, status: status)
                self.scheduleStatusSync()
                self.scheduleRelaunchableAgentSessionsPersist()
                self.updateAgentProgressNarration()
            }

        agentActivityCancellables[session.id] = session.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] _ in
                self?.scheduleAgentActivityRefresh(for: sessionID)
                self?.scheduleRelaunchableAgentSessionsPersist()
            }

        agentLoopActivityCancellables[session.id] = session.$activityStatusLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] _ in
                self?.scheduleAgentActivityRefresh(for: sessionID)
            }

        agentProgressStageCancellables[session.id] = session.$progressStage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRelaunchableAgentSessionsPersist()
            }

        agentTitleCancellables[session.id] = session.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] title in
                self?.updateAgentDockTitle(for: sessionID, title: title)
                self?.scheduleRelaunchableAgentSessionsPersist()
            }
    }

    func persistRelaunchableAgentSessions() {
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = nil
        ChatWorkspaceArchiveStore.saveRelaunchableSnapshots(
            for: codexAgentSessions,
            archivedSessionIDs: archivedSessionIDs
        )
    }

    func scheduleRelaunchableAgentSessionsPersist() {
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.persistRelaunchableAgentSessions()
            }
        }
    }

    func startRelaunchableAgentAutoResumeChecks() {
        relaunchableAgentResumeTimer?.invalidate()
        scheduleRelaunchableAgentAutoResumeCheck(trigger: "startup")

        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRelaunchableAgentAutoResumeCheck(trigger: "periodic")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        relaunchableAgentResumeTimer = timer
    }

    func scheduleRelaunchableAgentAutoResumeCheck(trigger: String) {
        pendingRelaunchableAgentResumeTask?.cancel()
        pendingRelaunchableAgentResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(trigger == "startup" ? 1500 : 250))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.resumeRestoredAgentTasksIfNeeded(trigger: trigger)
            }
        }
    }

    func resumeRestoredAgentTasksIfNeeded(trigger: String) {
        pendingRelaunchableAgentResumeTask = nil
        let sessionsToResume = codexAgentSessions.filter { session in
            session.canResumeAfterRelaunch
                && !archivedSessionIDs.contains(session.id)
                && !autoResumedRelaunchSessionIDs.contains(session.id)
        }
        guard !sessionsToResume.isEmpty else { return }

        let ids = sessionsToResume.map(\.id)
        autoResumedRelaunchSessionIDs.formUnion(ids)
        activeCodexAgentSessionID = ids.first ?? activeCodexAgentSessionID
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.auto_resume",
            fields: [
                "trigger": trigger,
                "count": sessionsToResume.count,
                "sessionIDs": ids.map(\.uuidString),
                "titles": sessionsToResume.map(\.title)
            ]
        )

        sessionsToResume.forEach { session in
            updateAgentDockItem(for: session.id, status: session.status)
            session.resumeInterruptedTaskAfterRelaunch()
        }
        scheduleStatusSync()
        scheduleRelaunchableAgentSessionsPersist()
    }

    func updateAgentDockTitle(for sessionID: UUID, title: String) {
        guard let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == sessionID }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, agentDockItems[itemIndex].title != trimmedTitle else { return }
        agentDockItems[itemIndex].title = trimmedTitle
        scheduleStatusSync()
    }

    func scheduleAgentActivityRefresh(for sessionID: UUID) {
        guard pendingAgentActivityRefreshTasks[sessionID] == nil else { return }

        // Short debounce so streaming assistant deltas feel real-time in the
        // dock caption. The old 450ms interval batched too aggressively and
        // produced visibly "stalled" updates while tokens were arriving.
        pendingAgentActivityRefreshTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                guard let self else { return }
                self.pendingAgentActivityRefreshTasks[sessionID] = nil
                guard let session = self.codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
                self.updateAgentDockItem(for: sessionID, status: session.status)
                self.scheduleStatusSync()
                self.updateAgentProgressNarration()
            }
        }
    }

    @discardableResult
    func createAndSelectNewCodexAgentSession(title: String? = nil, accentTheme: ClickyAccentTheme? = nil) -> CodexAgentSession {
        let resolvedAccentTheme = accentTheme ?? Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
        // Inject the Claude Code CLI client so title generation
        // follows the money rule (SDK first, direct REST fallback). See
        // CodexAgentSession.fastFriendlyTitle.
        let session = CodexAgentSession(
            title: title ?? "Ask Agent",
            accentTheme: resolvedAccentTheme,
            claudeCodeCLI: claudeCodeCLI
        )
        codexAgentSessions.append(session)
        observeCodexAgentSession(session)
        activeCodexAgentSessionID = session.id
        lastAgentContextSessionID = session.id
        scheduleStatusSync()
        scheduleRelaunchableAgentSessionsPersist()
        return session
    }

    func resolvedNewAgentTaskPrompt(from prompt: String) -> String {
        let explicitInstruction = Self.agentTaskCreationInstruction(from: prompt)
            ?? Self.permissiveAgentInstruction(from: prompt)
            ?? Self.clickyAgentInstruction(from: prompt)
        guard let explicitInstruction else { return prompt }

        var instruction = SpokenText.normalizedAgentTaskInstruction(from: explicitInstruction)
        if Self.isReferentialAgentInstruction(instruction),
           let resolvedInstruction = referentialAgentInstructionContext(excluding: prompt) {
            instruction = resolvedInstruction
        }

        instruction = SpokenText.cleanedAgentTaskInstruction(instruction)
        guard !instruction.isEmpty,
              !Self.isAgentTaskPlaceholderInstruction(instruction) else {
            return prompt
        }
        return instruction
    }

    /// Creates a brand-new agent session, stages it into the same dock/menu
    /// surfaces as a normal agent task, then submits the initial prompt.
    @discardableResult
    func createAndLaunchCodexAgentSession(
        title: String? = nil,
        prompt: String,
        accentTheme: ClickyAccentTheme? = nil,
        includeScreenContext: Bool = true,
        restrictedExecutionPolicy: Bool = false
    ) -> CodexAgentSession {
        let session = createAndSelectNewCodexAgentSession(title: title, accentTheme: accentTheme)
        if restrictedExecutionPolicy {
            session.configureRestrictedExecutionPolicy()
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return session }
        stageDashboardAgentSubmission(prompt: trimmedPrompt, session: session)
        submitAgentPrompt(trimmedPrompt, to: session, includeScreenContext: includeScreenContext)
        return session
    }

    func handleAgentFoundOpenableFile(_ fileURL: URL, session: CodexAgentSession) {
        let standardizedURL = fileURL.standardizedFileURL
        let eventKey = "\(session.id.uuidString)|\(standardizedURL.path)"
        guard !announcedAgentFileURLs.contains(eventKey) else { return }

        announcedAgentFileURLs.insert(eventKey)
        openOpenClickyDocument(standardizedURL)
        showShortSystemResponse("\(session.spokenAgentSentenceName) says it found \(Self.spokenFileName(for: standardizedURL)), showing it now.")
    }

    static func isMarkdownDocument(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    static func spokenFileName(for fileURL: URL) -> String {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let cleanedName = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleanedName.isEmpty ? "the file" : cleanedName
    }

    func selectCodexAgentSession(_ sessionID: UUID) {
        guard codexAgentSessions.contains(where: { $0.id == sessionID }) else { return }
        activeCodexAgentSessionID = sessionID
        lastAgentContextSessionID = sessionID
    }

    /// Mark a session as archived. Keeps the session alive so its transcript and state
    /// are preserved; the sidebar groups archived sessions under a separate header.
    func archiveSession(_ sessionID: UUID, allowIncomplete: Bool = false) {
        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
        let isActivelyRunning: Bool = {
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }()
        guard !isActivelyRunning, !session.isTurnActiveForChatQueue else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.archive_blocked_running",
                fields: [
                    "sessionID": sessionID.uuidString,
                    "title": session.title
                ]
            )
            return
        }
        guard allowIncomplete || session.isFinishedForArchive else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.archive_blocked_incomplete",
                fields: [
                    "sessionID": sessionID.uuidString,
                    "title": session.title,
                    "progressStage": session.progressStage.label
                ]
            )
            return
        }
        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.insert(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.saveSnapshot(for: session)
        ChatWorkspaceArchiveStore.removeRelaunchableSnapshot(for: sessionID)
        cancelPendingAgentDockItemRemoval(for: sessionID)
        silenceAgentSpeech(for: sessionID, reason: "agent_session_archived")
        agentDockItems.removeAll { $0.sessionID == sessionID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        refreshAgentDockFollowBehavior()
        if activeCodexAgentSessionID == sessionID {
            if let next = codexAgentSessions.first(where: { !archivedSessionIDs.contains($0.id) }) {
                selectCodexAgentSession(next.id)
            } else {
                _ = createAndSelectNewCodexAgentSession()
            }
        }
        scheduleStatusSync()
    }

    /// Restore a previously archived session.
    func unarchiveSession(_ sessionID: UUID) {
        guard archivedSessionIDs.contains(sessionID) else { return }
        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.remove(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.removeSnapshot(for: sessionID)
        persistRelaunchableAgentSessions()
        scheduleStatusSync()
    }

    /// Pop the currently active session into a floating mini-chat NSPanel scoped to that session.
    /// The mini-chat dies with the parent HUD via `MiniChatPanelManager.shared.destroyAll()`.
    func popoutCurrentSession() {
        let session = codexAgentSession
        MiniChatPanelManager.shared.show(session: session, companion: self)
    }

    /// Launch a new chat session pre-configured as a specialist OpenClicky
    /// agent. The agent's soul/instructions/memory are layered into the
    /// session's system prompt via `prependedSystemContext`.
    @discardableResult
    func createAndSelectNewCodexAgentSession(asAgent agent: OpenClickyAgentDefinition) -> CodexAgentSession {
        let session = createAndSelectNewCodexAgentSession(title: agent.metadata.displayName)
        session.prependedSystemContext = agent.renderedSystemContext()
        session.specialistAgentSlug = agent.slug
        return session
    }

    func closeCodexAgentSession(_ sessionID: UUID) {
        guard let closingIndex = codexAgentSessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let closingSession = codexAgentSessions[closingIndex]
        closingSession.stop(reason: "chat_session_closed")
        closingSession.onOpenableFileFound = nil

        cancelPendingAgentDockItemRemoval(for: sessionID)
        pendingAgentActivityRefreshTasks[sessionID]?.cancel()
        pendingAgentActivityRefreshTasks.removeValue(forKey: sessionID)
        pendingAgentDockItemRemovalTasks.removeValue(forKey: sessionID)
        agentStatusCancellables.removeValue(forKey: sessionID)
        agentActivityCancellables.removeValue(forKey: sessionID)
        agentLoopActivityCancellables.removeValue(forKey: sessionID)
        agentProgressStageCancellables.removeValue(forKey: sessionID)
        agentTitleCancellables.removeValue(forKey: sessionID)
        agentRequestTimingsBySessionID.removeValue(forKey: sessionID)
        agentExecutionStartDatesBySessionID.removeValue(forKey: sessionID)
        lastNarratedAgentOutcomeBySessionID.removeValue(forKey: sessionID)

        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.remove(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.removeSnapshot(for: sessionID)
        ChatWorkspaceArchiveStore.removeRelaunchableSnapshot(for: sessionID)

        codexAgentSessions.remove(at: closingIndex)
        agentDockItems.removeAll { $0.sessionID == sessionID }

        if pendingAgentVoiceFollowUpSessionID == sessionID {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
        }
        if lastAgentContextSessionID == sessionID {
            lastAgentContextSessionID = nil
        }

        if codexAgentSessions.isEmpty {
            _ = createAndSelectNewCodexAgentSession()
        } else if activeCodexAgentSessionID == sessionID {
            let fallbackIndex = min(closingIndex, codexAgentSessions.count - 1)
            selectCodexAgentSession(codexAgentSessions[fallbackIndex].id)
        }

        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_session.closed",
            fields: [
                "sessionID": sessionID.uuidString,
                "title": closingSession.title
            ]
        )
        scheduleStatusSync()
        persistRelaunchableAgentSessions()
    }
}
