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
    func showQuickTextInputFromMenuBar() {
        guard hasAccessibilityPermission, hasScreenRecordingPermission else { return }
        startPrewarmedScreenshotCaptureIfPossible()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        compactInputWindowManager.showTextInput { [weak self] submittedText in
            self?.submitNewAgentTaskFromUI(submittedText, source: "menu_bar_quick_task_prompt")
        }
    }

    func showMainOpenClickyPanelFromShortcut() {
        guard allPermissionsGranted else { return }
        guard !buddyDictationManager.isKeyboardShortcutSessionActiveOrFinalizing else { return }

        startPrewarmedScreenshotCaptureIfPossible()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        compactInputWindowManager.showTextInput { [weak self] submittedText in
            self?.submitNewAgentTaskFromUI(submittedText, source: "notch_shortcut_task_prompt")
        }
    }

    func showExternalDictationInput(mode: CompactPromptMode = .screen) {
        // Remember the app the user was writing in before the compact panel takes focus.
        if mode == .write {
            let frontmost = NSWorkspace.shared.frontmostApplication
            writeTargetApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        }
        showTutorInput(startDictation: true, mode: mode)
    }

    func submitTutorPrompt(_ text: String, attachesScreen: Bool = true) {
        ensureTutorDockItem()
        submitTextModePrompt(text, allowsAgentRouting: false, attachesScreen: attachesScreen)
    }

    func saveCompactConversation() {
        companionConversations.update(entries: companionConversations.active.boundThreadID == nil ? homeChatEntries : Array(homeChatEntries.suffix(24)), summary: compactedVoiceConversationArchive)
        companionConversations.save()
    }
    func refreshCompanionTaskIcons() {
        companionConversations.collapseDuplicateLinks()
        companionConversations.save()
        let ids = Set(companionConversations.conversations.map(\.id))
        agentDockItems.removeAll { ids.contains($0.id) }
        for task in companionConversations.conversations where !task.archived {
            agentDockItems.append(ClickyAgentDockItem(
                id: task.id, sessionID: nil, title: task.title,
                userInstruction: task.title, accentTheme: .current, status: .done,
                progressStageLabel: "Ready", progressStepText: nil, activityStatusLines: [],
                caption: task.entries.last(where: { $0.role == .assistant })?.text,
                suggestedNextActions: [], createdAt: task.entries.first?.createdAt ?? Date()))
        }
        showAgentDockWindowNearCurrentScreen()
        agentMenuBarStatusManager.scheduleSync(companionManager: self)
        scheduleStatusSync()
    }
    func ensureTutorDockItem() { saveCompactConversation(); refreshCompanionTaskIcons() }
    func sessionLink(for threadID: String) throws -> SessionLink {
        guard let link = sessionLinks.first(where: { $0.owns(threadID: threadID) }) else {
            throw NSError(domain: "SessionLink", code: -1, userInfo: [NSLocalizedDescriptionKey: "This task's linked session type is not supported."])
        }
        return link
    }

    func linkedSessionTranscript(for threadID: String) async throws -> [CodexTranscriptEntry] {
        try await sessionLink(for: threadID).transcript(threadID: threadID)
    }

    func showCodexSessionConnectionPicker() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var choices: [(link: SessionLink, session: LinkableSession)] = []
            for link in self.sessionLinks where link.isAvailable {
                choices += await link.listSessions().map { (link, $0) }
            }
            let alert = NSAlert()
            alert.messageText = "Connect cursor to a session"
            alert.informativeText = """
            Codex: live sessions on the shared Codex server. Claude Code: saved sessions, continued with --resume so each question and answer joins that session's history.
            The cursor uses the session's model and history. Claude Code turns can read files but not edit them. A Claude Code window that has the session open shows new turns after you resume it again.
            """
            guard choices.contains(where: \.session.canConnect) else {
                alert.informativeText = "No compatible session is available. Open a Codex session in the current terminal client, or start a Claude Code session and send it a message. Nothing was copied or changed."
                alert.addButton(withTitle: "OK"); alert.runModal(); return
            }
            // Connectable sessions first, keeping each source's own order.
            choices = choices.filter(\.session.canConnect) + choices.filter { !$0.session.canConnect }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
            for choice in choices {
                let detail = choice.session.detail.isEmpty ? "" : " · " + choice.session.detail
                picker.addItem(withTitle: "\(choice.link.sourceName): \(choice.session.title)\(detail)")
                picker.lastItem?.isEnabled = choice.session.canConnect
            }
            alert.accessoryView = picker
            alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,
                  choices.indices.contains(picker.indexOfSelectedItem) else { return }
            let chosen = choices[picker.indexOfSelectedItem]
            do {
                try await chosen.link.connect(threadID: chosen.session.threadID)
                let entries = try await chosen.link.transcript(threadID: chosen.session.threadID)
                self.dismissCoachingOverlays()
                self.saveCompactConversation()
                self.companionConversations.bind(threadID: chosen.session.threadID,
                                                 title: chosen.link.sourceName + ": " + chosen.session.title, entries: entries)
                self.activateCompactConversation()
                self.showTutorConversation()
            } catch {
                let alert = NSAlert(); alert.messageText = "Could not connect to the session"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK"); alert.runModal()
            }
        }
    }

    func activateCompactConversation() {
        dismissCoachingOverlays()
        if sharedCodexSession.connectedThreadID != companionConversations.active.boundThreadID {
            sharedCodexSession.disconnect()
            sharedSessionStatus = "Disconnected"
        }
        codexVoiceSession.stop()
        codexVoiceSession = CodexVoiceSession(model: OpenClickyModelCatalog.codexVoiceSessionModel(withID: selectedModel).id,
                                            homeManager: codexHomeManager)
        homeChatEntries = companionConversations.active.entries
        compactedVoiceConversationArchive = companionConversations.active.summary
        conversationHistory = []
        var prompt: String?
        for entry in homeChatEntries {
            if entry.role == .user { prompt = entry.text }
            if entry.role == .assistant, let user = prompt {
                conversationHistory.append((userTranscript: user, assistantResponse: entry.text)); prompt = nil
            }
        }
        compactInputAgentSessionID = nil
        companionConversations.save()
        if let data = try? JSONEncoder().encode(homeChatEntries) { UserDefaults.standard.set(data, forKey: "openclicky.tutorChatHistory") }
        if let summary = compactedVoiceConversationArchive {
            UserDefaults.standard.set(summary, forKey: Self.compactedVoiceConversationArchiveDefaultsKey)
        } else { UserDefaults.standard.removeObject(forKey: Self.compactedVoiceConversationArchiveDefaultsKey) }
        refreshCompanionTaskIcons()
    }
    func startNewCompactTask() {
        dismissCoachingOverlays()
        saveCompactConversation()
        companionConversations.startNew()
        activateCompactConversation()
        showTutorInput(startDictation: false)
    }
    func removeCurrentCompactTask() {
        if let id = compactInputAgentSessionID {
            stopCodexAgentSession(id, reason: "compact_task_removed")
            archiveSession(id, allowIncomplete: true)
            compactInputAgentSessionID = nil
        } else {
            dismissCoachingOverlays()
            saveCompactConversation()
            companionConversations.removeActive()
            activateCompactConversation()
        }
        showTutorInput(startDictation: false)
    }
    func presentCompactTask(entries: [CodexTranscriptEntry], historyVisible: Bool = false,
                                    title: String, submit: @escaping (String) -> Void) {
        let choices = companionConversations.conversations.filter { !$0.archived }.map {
            CompactTaskChoice(id: $0.id, title: $0.title)
        } + codexAgentSessions.filter { $0.hasVisibleActivity && !archivedSessionIDs.contains($0.id) }.map {
            CompactTaskChoice(id: $0.id, title: $0.title)
        }
        let linkedID = boundCodexThreadID
        let historyLoader: CompactHistoryLoader?
        if let id = linkedID {
            historyLoader = { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.linkedSessionTranscript(for: id)
            }
        } else { historyLoader = nil }
        compactInputWindowManager.showConversationInput(entries: entries, historyVisible: historyVisible, title: title,
            taskChoices: choices,
            selectTask: { [weak self] id in _ = self?.showCompactConversationForAgentDockItem(id) },
            loadHistory: historyLoader,
            connectTask: { [weak self] in self?.showCodexSessionConnectionPicker() },
            newTask: { [weak self] in self?.startNewCompactTask() },
            removeTask: { [weak self] in self?.removeCurrentCompactTask() }, submit: submit)
    }
    func showTutorConversation() {
        compactInputAgentSessionID = nil
        ensureTutorDockItem()
        if let threadID = boundCodexThreadID {
            let taskID = companionConversations.activeID
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let entries = try await self.linkedSessionTranscript(for: threadID)
                    guard self.companionConversations.activeID == taskID else { return }
                    self.homeChatEntries = entries
                    self.saveCompactConversation()
                    self.presentCompactTask(entries: entries, historyVisible: true,
                        title: self.companionConversations.active.title) { [weak self] text in self?.submitTutorPrompt(text) }
                } catch {
                    guard self.companionConversations.activeID == taskID else { return }
                    self.presentCompactTask(entries: self.homeChatEntries, historyVisible: true,
                        title: "Disconnected - " + self.companionConversations.active.title) { [weak self] text in self?.submitTutorPrompt(text) }
                }
            }
        } else {
            presentCompactTask(entries: homeChatEntries, historyVisible: true,
                               title: companionConversations.active.title) { [weak self] text in self?.submitTutorPrompt(text) }
        }
    }
    @discardableResult
    func showCompactConversationForAgentDockItem(_ itemID: UUID) -> Bool {
        if companionConversations.conversations.contains(where: { $0.id == itemID && !$0.archived }) {
            if companionConversations.activeID != itemID {
                dismissCoachingOverlays(); saveCompactConversation()
                companionConversations.select(itemID); activateCompactConversation()
            }
            showTutorConversation(); return true
        }
        let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID ?? itemID
        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else { return false }
        compactInputAgentSessionID = sessionID
        presentCompactTask(entries: session.entries, historyVisible: true, title: session.title) { [weak self] text in
            self?.submitTextFollowUp(text, toAgentSessionID: sessionID)
        }
        return true
    }
    func showTutorInput(startDictation: Bool, mode: CompactPromptMode = .screen) {
        guard hasAccessibilityPermission, hasScreenRecordingPermission else { return }
        if mode != .textOnly { startPrewarmedScreenshotCaptureIfPossible() }
        ensureTutorDockItem()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        if mode == .write {
            let appName = writeTargetApplication?.localizedName ?? "the current app"
            presentCompactTask(entries: [], title: "Write for \(appName)") { [weak self] text in
                self?.performWriteRequest(text)
            }
        } else if mode == .textOnly {
            compactInputAgentSessionID = nil
            presentCompactTask(entries: homeChatEntries, title: "Quick question · " + companionConversations.active.title) { [weak self] text in
                self?.submitTutorPrompt(text, attachesScreen: false)
            }
        } else if let sessionID = compactInputAgentSessionID,
           let session = codexAgentSessions.first(where: { $0.id == sessionID }) {
            presentCompactTask(entries: session.entries, title: session.title) { [weak self] text in
                self?.submitTextFollowUp(text, toAgentSessionID: sessionID)
            }
        } else {
            compactInputAgentSessionID = nil
            presentCompactTask(entries: homeChatEntries, title: companionConversations.active.title) { [weak self] text in
                self?.submitTutorPrompt(text)
            }
        }
        guard startDictation else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            do {
                try await OpenSuperWhisperDictation.trigger()
            } catch {
                let alert = NSAlert()
                alert.messageText = "OpenSuperWhisper dictation unavailable"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    func showNotchTextInput(
        accentTheme: ClickyAccentTheme? = nil,
        submitText: ((String) -> Void)? = nil
    ) {
        guard allPermissionsGranted else { return }
        guard !buddyDictationManager.isKeyboardShortcutSessionActiveOrFinalizing else { return }

        startPrewarmedScreenshotCaptureIfPossible()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        compactInputWindowManager.showTextInput(
            accentTheme: accentTheme,
            submitText: submitText ?? { [weak self] submittedText in
                self?.submitTextModePrompt(submittedText)
            }
        )
    }

    func submitTextPrompt(_ submittedText: String) {
        submitTextModePrompt(submittedText)
    }

    func submitTextModePrompt(_ submittedText: String, allowsAgentRouting: Bool = true, attachesScreen: Bool = true) {
        let trimmedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let requestTiming = beginRequestTiming(source: "text_mode", text: trimmedText)
        activeRequestTiming = requestTiming
        defer { activeRequestTiming = nil }
        lastTranscript = trimmedText
        rememberMainConversationUserPrompt(trimmedText, source: "text_mode")
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedText)
        interruptCurrentVoiceResponse()
        clearDetectedElementLocation()

        // The compact panel skips the broad router but still honors an explicit request for an agent.
        if !allowsAgentRouting, let instruction = ScreenTutorRoutingPolicy.explicitAgentInstruction(trimmedText) {
            startVoiceAgentTaskPlan(instruction: instruction, speakAcknowledgement: false, voiceContextUserTranscript: trimmedText)
            beginCursorReplyPresentation()
            updateVoiceResponseCaption("<cursor_reply>Started a background task. Its result will appear here when it finishes.</cursor_reply>",
                                       force: true, updatesDock: false)
            return
        }

        if allowsAgentRouting, routeFinalVoiceTranscriptActionIfNeeded(
            trimmedText,
            source: "text",
            selectionSource: "text_mode",
            directComputerUseSource: "text_mode",
            includeQuickLocalResponses: false
        ) {
            return
        }

        sendTranscriptToClaudeWithScreenshot(transcript: trimmedText, forceScreenContext: !allowsAgentRouting && attachesScreen,
                                             routesAgentWork: allowsAgentRouting, attachesScreen: attachesScreen)
    }
}
