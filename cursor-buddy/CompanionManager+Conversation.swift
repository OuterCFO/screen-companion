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
    static let activeVoiceConversationHistoryLimit = 8
    static let compactedVoiceConversationArchiveCharacterLimit = 2_400
    static let compactedVoiceConversationArchiveDefaultsKey = "openClickyCompactedVoiceConversationArchive"

    func setHomeChatModeActive(_ isActive: Bool, source: String) {
        guard isHomeChatModeActive != isActive else { return }
        isHomeChatModeActive = isActive
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "openclicky.home_chat.mode_changed",
            fields: [
                "source": source,
                "isActive": isActive
            ]
        )
    }

    func submitHomeChatPromptFromUI(_ prompt: String, source: String = "open_clicky_panel_chat") {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        setHomeChatModeActive(true, source: source)
        submitHomeChatPromptToAskAgent(trimmedPrompt, source: source)
    }

    @discardableResult
    func submitHomeChatVoiceTranscriptIfNeeded(_ transcript: String, source: String) -> Bool {
        guard isHomeChatModeActive else { return false }
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        submitHomeChatPromptToAskAgent(trimmedTranscript, source: source)
        return true
    }

    func submitHomeChatPromptToAskAgent(_ prompt: String, source: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let session = codexAgentSession
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.home_chat.ask_agent_prompt",
            fields: [
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedPrompt.count
            ]
        )
        if session.isTurnActiveForChatQueue {
            session.submitPromptFromUI(trimmedPrompt, screenContext: nil)
        } else {
            stageDashboardAgentSubmission(prompt: trimmedPrompt, session: session)
            submitAgentPrompt(trimmedPrompt, to: session)
        }
    }

    func appendHomeChatEntry(role: CodexTranscriptEntry.Role, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        if let last = homeChatEntries.last,
           last.role == role,
           SpokenText.normalizedSpokenCommandText(last.text) == SpokenText.normalizedSpokenCommandText(trimmedText) {
            return
        }
        homeChatEntries.append(CodexTranscriptEntry(role: role, text: trimmedText))
        if homeChatEntries.count > 24 {
            homeChatEntries.removeFirst(homeChatEntries.count - 24)
        }
        if let data = try? JSONEncoder().encode(homeChatEntries) {
            UserDefaults.standard.set(data, forKey: "openclicky.tutorChatHistory")
            saveCompactConversation()
        }
    }

    func rememberVoiceExchange(userTranscript: String, assistantResponse: String, reason: String) {
        let trimmedUserTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistantResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserTranscript.isEmpty, !trimmedAssistantResponse.isEmpty else { return }

        appendHomeChatEntry(role: .user, text: trimmedUserTranscript)
        appendHomeChatEntry(role: .assistant, text: trimmedAssistantResponse)
        if let index = agentDockItems.firstIndex(where: { $0.id == tutorDockItemID }) {
            agentDockItems[index].userInstruction = trimmedUserTranscript
            agentDockItems[index].caption = trimmedAssistantResponse
            agentDockItems[index].status = .done
            agentDockItems[index].progressStageLabel = "Ready"
        }

        conversationHistory.append((
            userTranscript: trimmedUserTranscript,
            assistantResponse: trimmedAssistantResponse
        ))
        compactVoiceConversationHistoryIfNeeded(reason: reason)
        OpenClickyMessageLogStore.shared.appendConversationTurn(
            lane: "voice",
            direction: "incoming",
            role: "user",
            text: trimmedUserTranscript,
            source: reason,
            title: "Voice conversation",
            extraFields: [
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0
            ]
        )
        OpenClickyMessageLogStore.shared.appendConversationTurn(
            lane: "voice",
            direction: "outgoing",
            role: "assistant",
            text: trimmedAssistantResponse,
            source: reason,
            title: "Voice conversation",
            extraFields: [
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0
            ]
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.conversation_history.updated",
            fields: [
                "reason": reason,
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0,
                "userTranscriptLength": trimmedUserTranscript.count,
                "assistantResponseLength": trimmedAssistantResponse.count
            ]
        )
    }

    func rememberSilentAgentHandoff(userTranscript: String, instruction: String, reason: String) {
        let trimmedUserTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserTranscript.isEmpty, !trimmedInstruction.isEmpty else { return }

        let contextResponse = Self.agentHandoffVoiceContextResponse(instruction: trimmedInstruction)
        conversationHistory.append((
            userTranscript: trimmedUserTranscript,
            assistantResponse: contextResponse
        ))
        compactVoiceConversationHistoryIfNeeded(reason: reason)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.agent_handoff_context_preserved",
            fields: [
                "reason": reason,
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0,
                "instructionPreview": Self.voiceArchiveSnippet(trimmedInstruction, limit: 180)
            ]
        )
    }

    func voiceConversationHistoryForAPI() -> [(userPlaceholder: String, assistantResponse: String)] {
        var history: [(userPlaceholder: String, assistantResponse: String)] = []
        if let compactedVoiceConversationArchive,
           !compactedVoiceConversationArchive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.append((
                userPlaceholder: "[earlier OpenClicky voice context]",
                assistantResponse: compactedVoiceConversationArchive
            ))
        }
        history.append(contentsOf: conversationHistory.map { entry in
            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
        })
        return Self.voiceConversationHistoryIncludingRecentUnpairedPrompts(
            baseHistory: history,
            lastPrompt: lastVoiceUserTranscript,
            lastPromptAt: lastVoiceUserTranscriptAt,
            previousPrompt: previousVoiceUserTranscript,
            previousPromptAt: previousVoiceUserTranscriptAt
        )
    }

    static func voiceConversationHistoryIncludingRecentUnpairedPrompts(
        baseHistory: [(userPlaceholder: String, assistantResponse: String)],
        lastPrompt: String?,
        lastPromptAt: Date?,
        previousPrompt: String?,
        previousPromptAt: Date?,
        now: Date = Date()
    ) -> [(userPlaceholder: String, assistantResponse: String)] {
        var history = baseHistory
        var seenPrompts = Set(history.map { SpokenText.normalizedSpokenCommandText($0.userPlaceholder) })
        let candidates: [(String?, Date?)] = [
            (previousPrompt, previousPromptAt),
            (lastPrompt, lastPromptAt)
        ]

        for (candidate, candidateAt) in candidates {
            guard let candidate,
                  let candidateAt,
                  now.timeIntervalSince(candidateAt) <= pendingAgentVoiceFollowUpTTL else {
                continue
            }
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCandidate = SpokenText.normalizedSpokenCommandText(trimmedCandidate)
            guard !trimmedCandidate.isEmpty,
                  !seenPrompts.contains(normalizedCandidate),
                  !isReferentialAgentInstruction(trimmedCandidate) else {
                continue
            }
            history.append((
                userPlaceholder: trimmedCandidate,
                assistantResponse: "OpenClicky routed that voice request into the app or Agent Mode, so keep it as the current conversation topic."
            ))
            seenPrompts.insert(normalizedCandidate)
        }

        return history
    }

    func compactVoiceConversationHistoryIfNeeded(reason: String) {
        let activeLimit = Self.activeVoiceConversationHistoryLimit
        guard conversationHistory.count > activeLimit else { return }

        let archiveCount = conversationHistory.count - activeLimit
        let archivedEntries = Array(conversationHistory.prefix(archiveCount))
        conversationHistory.removeFirst(archiveCount)

        let archiveChunk = archivedEntries.map { entry in
            "User: \(Self.voiceArchiveSnippet(entry.userTranscript))\nOpenClicky: \(Self.voiceArchiveSnippet(entry.assistantResponse))"
        }.joined(separator: "\n")

        let mergedArchive: String
        if let existing = compactedVoiceConversationArchive,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mergedArchive = existing + "\n" + archiveChunk
        } else {
            mergedArchive = archiveChunk
        }
        compactedVoiceConversationArchive = Self.trailingCharacters(
            of: mergedArchive,
            limit: Self.compactedVoiceConversationArchiveCharacterLimit
        )
        persistCompactedVoiceConversationArchive(
            archiveChunk: archiveChunk,
            reason: reason,
            archivedExchangeCount: archivedEntries.count
        )

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.conversation_history.compacted",
            fields: [
                "reason": reason,
                "archivedExchangeCount": archivedEntries.count,
                "activeHistoryCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0
            ]
        )
    }

    func persistCompactedVoiceConversationArchive(archiveChunk: String, reason: String, archivedExchangeCount: Int) {
        let savedArchive = compactedVoiceConversationArchive?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !savedArchive.isEmpty else { return }

        UserDefaults.standard.set(savedArchive, forKey: Self.compactedVoiceConversationArchiveDefaultsKey)
        saveCompactConversation()

        let trimmedChunk = archiveChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else { return }

        do {
            try codexHomeManager.appendPersistentMemoryEvent(
                userRequest: "Automatically compact OpenClicky voice context",
                agentResponse: "Compacted \(archivedExchangeCount) older exchange\(archivedExchangeCount == 1 ? "" : "s") during \(reason): \(trimmedChunk)"
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.conversation_history.compaction_memory_failed",
                fields: [
                    "reason": reason,
                    "archivedExchangeCount": archivedExchangeCount,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    static func voiceArchiveSnippet(_ text: String, limit: Int = 220) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func trailingCharacters(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "…\n" + String(text.suffix(limit))
    }

    func rememberMainConversationUserPrompt(_ transcript: String, source: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty,
              trimmedTranscript != "Realtime voice input",
              !Self.isReferentialAgentInstruction(trimmedTranscript) else {
            return
        }
        if let lastVoiceUserTranscript,
           let lastVoiceUserTranscriptAt,
           Date().timeIntervalSince(lastVoiceUserTranscriptAt) < 2,
           SpokenText.normalizedSpokenCommandText(lastVoiceUserTranscript) == SpokenText.normalizedSpokenCommandText(trimmedTranscript) {
            return
        }

        if let lastVoiceUserTranscript {
            previousVoiceUserTranscript = lastVoiceUserTranscript
            previousVoiceUserTranscriptAt = lastVoiceUserTranscriptAt
        }
        lastVoiceUserTranscript = trimmedTranscript
        lastVoiceUserTranscriptAt = Date()
        appendHomeChatEntry(role: .user, text: trimmedTranscript)

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.main_conversation_context.updated",
            fields: [
                "source": source,
                "promptLength": trimmedTranscript.count,
                "promptPreview": String(trimmedTranscript.prefix(160))
            ]
        )
    }

    func clearCurrentResponseTask(ifMatches token: UUID) {
        guard currentResponseTaskToken == token else { return }
        currentResponseTask = nil
        currentResponseTaskToken = nil
    }
}
