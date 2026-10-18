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
    func submitPendingAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard let sessionID = pendingAgentVoiceFollowUpSessionID else { return false }
        let pendingSource = pendingAgentVoiceFollowUpSource ?? "pending_voice_followup"
        if let createdAt = pendingAgentVoiceFollowUpCreatedAt,
           Date().timeIntervalSince(createdAt) > Self.pendingAgentVoiceFollowUpTTL {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_followup.voice_target_expired",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "ageMs": Int(Date().timeIntervalSince(createdAt) * 1000)
                ]
            )
            return false
        }
        if Self.shouldStartNewAgentInsteadOfPendingFollowUp(trimmedTranscript) {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_followup.bypassed_for_new_agent_request",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "instructionPreview": String(trimmedTranscript.prefix(160)),
                    "requestID": activeRequestTiming?.requestID ?? ""
                ]
            )
            return false
        }
        if Self.isProbablyIncompleteAgentVoiceFollowUp(trimmedTranscript) {
            let timing = activeRequestTiming
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_followup.deferred_incomplete_voice",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "requestID": timing?.requestID ?? "",
                    "instructionLength": trimmedTranscript.count,
                    "instructionPreview": String(trimmedTranscript.prefix(120))
                ]
            )
            showShortSystemResponse("i only caught part of that. try the agent follow-up again.")
            return true
        }
        // The user explicitly targeted an agent from the dock/HUD — either by
        // opening its overlay or pressing Voice — so the next utterance belongs
        // to that agent even if it sounds like a normal local OpenClicky
        // command such as “open Clicky.” Keep this ahead of new-task, direct
        // computer-use, and quick local routing.
        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        pendingAgentVoiceFollowUpSource = nil
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": pendingSource,
                "sessionID": sessionID.uuidString,
                "instructionLength": trimmedTranscript.count
            ]
        )

        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            showShortSystemResponse("i lost track of that agent. open the agent dock and try again.")
            markRequestCompleted(
                route: "agent.followup",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "CodexAgentSession.lookup",
                    "controller": "CompanionManager",
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "error": "Missing agent session"
                ]
            )
            return true
        }

        selectCodexAgentSession(sessionID)
        submitAgentPrompt(trimmedTranscript, to: session)
        lastAgentContextSessionID = sessionID
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": pendingSource,
                "sessionID": sessionID.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        showShortSystemResponse("sent that to \(session.spokenAgentName).")
        return true
    }

    static func isProbablyIncompleteAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return true }

        let danglingSuffixes = [
            "where the agent",
            "where the agents",
            "when the agent",
            "when the agents",
            "that the agent",
            "that the agents",
            "because the agent",
            "because the agents",
            "where it",
            "when it",
            "because it",
            "so it",
            "and it",
            "but it",
            "where",
            "when",
            "because",
            "that",
            "so",
            "and",
            "but"
        ]
        if danglingSuffixes.contains(where: { normalized.hasSuffix($0) }) {
            return true
        }

        let trailingFunctionWords: Set<String> = [
            "the", "a", "an", "to", "for", "with", "of", "in", "on", "at", "from",
            "by", "as", "into", "about", "around", "through", "over", "under"
        ]
        if let lastWord = normalized.split(separator: " ").last,
           trailingFunctionWords.contains(String(lastWord)) {
            return true
        }

        if isMostlySpokenTimestampOrLogNoise(normalized) {
            return true
        }

        return false
    }

    static func isMostlySpokenTimestampOrLogNoise(_ normalizedTranscript: String) -> Bool {
        let words = normalizedTranscript.split(separator: " ").map(String.init)
        guard words.count >= 5 else { return false }

        let timestampTokens: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
            "oh", "o", "t", "z", "am", "pm"
        ]
        let timestampTokenCount = words.filter { timestampTokens.contains($0) }.count
        let timestampTokenRatio = Double(timestampTokenCount) / Double(words.count)

        let hasSpokenDateShape = normalizedTranscript.contains("zero five one zero")
            || normalizedTranscript.contains("zero two six")
            || normalizedTranscript.contains("two zero two six")
            || normalizedTranscript.contains("t one four")
            || normalizedTranscript.contains("t fourteen")

        let usefulWorkPattern = #"\b(?:fix|change|update|add|remove|make|create|build|open|show|find|review|test|run|check|look|inspect|capture|move|point|write|send)\b"#
        let hasUsefulWorkVerb = normalizedTranscript.range(of: usefulWorkPattern, options: .regularExpression) != nil

        return hasSpokenDateShape
            && timestampTokenRatio >= 0.35
            && !hasUsefulWorkVerb
    }

    static func shouldStartNewAgentInsteadOfPendingFollowUp(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard normalized.contains("agent") || normalized.contains("agents") else { return false }
        if explicitNewTaskInstruction(from: transcript) != nil { return true }
        if agentTaskCreationInstruction(from: transcript) != nil { return true }

        let delegationPattern = #"\b(?:get|put|start|spin\s+up|spawn|create|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+|another\s+|new\s+|background\s+)*(?:agent|agents|codex)\b"#
        return normalized.range(of: delegationPattern, options: .regularExpression) != nil
    }

    func submitContextualAgentFollowUp(_ transcript: String, source: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard !Self.isExplicitNewTaskRequest(trimmedTranscript) else { return false }
        // Require an actual follow-up cue — a connector word, the literal
        // word "agent", or a clearly-imperative micro-utterance. Without
        // this gate, any random question (e.g. "can you search the web?")
        // gets eaten by a still-running agent purely because it exists.
        guard Self.isLikelyAgentFollowUpPhrasing(trimmedTranscript) else { return false }
        guard let session = latestSteerableAgentSession() else { return false }
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedTranscript.count
            ]
        )

        selectCodexAgentSession(session.id)
        submitAgentPrompt(trimmedTranscript, to: session)
        lastAgentContextSessionID = session.id
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_followup.steered",
            fields: [
                "sessionID": session.id.uuidString,
                "title": session.title,
                "source": source,
                "instruction": trimmedTranscript
            ]
        )
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        showShortSystemResponse("sent that to \(session.spokenAgentName).")
        return true
    }

    func handleAgentSelectionRequestIfNeeded(from transcript: String, source: String) -> Bool {
        guard let request = Self.agentSelectionRequest(from: transcript) else { return false }
        let timing = activeRequestTiming
        let route = request.followUpText == nil ? "agent.select" : "agent.select_and_followup"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.selectCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "agentName": request.agentName,
                "hasFollowUpText": request.followUpText != nil
            ]
        )

        guard let session = agentSession(matchingSpokenName: request.agentName) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_select.not_found",
                fields: [
                    "source": source,
                    "agentName": request.agentName,
                    "instruction": request.instruction
                ]
            )
            showShortSystemResponse("i couldn't find an agent called \(request.agentName).")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "CompanionManager.agentSession",
                    "controller": "CompanionManager",
                    "source": source,
                    "agentName": request.agentName,
                    "error": "No matching agent session"
                ]
            )
            return true
        }

        selectCodexAgentSession(session.id)
        if isAdvancedModeEnabled {
            showCodexHUD()
        } else {
            showAgentDockWindowNearCurrentScreen()
        }

        var extra: [String: String] = [
            "source": source,
            "agentName": request.agentName,
            "sessionID": session.id.uuidString,
            "title": session.title
        ]
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_select.selected",
            fields: extra.merging([
                "instruction": request.instruction
            ]) { current, _ in current }
        )

        if let followUpText = request.followUpText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !followUpText.isEmpty {
            submitAgentPrompt(followUpText, to: session)
            extra["followUpTextLength"] = "\(followUpText.count)"
            showShortSystemResponse("sent that to \(session.spokenAgentName).")
        } else {
            showShortSystemResponse("switched to \(session.spokenAgentName).")
        }

        markRequestCompleted(
            route: route,
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: extra.merging([
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.selectCodexAgentSession",
                "controller": "CompanionManager"
            ]) { current, _ in current }
        )
        return true
    }

    func agentSession(matchingSpokenName name: String) -> CodexAgentSession? {
        let needle = Self.normalizedAgentLookupText(name)
        guard !needle.isEmpty else { return nil }

        for dockItem in agentDockItems.reversed() {
            let title = Self.normalizedAgentLookupText(dockItem.title)
            guard title == needle || title.contains(needle) || needle.contains(title) else { continue }
            if let sessionID = dockItem.sessionID,
               let session = codexAgentSessions.first(where: { $0.id == sessionID }) {
                return session
            }
        }

        return codexAgentSessions.reversed().first { session in
            let title = Self.normalizedAgentLookupText(session.title)
            return title == needle || title.contains(needle) || needle.contains(title)
        }
    }

    func latestSteerableAgentSession() -> CodexAgentSession? {
        if let activeSession = codexAgentSessions.first(where: { $0.id == activeCodexAgentSessionID }),
           Self.isSteerableAgentStatus(activeSession.status),
           activeSession.hasVisibleActivity {
            return activeSession
        }

        if let lastAgentContextSessionID,
           let lastContextSession = codexAgentSessions.first(where: { $0.id == lastAgentContextSessionID }),
           Self.isSteerableAgentStatus(lastContextSession.status),
           lastContextSession.hasVisibleActivity {
            return lastContextSession
        }

        for dockItem in agentDockItems.reversed() {
            guard let sessionID = dockItem.sessionID,
                  let session = codexAgentSessions.first(where: { $0.id == sessionID }),
                  Self.isSteerableAgentStatus(session.status),
                  session.hasVisibleActivity else {
                continue
            }
            return session
        }

        return nil
    }

    /// Detects whether Haiku's response offered to spin up an agent.
    /// Triggers on phrases like "want me to spin up an agent", "should I
    /// start an agent", "i'd need to spin up an agent", or "I can hand that
    /// to an agent". Used to arm the pending-offer slot so the user's next
    /// "yes" / "okay then" can actually launch the agent.
    static func responseOffersAgentSpawn(_ spokenText: String) -> Bool {
        let normalized = spokenText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let offerPatterns = [
            "spin up an agent",
            "spin one up",
            "start an agent",
            "kick off an agent",
            "launch an agent",
            "spawn an agent",
            "have an agent",
            "agent mode",
            "want me to spin",
            "want me to start",
            "should i spin",
            "should i start"
        ]
        if offerPatterns.contains(where: { normalized.contains($0) }) {
            return true
        }

        let handoffPattern = #"\b(?:hand|send|route|pass|delegate|give)\b.{0,48}\b(?:agent|codex)\b"#
        return normalized.range(of: handoffPattern, options: .regularExpression) != nil
    }

    /// If Haiku's last reply offered an agent and the current transcript
    /// is a confirmation, spawn an agent with the remembered instruction.
    /// Returns true when the offer was accepted (caller should not route
    /// further). Falls through (returns false) when there's no pending
    /// offer, the offer expired, or the transcript isn't a confirmation.
    func acceptPendingAgentOfferIfConfirmed(from transcript: String) -> Bool {
        guard let instruction = pendingAgentOfferInstruction,
              let offeredAt = pendingAgentOfferAt,
              Date().timeIntervalSince(offeredAt) <= Self.pendingAgentOfferTTL else {
            // Stale or absent — clear it so a fresh offer can land later.
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
            return false
        }

        guard Self.isAffirmativeConfirmation(transcript) else { return false }

        pendingAgentOfferInstruction = nil
        pendingAgentOfferAt = nil
        let acknowledgement = "on it, starting an agent for that."
        startVoiceAgentTaskPlan(instruction: instruction, acknowledgement: acknowledgement)
        return true
    }

    /// Recognizes a short affirmative response. Only matches when the
    /// entire transcript is a confirmation — we don't want "yes, but
    /// also do X" being treated as a bare yes.
    static func isAffirmativeConfirmation(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        let affirmatives: Set<String> = [
            "yes", "yeah", "yep", "yup", "yes please", "ok", "okay",
            "okay then", "ok then", "alright", "all right", "sure",
            "sure thing", "go", "go ahead", "go for it", "do it",
            "do that", "let's do it", "lets do it", "let's go",
            "spin it up", "spin one up", "fire it up", "fine", "please do",
            "please", "absolutely", "definitely",
            "can you do that", "could you do that", "would you do that",
            "can you do it", "could you do it", "would you do it",
            "please do that", "please do it"
        ]
        return affirmatives.contains(normalized)
    }

    /// Recognizes phrases that clearly mean "speak to the active agent"
    /// rather than "answer this question yourself". Used to gate
    /// `submitContextualAgentFollowUp` so an idle running agent doesn't
    /// silently absorb every subsequent voice turn.
    // MARK: - Speculative pre-fire

    static func isLikelyAgentFollowUpPhrasing(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return false }

        // Explicit "agent" / "agents" mention always counts as a steer.
        if permissiveAgentInstruction(from: transcript) != nil { return true }

        // Connector words that imply "continue what the agent was doing".
        let connectorPrefixes = [
            "and ", "also ", "now ", "then ", "next ", "after that ",
            "plus ", "as well ", "while you're at it ",
            "keep going", "carry on", "continue", "go on"
        ]
        for prefix in connectorPrefixes where normalized.hasPrefix(prefix) {
            return true
        }

        // Short imperatives like "do that", "yes", "stop", "go".
        let shortImperatives: Set<String> = [
            "do that", "do it", "yes", "yeah", "yep", "ok", "okay",
            "go", "go ahead", "go on", "fine", "sure", "no", "nope", "stop"
        ]
        if shortImperatives.contains(normalized) { return true }

        if isReferentialAgentWorkFollowUp(transcript) { return true }

        return false
    }

    /// Catches follow-ups like "update the form you made earlier" without
    /// routing ordinary questions such as "do you remember what we did earlier"
    /// into Agent Mode.
    static func isReferentialAgentWorkFollowUp(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return false }

        let referenceSignals = [
            "you did earlier",
            "you made earlier",
            "you created earlier",
            "you built earlier",
            "that you did",
            "that you made",
            "that you created",
            "that you built",
            "from earlier",
            "earlier one",
            "previous one",
            "last one",
            "that file",
            "that page",
            "that form",
            "that site",
            "that app",
            "that project",
            "it again"
        ]
        guard referenceSignals.contains(where: normalized.contains) else { return false }

        let workVerbPattern = #"\b(?:update|change|edit|modify|fix|tweak|adjust|add|remove|delete|make|turn|convert|open|reopen|show|preview|run|test|save|export|publish)\b"#
        return normalized.range(of: workVerbPattern, options: .regularExpression) != nil
    }

    static func isSteerableAgentStatus(_ status: CodexAgentSessionStatus) -> Bool {
        switch status {
        case .stopped:
            return false
        case .starting, .ready, .running, .failed:
            return true
        }
    }

    // MARK: - Clear-overlays local intent

    /// Returns true when the transcript is a request to clear overlay
    /// annotations (boxes, highlights, cursor markers).
    /// - Parameter hasActiveOverlayAnnotation: pass `hasActiveOverlayAnnotation`
    ///   to gate pronoun-only forms ("clear those") on a live annotation.
    static func isClearOverlayAnnotationsRequest(
        _ transcript: String,
        hasActiveOverlayAnnotation: Bool
    ) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        // Reject if agent-related words appear — keep agent-cancel priority.
        let agentWords = ["agent", "task", "job", "background", "session"]
        if agentWords.contains(where: normalized.contains) { return false }

        let clearVerbs = ["clear", "remove", "hide", "dismiss", "get rid of"]
        let hasVerb = clearVerbs.contains(where: normalized.contains)
        guard hasVerb else { return false }

        let annotationNouns = [
            "rectangle", "rectangles",
            "box", "boxes",
            "highlight", "highlights", "highlighting",
            "overlay", "overlays",
            "drawing", "drawings",
            "annotation", "annotations",
            "marker", "markers"
        ]
        if annotationNouns.contains(where: normalized.contains) {
            return true
        }

        // Pronoun-only form ("clear those", "hide them") — require an active annotation.
        let pronouns = ["those", "that", "them", "these"]
        if pronouns.contains(where: normalized.contains) {
            return hasActiveOverlayAnnotation
        }

        return false
    }

    var hasActiveOverlayAnnotation: Bool {
        detectedElementScreenLocation != nil
            || detectedElementDisplayFrame != nil
            || !cursorOverlayState.visualGuidanceOverlays.isEmpty
            || !cursorOverlayState.externalSecondaryCursors.isEmpty
    }

    func handleClearOverlayAnnotationsRequestIfNeeded(from transcript: String) -> Bool {
        guard Self.isClearOverlayAnnotationsRequest(
            transcript,
            hasActiveOverlayAnnotation: hasActiveOverlayAnnotation
        ) else { return false }

        let timing = activeRequestTiming
        let logFields: [String: Any] = [
            "executor": "local_fast_path",
            "executionMethod": "CompanionManager.clearOverlayAnnotations",
            "controller": "CompanionManager",
            "screenCaptureSkipped": true,
            "modelSkipped": true
        ]
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.clear_overlays",
            timing: timing,
            extra: logFields
        )

        // Clear all active overlay annotations.
        clearDetectedElementLocation()
        externalSecondaryCursorClearTasks.values.forEach { $0.cancel() }
        externalSecondaryCursorClearTasks.removeAll()
        cursorOverlayState.externalSecondaryCursors.removeAll()
        visualGuidanceOverlayClearTasks.values.forEach { $0.cancel() }
        visualGuidanceOverlayClearTasks.removeAll()
        cursorOverlayState.visualGuidanceOverlays.removeAll()
        clearVoiceResponseCaptionAndInteractiveBubble()
        latestVoiceResponseCard = nil

        showShortSystemResponse(
            "cleared.",
            route: "voice.clear_overlays",
            timing: timing,
            executionStartedAt: executionStartedAt,
            extra: logFields
        )
        return true
    }

    func handleAgentCancellationRequestIfNeeded(from transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }

        if Self.isCancelAllAgentTasksRequest(trimmedTranscript) {
            cancelAllAgentTasks()
            return true
        }

        if Self.isCancelCurrentAgentTaskRequest(trimmedTranscript) {
            cancelCurrentAgentTask()
            return true
        }

        return false
    }

    func cancelAllAgentTasks(reason: String = "agent.cancel_all") {
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.cancel_all",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession"
            ]
        )
        let sessionIDsToCancel = Set(agentDockItems.compactMap(\.sessionID))
        var cancelledCount = 0

        for session in codexAgentSessions {
            guard sessionIDsToCancel.contains(session.id) || Self.isSteerableAgentStatus(session.status) else {
                continue
            }
            cancelAgentTask(sessionID: session.id, removeDockItems: true, reason: reason)
            cancelledCount += 1
        }

        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        pendingAgentVoiceFollowUpSource = nil
        lastAgentContextSessionID = nil

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_tasks.cancelled_all",
            fields: [
                "count": cancelledCount
            ]
        )
        markRequestCompleted(
            route: "agent.cancel_all",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession",
                "cancelledCount": cancelledCount
            ]
        )

        let response: String
        if cancelledCount == 0 {
            response = "there aren't any active agent tasks to cancel."
        } else if cancelledCount == 1 {
            response = "cancelled the agent task."
        } else {
            response = "cancelled all agent tasks."
        }
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: response,
            contextTitle: "Agent tasks"
        )
        showShortSystemResponse(response)
    }

    func cancelCurrentAgentTask() {
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.cancel_current",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession"
            ]
        )
        guard let session = latestSteerableAgentSession() else {
            showShortSystemResponse("there isn't an active agent task to cancel.")
            markRequestCompleted(
                route: "agent.cancel_current",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "latestSteerableAgentSession",
                    "controller": "CompanionManager",
                    "error": "No active agent task"
                ]
            )
            return
        }

        cancelAgentTask(sessionID: session.id, removeDockItems: true, reason: "agent.cancel_current")
        markRequestCompleted(
            route: "agent.cancel_current",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession",
                "sessionID": session.id.uuidString,
                "title": session.title
            ]
        )
        showShortSystemResponse("cancelled \(session.spokenAgentName).")
    }

    func stopCodexAgentSession(_ sessionID: UUID, reason: String = "agent.stop_button") {
        cancelAgentTask(sessionID: sessionID, removeDockItems: true, reason: reason)
    }

    func cancelAgentTask(sessionID: UUID, removeDockItems: Bool, reason: String = "agent.cancel") {
        cancelPendingAgentDockItemRemoval(for: sessionID)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSession = codexAgentSessions.first(where: { $0.id == sessionID })
        targetSession?.stop(reason: normalizedReason.isEmpty ? nil : normalizedReason)
        completeAgentRequestTimingIfNeeded(
            sessionID: sessionID,
            status: "cancelled",
            extra: [
                "cancelReason": normalizedReason.isEmpty ? "unknown" : normalizedReason
            ]
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.cancelled",
            fields: [
                "sessionID": sessionID.uuidString,
                "title": targetSession?.title ?? "Agent",
                "reason": normalizedReason.isEmpty ? "unknown" : normalizedReason
            ]
        )
        let announcementReason = Self.prettyCancelReason(for: normalizedReason)
        announceAgentCompletionIfNeeded(
            sessionID: sessionID,
            outcome: "cancelled",
            summary: announcementReason,
            cancelReason: normalizedReason
        )
        if removeDockItems {
            scheduleAgentDockItemRemoval(for: sessionID)
        }
        if pendingAgentVoiceFollowUpSessionID == sessionID {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
        }
        if lastAgentContextSessionID == sessionID {
            lastAgentContextSessionID = nil
        }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        scheduleStatusSync()
    }

    func startExplicitAgentTaskIfRequested(from transcript: String) -> Bool {
        if let newTaskInstruction = Self.explicitNewTaskInstruction(from: transcript) {
            guard !newTaskInstruction.isEmpty else {
                showShortSystemResponse("what should the new task be?")
                return true
            }

            startVoiceAgentTaskPlan(instruction: newTaskInstruction)
            return true
        }

        if Self.isIncompleteExplicitNewTaskRequest(from: transcript) {
            showShortSystemResponse("what should the new task be?")
            return true
        }

        if let taskCreationInstruction = Self.agentTaskCreationInstruction(from: transcript) {
            guard !taskCreationInstruction.isEmpty else {
                showShortSystemResponse("what should the agent do?")
                return true
            }

            if let typeRequest = Self.nativeTypeRequest(from: taskCreationInstruction) {
                typeTextUsingSelectedComputerUse(typeRequest)
                return true
            }

            if let keyPressRequest = Self.nativeKeyPressRequest(from: taskCreationInstruction) {
                pressKeyUsingSelectedComputerUse(keyPressRequest)
                return true
            }

            if let clickRequest = Self.nativeClickRequest(from: taskCreationInstruction) {
                clickUsingSelectedComputerUse(clickRequest)
                return true
            }

            if let systemVolumeAction = Self.systemVolumeControlAction(from: taskCreationInstruction) {
                runSystemVolumeControl(systemVolumeAction, instruction: taskCreationInstruction)
                return true
            }

            if let folderRequest = folderOpenRequest(from: taskCreationInstruction),
               Self.shouldInlineDirectFolderOpenFromAgentInstruction(taskCreationInstruction) {
                openRequestedFolder(folderRequest)
                return true
            }

            print("OpenClicky agent task creation request detected: \(taskCreationInstruction)")
            startVoiceAgentTaskPlan(instruction: taskCreationInstruction)
            return true
        }

        if Self.isIncompleteAgentTaskCreationRequest(from: transcript) {
            showShortSystemResponse("what should the agent do?")
            return true
        }

        let explicitInstructionFromCliky = Self.clickyAgentInstruction(from: transcript)
        let permissiveInstruction = explicitInstructionFromCliky == nil
            ? Self.permissiveAgentInstruction(from: transcript)
            : nil

        guard let explicitInstruction = explicitInstructionFromCliky ?? permissiveInstruction else {
            return false
        }

        guard !explicitInstruction.isEmpty else {
            print("OpenClicky agent trigger detected without an instruction.")
            showShortSystemResponse("what should the agent do?")
            return true
        }

        var instruction = SpokenText.normalizedAgentTaskInstruction(from: explicitInstruction)
        if Self.isReferentialAgentInstruction(instruction) {
            guard let resolvedInstruction = referentialAgentInstructionContext(excluding: transcript) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.referential_instruction_unresolved",
                    fields: [
                        "transcript": transcript,
                        "explicitInstruction": explicitInstruction,
                        "requestID": activeRequestTiming?.requestID ?? "none"
                    ]
                )
                showShortSystemResponse("what should the agent do?")
                return true
            }

            instruction = resolvedInstruction
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.referential_instruction_resolved",
                fields: [
                    "transcript": transcript,
                    "explicitInstruction": explicitInstruction,
                    "resolvedInstruction": instruction,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
        }
        if let typeRequest = Self.nativeTypeRequest(from: instruction) {
            typeTextUsingSelectedComputerUse(typeRequest)
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: instruction) {
            pressKeyUsingSelectedComputerUse(keyPressRequest)
            return true
        }

        if let clickRequest = Self.nativeClickRequest(from: instruction) {
            clickUsingSelectedComputerUse(clickRequest)
            return true
        }

        if let systemVolumeAction = Self.systemVolumeControlAction(from: instruction) {
            runSystemVolumeControl(systemVolumeAction, instruction: instruction)
            return true
        }

        if let folderRequest = folderOpenRequest(from: instruction),
           Self.shouldInlineDirectFolderOpenFromAgentInstruction(instruction) {
            openRequestedFolder(folderRequest)
            return true
        }

        if let compositeRequest = Self.compositeAppActionRequest(from: instruction) {
            startVoiceAgentTask(
                instruction: Self.compositeAppActionAgentInstruction(from: compositeRequest),
                acknowledgement: "i’ll do the app action, not just open the app.",
                route: "agent.composite_app_action",
                voiceContextUserTranscript: instruction
            )
            return true
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: instruction) {
            _ = openRequestedApplication(appOpenRequest)
            return true
        }
        if Self.isIncompleteLocalAppOpenRequest(from: instruction) {
            showShortSystemResponse("what app should I open?")
            return true
        }

        print("OpenClicky agent task detected; starting agent task: \(instruction)")
        startVoiceAgentTaskPlan(instruction: instruction)
        return true
    }

    func referentialAgentInstructionContext(excluding transcript: String) -> String? {
        let now = Date()
        if let pendingInstruction = pendingAgentOfferInstruction,
           let offeredAt = pendingAgentOfferAt,
           now.timeIntervalSince(offeredAt) <= Self.pendingAgentOfferTTL {
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
            return pendingInstruction
        }

        if let offeredAt = pendingAgentOfferAt,
           now.timeIntervalSince(offeredAt) > Self.pendingAgentOfferTTL {
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
        }

        let candidates: [(String?, Date?)] = [
            (lastVoiceUserTranscript, lastVoiceUserTranscriptAt),
            (previousVoiceUserTranscript, previousVoiceUserTranscriptAt)
        ]
        for (candidate, candidateAt) in candidates {
            guard let candidate,
                  let candidateAt,
                  now.timeIntervalSince(candidateAt) <= Self.pendingAgentOfferTTL else {
                continue
            }
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCandidate.isEmpty,
                  SpokenText.normalizedSpokenCommandText(trimmedCandidate) != SpokenText.normalizedSpokenCommandText(transcript),
                  !Self.isReferentialAgentInstruction(trimmedCandidate) else {
                continue
            }
            return trimmedCandidate
        }

        return nil
    }

    static func isCancelAllAgentTasksRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        if isAgentDelegationRequest(normalizedTranscript) {
            return false
        }
        let phrases = [
            "cancel all tasks",
            "cancel all task",
            "cancel all agents",
            "cancel all agent tasks",
            "stop all tasks",
            "stop all agents",
            "stop all agent tasks",
            "kill all tasks",
            "kill all agents",
            "dismiss all tasks",
            "dismiss all agents",
            "clear all tasks",
            "clear all agents",
            "cancel everything",
            "stop everything",
            "kill everything"
        ]
        return phrases.contains { normalizedTranscript.contains($0) }
    }

    static func isCancelCurrentAgentTaskRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        if isAgentDelegationRequest(normalizedTranscript) {
            return false
        }
        let phrases = [
            "cancel that",
            "cancel this",
            "cancel it",
            "cancel task",
            "cancel the task",
            "cancel current task",
            "cancel current agent",
            "cancel the agent",
            "cancel that agent",
            "stop that",
            "stop this",
            "stop it",
            "stop task",
            "stop the task",
            "stop current task",
            "stop current agent",
            "stop the agent",
            "kill that",
            "kill this",
            "kill it",
            "kill task",
            "kill the task",
            "done with that",
            "done with this"
        ]
        if phrases.contains(normalizedTranscript) {
            return true
        }

        let explicitAgentStopPattern = #"\b(?:cancel|stop|kill|dismiss)\b.{0,28}\b(?:agent|task|codex|background\s+task)\b"#
        return normalizedTranscript.range(of: explicitAgentStopPattern, options: .regularExpression) != nil
    }

    static func isAgentDelegationRequest(_ normalizedTranscript: String) -> Bool {
        let delegationPhrases = [
            "get another agent",
            "start another agent",
            "spin up another agent",
            "launch another agent",
            "get an agent",
            "start an agent",
            "spin up an agent",
            "launch an agent",
            "have an agent",
            "ask an agent",
            "new agent",
            "another agent to",
            "agent to look",
            "agent look at",
            "agent to check",
            "agent to investigate",
            "agent to fix"
        ]
        return delegationPhrases.contains { normalizedTranscript.contains($0) }
    }

    static func explicitNewTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task\s*[:,-]?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch|set\s+off)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task\s*(?:to|for|that)?\s+(.+?)\s*$"#,
            #"(?i)^\s*set\s+(?:an?\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+(?:off|going)\s+(?:to|for|that)?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:new|separate|different)\s+(?:agent|codex)\s*(?:task|job|session)?\s*[:,-]?\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let instruction = SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        return nil
    }

    static func isExplicitNewTaskRequest(_ transcript: String) -> Bool {
        explicitNewTaskInstruction(from: transcript) != nil || isIncompleteExplicitNewTaskRequest(from: transcript)
    }

    static func isIncompleteExplicitNewTaskRequest(from transcript: String) -> Bool {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch|set\s+off)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task[\s\.\!\?]*$"#,
            #"(?i)^\s*set\s+(?:an?\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+(?:off|going)[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:new|separate|different)\s+(?:agent|codex)\s*(?:task|job|session)?[\s\.\!\?]*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            if regex.firstMatch(in: candidate, range: range) != nil {
                return true
            }
        }

        return false
    }

    static func quickLocalVoiceResponseText(for transcript: String) -> String? {
        let candidate = normalizedQuickLocalVoiceResponseCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let acknowledgementChecks = [
            "yes", "yeah", "yep", "no", "nope", "ok", "okay",
            "ok then", "okay then",
            "alright", "all right", "yeah alright", "yeah all right",
            "sounds good", "fair enough"
        ]
        if acknowledgementChecks.contains(candidate) {
            return "okay."
        }

        let hearingChecks = [
            "can you hear me",
            "can you hear us",
            "do you hear me",
            "do you hear us",
            "are you hearing me",
            "are you hearing us"
        ]
        if hearingChecks.contains(candidate) {
            return "yes, i can hear you."
        }

        let availabilityChecks = [
            "are you there",
            "are you still there",
            "are you listening",
            "are you awake",
            "you there",
            "hello",
            "hello there",
            "hi"
        ]
        if availabilityChecks.contains(candidate) {
            return "i'm here."
        }

        let connectionChecks = [
            "are you connected",
            "are we connected",
            "am i connected",
            "are you online",
            "are you working",
            "checking connection",
            "checking connection 123",
            "checking connection one two three",
            "connection check",
            "connection check 123",
            "connection check one two three"
        ]
        if connectionChecks.contains(candidate) {
            return "connection is working."
        }

        let capabilityChecks = [
            "what can you do",
            "what can you do for me",
            "what do you do",
            "what are you able to do",
            "what can openclicky do",
            "what can clicky do"
        ]
        if capabilityChecks.contains(candidate) {
            return "i can answer quick questions, look at your screen when needed, open apps and control your Mac, and hand bigger jobs to Agent Mode."
        }

        let voiceControlChecks = [
            "checking voice",
            "checking voice control",
            "just checking voice",
            "just checking voice control",
            "test test",
            "test 123",
            "test one two three",
            "testing",
            "testing 123",
            "testing one two three",
            "testing testing",
            "testing testing 123",
            "testing testing testing",
            "testing voice",
            "testing voice control",
            "testing out voice",
            "testing out voice control",
            "i am testing voice control",
            "i am testing out voice control",
            "im testing voice control",
            "im testing out voice control"
        ]
        if voiceControlChecks.contains(candidate) {
            return "voice control is working."
        }

        let slowResponseChecks = [
            "nothing is happening",
            "nothing happening",
            "why is nothing happening"
        ]
        if slowResponseChecks.contains(candidate) {
            return "i'm here. that last response was taking longer than expected."
        }

        return nil
    }

    static func normalizedQuickLocalVoiceResponseCandidate(from transcript: String) -> String {
        var candidate = SpokenText.normalizedSpokenCommandText(transcript)
        let fillerPrefixes = ["hey", "ok", "okay", "right", "so"]
        let invocationPrefixes = [
            "learning buddy",
            "cursor buddy",
            "leaning buddy",
            "open clicky",
            "openclicky",
            "clicky",
            "buddy"
        ]

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            for prefix in fillerPrefixes + invocationPrefixes {
                if candidate == prefix {
                    return ""
                }
                if candidate.hasPrefix(prefix + " ") {
                    candidate.removeFirst(prefix.count)
                    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    didStripPrefix = true
                }
            }
        }

        return candidate
    }

    func handleQuickLocalVoiceResponseIfNeeded(from transcript: String) -> Bool {
        guard let responseText = Self.quickLocalVoiceResponseText(for: transcript) else { return false }

        let timing = activeRequestTiming
        let logFields: [String: Any] = [
            "executor": "local_fast_path",
            "executionMethod": "CompanionManager.quickLocalVoiceResponseText",
            "controller": "CompanionManager",
            "screenCaptureSkipped": true,
            "modelSkipped": true,
            "transcriptLength": transcript.count,
            "spokenTextLength": responseText.count
        ]
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.quick_local_response",
            timing: timing,
            extra: logFields
        )

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: responseText,
            contextTitle: transcript
        )
        showShortSystemResponse(
            responseText,
            route: "voice.quick_local_response",
            timing: timing,
            executionStartedAt: executionStartedAt,
            extra: logFields
        )
        return true
    }

    func handleAgentStatusQuestionIfNeeded(from transcript: String) -> Bool {
        guard Self.isAgentStatusQuestion(transcript) else { return false }
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.status",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "agentStatusSpokenSummary",
                "controller": "CompanionManager"
            ]
        )

        let summary = agentStatusSpokenSummary()
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: summary,
            contextTitle: "Agent status"
        )
        if codexAgentSessions.contains(where: { $0.hasVisibleActivity && !archivedSessionIDs.contains($0.id) }) {
            ensureCursorOverlayVisibleForAgentTask()
            showAgentDockWindowNearCurrentScreen()
        }
        showShortSystemResponse(summary)
        markRequestCompleted(
            route: "agent.status",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "agentStatusSpokenSummary",
                "controller": "CompanionManager",
                "visibleAgentCount": codexAgentSessions.filter { session in
                    session.hasVisibleActivity && !archivedSessionIDs.contains(session.id)
                }.count
            ]
        )
        return true
    }

    func agentStatusSpokenSummary() -> String {
        let visibleSessions = codexAgentSessions.filter { session in
            session.hasVisibleActivity && !archivedSessionIDs.contains(session.id)
        }
        guard !visibleSessions.isEmpty else {
            return "no agents are running yet."
        }

        let runningCount = visibleSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }.count
        let failedCount = visibleSessions.filter { session in
            if case .failed = session.status { return true }
            return false
        }.count
        let readyCount = visibleSessions.filter { session in
            if case .ready = session.status { return true }
            return false
        }.count

        let headline: String
        if runningCount > 0 {
            headline = "\(Self.spokenCount(runningCount, singular: "agent", plural: "agents")) running"
        } else if failedCount > 0 {
            headline = "\(Self.spokenCount(failedCount, singular: "agent", plural: "agents")) needing attention"
        } else {
            headline = "\(Self.spokenCount(readyCount, singular: "agent", plural: "agents")) ready"
        }

        let details = visibleSessions
            .suffix(3)
            .map(\.statusSummaryLine)
            .joined(separator: " ")

        return "you have \(Self.spokenCount(visibleSessions.count, singular: "agent", plural: "agents")): \(headline). \(details)"
    }

    func updateAgentProgressNarration() {
        let now = Date()
        if let lastAgentProgressNarrationAt,
           now.timeIntervalSince(lastAgentProgressNarrationAt) < 30 {
            return
        }

        speakAgentProgressUpdateIfAppropriate(now: now)
    }

    func speakAgentProgressUpdateIfAppropriate(now: Date = Date()) {
        // Default OFF: users asked to stop automatic "working on it"
        // style voice updates while agents are still in flight.
        let progressVoiceEnabled = UserDefaults.standard.object(forKey: Self.agentProgressVoiceUpdatesDefaultsKey) as? Bool ?? false
        guard progressVoiceEnabled else { return }

        let runningSessions = codexAgentSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }

        guard !runningSessions.isEmpty else { return }
        guard voiceState == .idle else { return }

        // Only narrate sessions that have substantively new activity since
        // the last time we spoke about them. No filler — "we're working"
        // / "we're starting" no longer counts. If nothing meaningful has
        // changed, stay silent. This replaces the old behavior of
        // speaking "the agent says we're working" every 30 seconds.
        let updates: [(session: CodexAgentSession, phrase: String, signature: String)] =
            runningSessions.compactMap { session in
                guard let phrase = Self.agentProgressPhrase(for: session) else { return nil }
                let signature = "\(session.id.uuidString)|\(phrase)"
                if lastAgentProgressNarrationSignatures[session.id] == phrase {
                    return nil
                }
                return (session, phrase, signature)
            }

        guard !updates.isEmpty else { return }

        let updateText: String
        if updates.count == 1, let only = updates.first {
            updateText = "\(only.session.spokenAgentSentenceName) says \(only.phrase)."
        } else {
            let details = updates
                .prefix(3)
                .map { "\($0.session.spokenAgentSentenceName) says \($0.phrase)" }
                .joined(separator: ". ")
            let remainingCount = updates.count - min(updates.count, 3)
            if remainingCount > 0 {
                updateText = "\(details). \(remainingCount) more running."
            } else {
                updateText = details + "."
            }
        }

        for update in updates {
            lastAgentProgressNarrationSignatures[update.session.id] = update.phrase
        }
        lastAgentProgressNarrationAt = now
        showShortSystemResponse(updateText)
    }

    /// Build the spoken phrase for an in-flight agent. Returns `nil` when
    /// there is nothing substantive to say — never returns filler like
    /// "we're working" or "we're starting", because the narration policy
    /// is now silence-by-default.
    static func agentProgressPhrase(for session: CodexAgentSession) -> String? {
        guard let activity = session.latestActivitySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !activity.isEmpty else {
            return nil
        }

        // Map a few well-known activity shapes to natural-sounding phrases.
        // For anything else, just speak the raw activity verbatim.
        if activity.contains("matching files") || activity.contains("looking for") {
            return "we're checking the files"
        }
        if activity.contains("focusing") || activity.contains("showing") {
            return "we're opening what we found"
        }
        if activity.contains("checking the work") {
            return "we're checking the work"
        }
        // Suppress the "we're working" / "still working" filler — we want
        // silence when nothing concrete has happened. If the activity is
        // genuinely just a "working" word with no detail, return nil.
        if activity == "working" || activity == "still working"
            || activity == "running" || activity == "in progress" {
            return nil
        }
        return "we're \(activity)"
    }

    static func isAgentStatusQuestion(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)

        let mentionsAgent = normalizedTranscript.contains("agent") || normalizedTranscript.contains("agents") || normalizedTranscript.contains("codex")
        guard mentionsAgent else { return false }

        let statusPatterns = [
            #"\b(?:agent|agents|codex)\s+(?:status|progress)\b"#,
            #"\b(?:status|progress)\s+(?:of|on|for)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\b(?:how\s+(?:are|is|s))\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\bwhat\s+(?:are|is|s)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+(?:doing|up\s+to|working\s+on)\b"#,
            #"\bwhat\s+(?:is|s)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+status\b"#,
            #"\bwhat\s+(?:is|s)\s+(?:the\s+)?(?:status|progress)\s+(?:of|on|for)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\b(?:is|are)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+(?:still\s+)?(?:running|finished|done|working)\b"#,
            #"\b(?:agent|agents|codex)\s+(?:still\s+)?(?:doing|running|finished|done|working)\b"#,
            #"\b(?:agent|agents|codex)\s+up\s+to\b"#,
            #"\b(?:your|the)\s+(?:agent|agents|codex)\s+(?:status|progress)\b"#
        ]

        return statusPatterns.contains { pattern in
            normalizedTranscript.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func spokenCount(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "one \(singular)" : "\(count) \(plural)"
    }

    static func alphanumericTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var currentStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if currentStart == nil {
                    currentStart = index
                }
            } else if let start = currentStart {
                ranges.append(start..<index)
                currentStart = nil
            }
            index = text.index(after: index)
        }

        if let start = currentStart {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }
}
