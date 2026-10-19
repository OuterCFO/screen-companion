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
    func startVoiceAgentTaskPlan(
        instruction: String,
        acknowledgement: String? = nil,
        route: String = "agent.start",
        speakAcknowledgement: Bool = true,
        interruptVoiceResponse: Bool = false,
        voiceContextUserTranscript: String? = nil
    ) {
        let effectiveSpeakAcknowledgement: Bool
        if suppressNextVoiceAgentStartAcknowledgement {
            effectiveSpeakAcknowledgement = false
            suppressNextVoiceAgentStartAcknowledgement = false
        } else {
            effectiveSpeakAcknowledgement = speakAcknowledgement
        }

        let plannedInstructions = Self.parallelAgentInstructions(from: instruction)
        guard plannedInstructions.count > 1 else {
            startVoiceAgentTask(
                instruction: instruction,
                acknowledgement: acknowledgement,
                route: route,
                speakAcknowledgement: effectiveSpeakAcknowledgement,
                interruptVoiceResponse: interruptVoiceResponse,
                voiceContextUserTranscript: voiceContextUserTranscript
            )
            return
        }

        let splitAcknowledgement = acknowledgement ?? "i’ll split that into \(plannedInstructions.count) background agents."
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.split_route",
            fields: [
                "originalInstruction": instruction,
                "taskCount": plannedInstructions.count,
                "executor": "agent_mode",
                "route": "\(route).split",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )

        for (index, plannedInstruction) in plannedInstructions.enumerated() {
            startVoiceAgentTask(
                instruction: plannedInstruction,
                acknowledgement: index == 0 ? splitAcknowledgement : nil,
                route: "\(route).split",
                speakAcknowledgement: effectiveSpeakAcknowledgement && index == 0,
                interruptVoiceResponse: interruptVoiceResponse && index == 0,
                voiceContextUserTranscript: voiceContextUserTranscript ?? instruction
            )
        }
    }

    func startVoiceAgentTask(
        instruction: String,
        acknowledgement: String? = nil,
        route: String = "agent.start",
        speakAcknowledgement: Bool = true,
        interruptVoiceResponse: Bool = false,
        voiceContextUserTranscript: String? = nil
    ) {
        // Note: when the user explicitly said "agent" we do NOT route
        // through `handleDirectComputerUseRequest` here — that path
        // tries to hijack the request into Background Computer Use /
        // native CUA and fails silently when the BCU runtime isn't
        // running. Agent invocation always means "delegate to the
        // coder agent". Inline shortcuts (open-app / type / press /
        // open-folder) are still handled in `startExplicitAgentTaskIfRequested`
        // before we reach this function.
        var instruction = instruction
        if Self.isRawTransportDiagnosticEvent(instruction) {
            // A prompt that carries log evidence plus user intent is a
            // real task ("find out why these logs..."), not transport echo
            // — refuse only when no analysis instruction can be derived.
            guard let logInstruction = Self.logEvidenceAnalysisInstruction(from: instruction) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.raw_transport_event_ignored",
                    fields: [
                        "source": "voice_agent_task",
                        "instructionPreview": Self.voiceArchiveSnippet(instruction, limit: 240),
                        "requestID": activeRequestTiming?.requestID ?? "none"
                    ]
                )
                showShortSystemResponse("that looks like an internal OpenClicky runtime event, not a task.")
                return
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.log_evidence_rescued",
                fields: [
                    "source": "voice_agent_task",
                    "instructionPreview": Self.voiceArchiveSnippet(instruction, limit: 240),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            instruction = logInstruction
        }

        let startFingerprint = Self.voiceAgentStartFingerprint(
            instruction: instruction,
            route: route
        )
        let now = Date()
        if lastVoiceAgentStartFingerprint == startFingerprint,
           let previousStart = lastVoiceAgentStartAt,
           now.timeIntervalSince(previousStart) <= Self.voiceAgentStartDuplicateTTL {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.duplicate_start_suppressed",
                fields: [
                    "route": route,
                    "instruction": instruction,
                    "ageMs": Int(now.timeIntervalSince(previousStart) * 1000),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            return
        }
        lastVoiceAgentStartFingerprint = startFingerprint
        lastVoiceAgentStartAt = now

        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "instructionLength": instruction.count
            ]
        )
        if interruptVoiceResponse {
            interruptCurrentVoiceResponse()
        }
        ensureCursorOverlayVisibleForAgentTask()

        let dockItemID = UUID()
        // Keep the spoken handoff intentionally generic. The dock still gets
        // the compact task title, but voice should not read the task name
        // back when launching an agent.
        let acknowledgement = acknowledgement ?? Self.acknowledgementForAgentInstruction(instruction)
        let dockScreen = agentDockTargetScreen()
        let voiceContextTranscript = voiceContextUserTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceContextUserTranscript = (voiceContextTranscript?.isEmpty == false)
            ? voiceContextTranscript!
            : instruction

        if speakAcknowledgement {
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: "OpenClicky Agent"
            )
            rememberVoiceExchange(
                userTranscript: voiceContextUserTranscript,
                assistantResponse: acknowledgement,
                reason: "agent_start"
            )
        } else {
            rememberSilentAgentHandoff(
                userTranscript: voiceContextUserTranscript,
                instruction: instruction,
                reason: "agent_start_silent"
            )
        }

        // Spawn the dock representation while the live OpenClicky buddy makes
        // a short handoff flight to the corner and then returns to the user's
        // cursor, so the task start feels intentional without leaving the
        // working position abandoned.
        clearDetectedElementLocation()

        Task { @MainActor in
            let accentTheme = Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
            let agentSession = createAndSelectNewCodexAgentSession(
                title: Self.shortAgentInstructionSummary(instruction),
                accentTheme: accentTheme
            )
            if let timing {
                agentRequestTimingsBySessionID[agentSession.id] = timing
            }
            lastVoiceAgentStartSessionID = agentSession.id
            agentExecutionStartDatesBySessionID[agentSession.id] = executionStartedAt
            agentSessionsStartedThisLaunch.insert(agentSession.id)
            let dockItem = ClickyAgentDockItem(
                id: dockItemID,
                sessionID: agentSession.id,
                title: Self.shortAgentInstructionSummary(instruction),
                userInstruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                accentTheme: accentTheme,
                status: .starting,
                progressStageLabel: "Starting",
                progressStepText: acknowledgement,
                activityStatusLines: [acknowledgement],
                caption: acknowledgement,
                suggestedNextActions: [],
                createdAt: Date()
            )

            agentDockItems.append(dockItem)
            if agentDockItems.count > 6 {
                agentDockItems.removeFirst(agentDockItems.count - 6)
            }
            refreshAgentDockFollowBehavior()
            scheduleStatusSync()
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_task.created",
                fields: [
                    "executor": "agent_mode",
                    "executionMethod": "CodexAgentSession.submitPromptFromUI",
                    "controller": "CodexAgentSession",
                    "model": agentSession.model,
                    "sessionID": agentSession.id.uuidString,
                    "title": agentSession.title,
                    "instruction": instruction,
                    "requestID": timing?.requestID ?? "none",
                    "spawnChoreography": "cursor_to_dock_and_back",
                    "spokenAcknowledgement": speakAcknowledgement
                ]
            )
            markRequestStageCompleted(
                route: route,
                stage: "agent_created",
                stageStartedAt: executionStartedAt,
                timing: timing,
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "createAndSelectNewCodexAgentSession",
                    "controller": "CompanionManager",
                    "model": agentSession.model,
                    "sessionID": agentSession.id.uuidString,
                    "title": agentSession.title,
                    "spawnChoreography": "cursor_to_dock_and_back",
                    "spokenAcknowledgement": speakAcknowledgement
                ]
            )

            if let dockScreen {
                agentDockWindowManager.show(
                    companionManager: self,
                    onScreen: dockScreen,
                    position: agentParkingPosition
                )
            } else {
                showAgentDockWindowNearCurrentScreen()
            }
            animateAgentSpawnProxyFromCursorToDock(accentTheme: accentTheme, dockItemID: dockItem.id)
            submitAgentPrompt(
                instruction,
                to: agentSession,
                includeScreenContext: Self.shouldAttachScreenContext(to: instruction)
                    || pendingCircleSelectStroke != nil,
                attachPendingVoiceCircle: true
            )

            guard speakAcknowledgement else { return }
            beginCursorReplyPresentation()
            updateVoiceResponseCaption("<cursor_reply>" + acknowledgement + "</cursor_reply>", force: true, updatesDock: false)
        }
    }

    static func voiceAgentStartFingerprint(instruction: String, route: String) -> String {
        let normalizedInstruction = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRoute = route
            .replacingOccurrences(of: #"\.split$"#, with: "", options: .regularExpression)
        return "\(normalizedRoute)|\(normalizedInstruction)"
    }

    /// Every submitted cursor request presents a real app-owned pointer/reply immediately.
    func beginCursorReplyPresentation() {
        clearDetectedElementLocation()
        cursorOverlayState.replyPointerIsPinned = true
        cursorOverlayState.replyHasVerifiedTarget = false
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screen(containingOrNearestTo: mouse) {
            let frame = screen.visibleFrame
            let anchor = CGPoint(x: min(max(mouse.x + 35, frame.minX + 20), frame.maxX - 20),
                                 y: min(max(mouse.y - 25, frame.minY + 20), frame.maxY - 20))
            detectedElementDisplayFrame = screen.frame
            detectedElementScreenLocation = anchor
            cursorOverlayState.aiPointerScreenLocation = anchor
        }
        showCursorOverlayIfAvailable()
        responseOverlayManager.beginNewReply()
        updateVoiceResponseCaption("<cursor_reply>Working…</cursor_reply>", force: true, updatesDock: false)
    }

    func ensureCursorOverlayVisibleForAgentTask() {
        showCursorOverlayIfAvailable()
    }

    func showCursorOverlayIfAvailable() {
        guard hasAccessibilityPermission else { return }
        guard !isOverlayVisible || !overlayWindowManager.isShowingOverlay() else {
            overlayWindowManager.reassertOverlayWindows()
            return
        }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func cancelPendingAgentDockItemRemoval(for sessionID: UUID) {
        pendingAgentDockItemRemovalTasks[sessionID]?.cancel()
        pendingAgentDockItemRemovalTasks.removeValue(forKey: sessionID)
    }

    func scheduleAgentDockItemRemoval(for sessionID: UUID, delay: TimeInterval? = nil) {
        cancelPendingAgentDockItemRemoval(for: sessionID)
        guard agentDockItems.contains(where: { $0.sessionID == sessionID }) else { return }

        let effectiveDelay = delay ?? cancelledDockItemHoldDuration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.agentDockItems.removeAll { $0.sessionID == sessionID }
            if self.agentDockItems.isEmpty {
                self.agentDockWindowManager.hide()
            }
            self.pendingAgentDockItemRemovalTasks[sessionID] = nil
            self.refreshAgentDockFollowBehavior()
            self.scheduleStatusSync()
        }
        pendingAgentDockItemRemovalTasks[sessionID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: workItem)
    }

    static func shortAgentInstructionSummary(_ instruction: String) -> String {
        var title = instruction
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'.,:;!?-–—[](){}<>"))

        if isRawTransportDiagnosticEvent(instruction) {
            return "Runtime Event Filter"
        }

        let directTitleRules: [(pattern: String, title: String)] = [
            (#"(?i)\b(?:see\s+(?:the\s+)?issue\s+here|look\s+at\s+this|fix\s+this)\b.*\b(?:OpenClickyLog|NSXPCDecoder|ViewBridge|unifiedReasons|NSXPCConnection|agent_sdk_query|_sdk_query|kDragIPC|Reentrant\s+message)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:OpenClickyLog|NSXPCDecoder|NSXPCInterface|NSXPCConnection|ViewBridge|NSViewBridgeError|Unable to obtain a task name port right|nw_protocol_instance|nw_read_request_report|unifiedReasons|agent_sdk_query|_sdk_query|Bridge SDK Message|kDragIPC|Reentrant\s+message)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:lozenge|pill|caption|label)\b.*\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b.*\b(?:lozenge|pill|caption|label)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:whole|full)\s+(?:task\s+)?names?\b"#, "Task Status Wording"),
            (#"(?i)\bshort\s+(?:version|task\s+name|name)\b"#, "Task Status Wording"),
            (#"(?i)\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b.*\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b.*\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:short|compact)\s+(?:version|label|title|name)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:proper|better|concise|short|compact)\s+(?:task\s+)?titles?\b"#, "Task Title Cleanup"),
            (#"(?i)\btask\s+titles?\b.*\b(?:read(?:ing)?\s+out|raw|asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:read(?:ing)?\s+out|raw)\b.*\b(?:asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b"#, "Task Title Stability"),
            (#"(?i)\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Stability")
        ]
        for rule in directTitleRules where title.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.title
        }

        let attachmentPathPatterns = [
            #"(?i)^/.*?\.(?:png|jpe?g|jpeg|heic|webp|gif|pdf|mov|mp4|m4v)\b"#,
            #"(?i)(?:^|\s)/(?:Users|var|tmp|private|Applications|Volumes)/\S+"#
        ]
        for pattern in attachmentPathPatterns {
            title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let fillerPatterns = [
            #"(?i)^hey\s+(?:clicky\s+)?agent[,\s]+"#,
            #"(?i)^clicky\s+agent[,\s]+"#,
            #"(?i)^(?:can|could|would)\s+you\s+"#,
            #"(?i)^(?:please\s+)?(?:help\s+me\s+)?(?:do|make|handle|sort|take\s+care\s+of)\s+"#,
            #"(?i)^the\s+(?:updates?|changes?)\s+(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:to|for|about)\s+"#
        ]
        for pattern in fillerPatterns {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        title = title.replacingOccurrences(
            of: #"(?i)\b(?:please|just|maybe|basically|actually|kind\s+of|sort\s+of|you\s+know|everything\s+else)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:can\s+you|could\s+you|would\s+you|we(?:'|’)ve|we\s+have|we\s+were|talking\s+about)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:so\s+that|and\s+then|which\s+is\s+to|that\s+you)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:shorten|remove|make|making|sound|sounding|turn|change|update|fix|clean\s+up)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:the|a|an|this|that|it|them|you|your|then|also|with|from|into|and|or|but|for|of|to|in|on|as|is|are|be|have|has|had|asked)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:find|out|why|when|sure|use|uses?|using|start|starts|started|starting|speak|speaks|speaking|say|says|saying|read|reads|reading|whole|full|long|name|version|words?|thing|stuff|phrases?|responses?)\b"#,
            with: " ",
            options: .regularExpression
        )

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return word.count > 1 || word.rangeOfCharacter(from: .decimalDigits) != nil
            }
            .prefix(5)

        let cleaned = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "Agent Task" }
        guard cleaned.count > 44 else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: 44)
        let prefix = String(cleaned[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the spoken/displayed acknowledgement for a freshly invoked
    /// agent task. Keep it generic so OpenClicky does not speak the task
    /// name back to the user; the compact title remains visual-only in the
    /// dock and task history.
    static func acknowledgementForAgentInstruction(_ _: String) -> String {
        "got it — i’ll get on with that in the background."
    }

    /// Record silent/hybrid agent launches as real voice context so the
    /// primary voice conversation can answer follow-ups like “what were we
    /// talking about?” and “get an agent on it” without losing the topic.
    static func agentHandoffVoiceContextResponse(instruction: String) -> String {
        let snippet = voiceArchiveSnippet(instruction, limit: 180)
        return "OpenClicky started a background agent for: \(snippet). Keep this as part of the current voice conversation context."
    }

    /// Every task uses the user's pointer color; the Tasks menu tells tasks apart by title and status.
    static func nextAgentDockAccentTheme(existingCount _: Int) -> ClickyAccentTheme {
        .current
    }

    func updateAgentDockItem(for sessionID: UUID, status: CodexAgentSessionStatus) {
        defer { refreshCursorAgentTaskLabel() }

        guard let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == sessionID }) else { return }
        let session = codexAgentSessions.first(where: { $0.id == sessionID })
        let activitySummary = session?.latestActivitySummary
        let activityDisplaySummary = session?.latestActivityDisplaySummary ?? activitySummary
        let stageLabel = session?.progressStage.label ?? (status == .starting ? "Starting" : "Working")
        let suggestedNextActions = session?.latestResponseCard?.suggestedNextActions ?? []
        let activityStatusLines = Self.agentDockActivityStatusLines(for: session, fallback: activitySummary)
        let responseDisplaySummary = Self.agentDockResponseDisplaySummary(for: session)
        let displayActivity = responseDisplaySummary ?? activityDisplaySummary ?? activityStatusLines.last ?? activitySummary
        let trimmedActivitySummary = displayActivity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasActivitySummary = trimmedActivitySummary?.isEmpty == false

        agentDockItems[itemIndex].progressStageLabel = stageLabel
        agentDockItems[itemIndex].progressStepText = hasActivitySummary ? trimmedActivitySummary : nil
        agentDockItems[itemIndex].activityStatusLines = activityStatusLines
        agentDockItems[itemIndex].suggestedNextActions = suggestedNextActions

        switch status {
        case .starting:
            agentDockItems[itemIndex].status = .starting
            // Only overwrite the caption when we actually have real assistant
            // activity. Otherwise preserve the existing caption (the user's
            // acknowledgement message) instead of replacing it with the
            // generic "An agent is getting ready." placeholder. When neither
            // is present, leave caption nil so the view can render its own
            // streaming "thinking" affordance.
            if let displayActivity, hasActivitySummary {
                agentDockItems[itemIndex].caption = displayActivity
            }
        case .running:
            agentDockItems[itemIndex].status = .running
            // Same rationale as .starting — never replace the caption with
            // "An agent is working on this." Leave nil to surface the
            // animated thinking indicator until real tokens stream in.
            if let displayActivity, hasActivitySummary {
                agentDockItems[itemIndex].caption = displayActivity
            }
        case .ready:
            // Codex briefly reports `.ready` after thread startup and before
            // the actual turn starts. Do not turn that preflight ready state
            // into "done"; assigning/queueing an agent is not task completion.
            let isCompletedTurn = session?.progressStage == .completed || responseDisplaySummary != nil
            guard isCompletedTurn else {
                // Preflight ready, even with the acknowledgement/activity text
                // we seeded at assignment time, should stay visibly queued or
                // working until a real completed turn arrives.
                return
            }
            if agentDockItems[itemIndex].status == .running
                || agentDockItems[itemIndex].status == .starting
                || (agentDockItems[itemIndex].status == .failed && isCompletedTurn) {
                agentDockItems[itemIndex].status = .done
                agentDockItems[itemIndex].caption = "The agent has completed the task — \(displayActivity ?? activitySummary ?? "open the agent for details")"
                agentDockItems[itemIndex].progressStageLabel = "Completed"
                agentDockItems[itemIndex].progressStepText = displayActivity ?? activitySummary
            }
            completeAgentRequestTimingIfNeeded(sessionID: sessionID, status: "success")
            let completionSpeechSummary = Self.completionSpeechSummary(for: session, fallback: activitySummary)
            announceAgentCompletionIfNeeded(sessionID: sessionID, outcome: "success", summary: completionSpeechSummary)
        case .failed:
            agentDockItems[itemIndex].status = .failed
            agentDockItems[itemIndex].caption = activityDisplaySummary ?? "The agent stopped. Open the agent for details."
            agentDockItems[itemIndex].progressStageLabel = "Stopped"
            agentDockItems[itemIndex].progressStepText = activityDisplaySummary ?? activitySummary
            completeAgentRequestTimingIfNeeded(
                sessionID: sessionID,
                status: "failed",
                extra: [
                    "activitySummary": activitySummary ?? ""
                ]
            )
            let completionSpeechSummary = Self.completionSpeechSummary(for: session, fallback: activitySummary)
            announceAgentCompletionIfNeeded(sessionID: sessionID, outcome: "failed", summary: completionSpeechSummary)
        case .stopped:
            if session?.status != .stopped {
                break
            }
            let stopReason = session?.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasExplicitStopReason = stopReason?.isEmpty == false
            if agentDockItems[itemIndex].status == .starting,
               !hasExplicitStopReason {
                // New sessions publish their initial `.stopped` value once
                // the Combine observer is attached. That delivery can arrive
                // after the prompt has been queued, so `hasVisibleActivity`
                // is already true even though the agent has not actually
                // stopped. Do not convert that preflight value into an
                // immediate cancellation; wait for `.starting` / `.running`,
                // or for an explicit stop reason from a real stop action.
                break
            }
            let normalizedStopReason = stopReason?.isEmpty == false ? (stopReason ?? "") : "session_stopped"
            agentDockItems[itemIndex].status = .failed
            if let summary = activitySummary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                agentDockItems[itemIndex].caption = "Cancelled while: \(summary)"
                agentDockItems[itemIndex].progressStepText = summary
            } else {
                agentDockItems[itemIndex].caption = "The agent was cancelled (\(Self.prettyCancelReason(for: normalizedStopReason)))."
                agentDockItems[itemIndex].progressStepText = Self.prettyCancelReason(for: normalizedStopReason)
            }
            agentDockItems[itemIndex].progressStageLabel = "Stopped"
            completeAgentRequestTimingIfNeeded(
                sessionID: sessionID,
                status: "cancelled",
                extra: [
                    "activitySummary": activitySummary ?? "",
                    "cancelledAt": Date().ISO8601Format(),
                    "cancelReason": normalizedStopReason
                ]
            )
            announceAgentCompletionIfNeeded(
                sessionID: sessionID,
                outcome: "cancelled",
                summary: Self.prettyCancelReason(for: normalizedStopReason),
                cancelReason: normalizedStopReason
            )
            break
        }
        scheduleStatusSync()
    }

    static func agentDockActivityStatusLines(for session: CodexAgentSession?, fallback: String?) -> [String] {
        var lines: [String] = []
        for line in session?.activityStatusLines ?? [] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lines.last != trimmed {
                lines.append(trimmed)
            }
        }
        if let fallback {
            let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFallback.isEmpty, lines.last != trimmedFallback {
                lines.append(trimmedFallback)
            }
        }
        return Array(lines.suffix(8))
    }

    static func agentDockResponseDisplaySummary(for session: CodexAgentSession?) -> String? {
        guard let raw = session?.latestResponseCard?.rawText else { return nil }
        let displayText = ClickyResponseCard.sanitizedDisplayText(from: raw, maximumCharacters: 1_200)
            .replacingOccurrences(
                of: #"(?im)^\s*TASK_TITLE\s*:\s*.*$"#,
                with: " ",
                options: .regularExpression
            )
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return displayText.isEmpty ? nil : displayText
    }

    func refreshCursorAgentTaskLabel() {
        guard let item = agentDockItems.reversed().first(where: { dockItem in
            dockItem.status == .starting || dockItem.status == .running
        }) else {
            clearAgentTaskBubbleText()
            return
        }

        let session = item.sessionID.flatMap { sessionID in
            codexAgentSessions.first(where: { $0.id == sessionID })
        }
        let nextLabel = Self.cursorAgentTaskLabel(for: item, session: session)
        guard !nextLabel.isEmpty else {
            clearAgentTaskBubbleText()
            return
        }

        cursorOverlayState.agentTaskBubbleText = nextLabel
        scheduleAgentTaskBubbleClear(matching: nextLabel)
    }

    func clearAgentTaskBubbleText() {
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = nil
        cursorOverlayState.agentTaskBubbleText = nil
    }

    func scheduleAgentTaskBubbleClear(matching label: String, after delay: TimeInterval = 3.0) {
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self, self.cursorOverlayState.agentTaskBubbleText == label else { return }
                self.cursorOverlayState.agentTaskBubbleText = nil
                self.agentTaskBubbleClearTask = nil
            }
        }
    }

    static func cursorAgentTaskLabel(for item: ClickyAgentDockItem, session: CodexAgentSession?) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Agent task" : title
        let stageLabel = session?.progressStage.label ?? (item.status == .starting ? "Starting" : "Working")

        // The cursor bubble is only a transient cue; the dock/HUD owns detailed progress.
        // Keeping it title-based prevents long streamed status lines from wrapping into
        // clipped, ellipsis-heavy captions beside the cursor.
        return shortCursorAgentTaskLabel("\(stageLabel): \(fallbackTitle)")
    }

    static func shortCursorAgentTaskLabel(_ text: String) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let maxCharacters = 64
        guard flattened.count > maxCharacters else { return flattened }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxCharacters)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func completeAgentRequestTimingIfNeeded(
        sessionID: UUID,
        status: String,
        extra: [String: Any] = [:]
    ) {
        let timing = agentRequestTimingsBySessionID.removeValue(forKey: sessionID)
        let executionStartedAt = agentExecutionStartDatesBySessionID.removeValue(forKey: sessionID)
        // Drop the dedup signature for terminal sessions so the map can't
        // grow without bound across long-running OpenClicky sessions.
        lastAgentProgressNarrationSignatures.removeValue(forKey: sessionID)
        guard timing != nil || executionStartedAt != nil else { return }

        var fields = extra
        if status == "cancelled" {
            if fields["cancelledAt"] == nil {
                fields["cancelledAt"] = Date().ISO8601Format()
            }
            if fields["cancelReason"] == nil,
               let stoppedSession = codexAgentSessions.first(where: { $0.id == sessionID })?.stopReason,
               !stoppedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["cancelReason"] = stoppedSession
            }
            fields["executionMethod"] = "CodexAgentSession.status"
            fields["executionStatus"] = "cancelled"
        }

        fields["sessionID"] = sessionID.uuidString
        fields["executor"] = "agent_mode"
        fields["executionMethod"] = fields["executionMethod"] as? String ?? "CodexAgentSession.status"
        fields["controller"] = "CodexAgentSession"
        markRequestCompleted(
            route: "agent.start",
            executionStartedAt: executionStartedAt,
            timing: timing,
            status: status,
            extra: fields
        )
    }

    /// Speaks a short completion line the first time a delegated agent
    /// reaches a terminal outcome. Suppresses duplicate announcements
    /// when Combine republishes, and avoids stepping on a voice response
    /// that's already mid-flight.
    func announceAgentCompletionIfNeeded(
        sessionID: UUID,
        outcome: String,
        summary: String?,
        cancelReason: String? = nil
    ) {
        if lastNarratedAgentOutcomeBySessionID[sessionID] == outcome { return }
        lastNarratedAgentOutcomeBySessionID[sessionID] = outcome

        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
        let taskTitle = Self.agentCompletionSpokenTaskTitle(for: session)

        // User-initiated cancellation: the user just clicked Stop / said
        // "cancel" — they already know what happened. Don't narrate it back.
        // Only system-initiated cancellations get spoken/notified (those would
        // otherwise be invisible to the user).
        if outcome == "cancelled", Self.isUserInitiatedCancelReason(cancelReason) {
            return
        }

        let trimmedSummary = summary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line: String
        switch outcome {
        case "cancelled":
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) was cancelled"
                : "\(taskTitle) was cancelled: \(Self.briefCompletionSummary(trimmedSummary))"
        case "failed":
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) stopped"
                : "\(taskTitle) stopped: \(Self.briefCompletionSummary(trimmedSummary))"
        default:
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) is done"
                : "\(taskTitle) is done: \(Self.briefCompletionSummary(trimmedSummary))"
        }

        let notificationTitle: String
        switch outcome {
        case "cancelled": notificationTitle = "OpenClicky task cancelled"
        case "failed": notificationTitle = "OpenClicky task stopped"
        default: notificationTitle = "OpenClicky task done"
        }
        OpenClickyDesktopNotificationCenter.shared.post(
            title: notificationTitle,
            body: line,
            threadID: "openclicky.agent.\(sessionID.uuidString)",
            playSound: outcome == "success",
            userInfo: [
                "source": "agent_completion",
                "sessionID": sessionID.uuidString,
                "outcome": outcome
            ]
        )

        // Spoken replies are muted by default and notifications can be off, so show the result by the pointer
        // unless an answer is on screen right now.
        if currentResponseTask == nil, outcome != "cancelled", agentSessionsStartedThisLaunch.contains(sessionID) {
            beginCursorReplyPresentation()
            updateVoiceResponseCaption("<cursor_reply>" + line + "</cursor_reply>", force: true, updatesDock: false)
        }

        guard AppBundleConfiguration.agentCompletionVoiceEnabled() else { return }

        // Skip narration if the user is mid-conversation with the voice
        // responder — the dock item still updates visually, and the desktop
        // notification now carries the update without talking over them.
        if voiceState == .listening { return }

        // Sequence behind any in-flight TTS or voice capture instead of
        // cutting in. The queued path is important: an agent can finish
        // while the user has already started the next push-to-talk turn,
        // and completion speech must not feed back into the microphone.
        // Previously this called `showShortSystemResponse(line)` directly,
        // whose `interruptCurrentVoiceResponse()` would chop the
        // acknowledgement TTS mid-sentence when fast tasks completed
        // before the acknowledgement finished playing. Now we wait for
        // the audio device to go idle, then play the chime (success
        // only), then speak the announcement — so the success line is
        // always heard, never elided, and never overlaps prior audio.
        let playChime = (outcome == "success")
        speakSystemAnnouncementAfterCurrentTTS(line, for: sessionID, withChime: playChime)
    }

    static func agentCompletionSpokenTaskTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "Agent" else {
            return "the agent task"
        }
        return title
    }

    /// Queue a system announcement to play *after* any currently-playing
    /// TTS finishes. Polls `voiceTTSClient.isPlaying` rather than awaiting
    /// a Task, because the relevant signal is "audio device idle", not
    /// "Swift Task completed" — TTS playback can outlive its dispatching
    /// task by a few hundred milliseconds while audio buffers drain.
    ///
    /// When `withChime` is true, the agent-done chime is played first,
    /// followed by a settle gap, then the announcement. This is how
    /// success completion announces — chime, then the spoken summary.
    /// Play an agent-completion announcement. Chime first (if requested),
    /// then the spoken line. Anything currently playing is cut so the
    /// chime never overlaps speech and never gets cut by speech.
    func speakSystemAnnouncementAfterCurrentTTS(
        _ line: String,
        for sessionID: UUID?,
        withChime: Bool = false
    ) {
        let previousTask = pendingSystemAnnouncementTask
        pendingSystemAnnouncementSessionID = sessionID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousTask {
                _ = await previousTask.result
            }
            if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
            if Task.isCancelled { return }
            guard await self.waitForSystemAnnouncementSlot(sessionID: sessionID) else { return }
            if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
            if withChime {
                let chimeDuration = self.playAgentDoneChime()
                let settleSeconds = max(0.12, chimeDuration + 0.08)
                try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
                guard await self.waitForSystemAnnouncementSlot(sessionID: sessionID) else { return }
            }
            self.speakingSystemAnnouncementSessionID = sessionID
            self.showShortSystemResponse(line, interruptExisting: false)
            await self.waitForVoicePlaybackToIdle()
            if self.speakingSystemAnnouncementSessionID == sessionID {
                self.speakingSystemAnnouncementSessionID = nil
            }
            if self.pendingSystemAnnouncementSessionID == sessionID {
                self.pendingSystemAnnouncementTask = nil
                self.pendingSystemAnnouncementSessionID = nil
            }
        }
        pendingSystemAnnouncementTask = task
    }

    func silenceAgentSpeech(for sessionID: UUID, reason: String) {
        var didSilenceSpeech = false
        silencedAgentSpeechSessionIDs.insert(sessionID)
        if pendingSystemAnnouncementSessionID == sessionID {
            pendingSystemAnnouncementTask?.cancel()
            pendingSystemAnnouncementTask = nil
            pendingSystemAnnouncementSessionID = nil
            didSilenceSpeech = true
        }
        if speakingSystemAnnouncementSessionID == sessionID {
            interruptCurrentVoiceResponse()
            speakingSystemAnnouncementSessionID = nil
            didSilenceSpeech = true
        }
        guard didSilenceSpeech else { return }
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.speech_silenced",
            fields: [
                "sessionID": sessionID.uuidString,
                "reason": reason
            ]
        )
    }

    @MainActor
    func waitForVoicePlaybackToIdle(maxWaitSeconds: TimeInterval = 8.0) async {
        let start = Date()
        while voiceState == .responding {
            if Task.isCancelled { return }
            if Date().timeIntervalSince(start) >= maxWaitSeconds { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func waitForSystemAnnouncementSlot(
        sessionID: UUID?,
        maxWaitSeconds: TimeInterval = 30.0
    ) async -> Bool {
        let start = Date()
        while systemAnnouncementAudioWouldCollideWithVoiceInput {
            if Task.isCancelled { return false }
            if let sessionID, silencedAgentSpeechSessionIDs.contains(sessionID) { return false }
            if Date().timeIntervalSince(start) >= maxWaitSeconds {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "internal",
                    event: "openclicky.agent_completion.speech_deferred_timeout",
                    fields: [
                        "sessionID": sessionID?.uuidString ?? "",
                        "voiceState": String(describing: voiceState),
                        "dictationInProgress": buddyDictationManager.isDictationInProgress,
                        "dictationActive": buddyDictationManager.isDictationInProgress
                    ]
                )
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    @MainActor
    var systemAnnouncementAudioWouldCollideWithVoiceInput: Bool {
        if buddyDictationManager.isDictationInProgress { return true }
        switch voiceState {
        case .listening, .processing, .responding:
            return true
        case .idle:
            return false
        }
    }

    /// Play the bundled "agent-done" chime via NSSound on a system
    /// audio channel separate from TTS. Caller is responsible for
    /// timing this so it doesn't overlap in-flight TTS.
    @discardableResult
    func playAgentDoneChime() -> TimeInterval {
        guard let url = Bundle.main.url(forResource: "agent-done", withExtension: "mp3") else {
            return 0.55
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            return 0.55
        }
        sound.play()
        return sound.duration > 0 ? sound.duration : 0.55
    }

    /// Trims an agent activity summary to a sentence-length spoken line.
    /// Activity summaries can be multi-line tool output; we want one
    /// short clause for TTS.
    static func prettyCancelReason(for reason: String) -> String {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "", "unknown", "session_stopped":
            return "session was stopped"
        case "agent.cancel_current", "agent.cancel":
            return "the user requested cancellation"
        case "agent.cancel_all":
            return "all agents were cancelled"
        case "agent_dock_stop":
            return "dock stop"
        case "response_card_dismissed":
            return "response card dismissed"
        case "api_key_reconfigured":
            return "API configuration changed"
        case "model_changed":
            return "model changed"
        default:
            return reason
        }
    }

    /// Whether a cancellation reason was *initiated by the user* (Stop
    /// click, "cancel" voice command, dismiss response card). Those
    /// cancellations should be silent — the user already knows. Only
    /// system-initiated cancellations (API key changed, model changed,
    /// session externally stopped with no other context) get spoken.
    static func isUserInitiatedCancelReason(_ reason: String?) -> Bool {
        guard let reason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !reason.isEmpty else {
            return false
        }
        switch reason {
        case "agent_dock_stop",
             "agent.cancel",
             "agent.cancel_current",
             "agent.cancel_all",
             "response_card_dismissed":
            return true
        case "api_key_reconfigured",
             "model_changed",
             "session_stopped",
             "unknown":
            return false
        default:
            // For anything else, default to "system" — user-initiated
            // reasons are explicit and known. Unknown reasons get a
            // narration so the user can find out what happened.
            return false
        }
    }

    static func briefCompletionSummary(_ summary: String) -> String {
        cleanedNaturalSpeech(summary, maxLength: 180)
    }

    /// For completion TTS, use a short cleaned final-response summary after
    /// the compact task title. Do not read the whole task or result aloud.
    static func completionSpeechSummary(
        for session: CodexAgentSession?,
        fallback: String?
    ) -> String? {
        if let raw = session?.latestResponseCard?.rawText {
            var text = ClickyResponseCard.sanitizedDisplayText(from: raw, maximumCharacters: 10_000)
            text = text.replacingOccurrences(
                of: #"(?im)^\s*TASK_TITLE\s*:\s*.*$"#,
                with: " ",
                options: .regularExpression
            )
            text = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let maxSpokenLength = 180
                let cleaned = cleanedNaturalSpeech(text, maxLength: maxSpokenLength)
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "outgoing",
                    event: "openclicky.agent_completion.speech_budget",
                    fields: [
                        "rawLength": raw.count,
                        "sanitizedLength": text.count,
                        "spokenLength": cleaned.count,
                        "maxLength": maxSpokenLength
                    ]
                )
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        if let fallback {
            let maxSpokenLength = 180
            let cleaned = cleanedNaturalSpeech(fallback, maxLength: maxSpokenLength)
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_completion.speech_budget",
                fields: [
                    "rawLength": fallback.count,
                    "sanitizedLength": fallback.count,
                    "spokenLength": cleaned.count,
                    "maxLength": maxSpokenLength,
                    "source": "fallback"
                ]
            )
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// Sanitizes assistant text into short, natural spoken English for TTS.
    /// Removes paths/filenames and punctuation-heavy fragments that sound
    /// robotic when read aloud.
    static func cleanedNaturalSpeech(_ text: String, maxLength: Int) -> String {
        var value = text
        value = trimmedCompletionSpeechBeforeTechnicalTail(value)
        value = value.replacingOccurrences(
            of: #"(?is)\s+(?:in|at|under|inside)\s+`?(?:/Users|/Volumes|~)/[^\s,;:()\[\]{}<>"]+`?"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"(?i)\b(?:/Users|/Volumes|~)/[^\s,;:()\[\]{}<>"]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b\S+\.(swift|md|json|jsonl|toml|yaml|yml|txt|csv|ts|tsx|js|jsx|py|sh)\b"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)
        value = Self.naturallyBoundedCompletionSpeech(value, maxLength: maxLength)
        value = value.replacingOccurrences(of: #"[#*_>\[\]\(\)\{\}:;|\\/]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[-–—]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[.!?,]+"#, with: " ", options: .regularExpression)
        value = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard value.count > maxLength else { return value }
        let endIndex = value.index(value.startIndex, offsetBy: maxLength)
        let prefix = String(value[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps spoken task-completion summaries from sounding like the
    /// audio was cut off. Prefer a real sentence boundary; when the
    /// only available text is long, end with a deliberate handoff to
    /// the on-screen task transcript instead of stopping mid-thought.
    static func naturallyBoundedCompletionSpeech(_ text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxLength else { return flattened }

        let limitIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<limitIndex])
        let minimumBoundary = flattened.index(
            flattened.startIndex,
            offsetBy: min(70, max(0, flattened.count - 1))
        )
        if let sentenceBreak = prefix.lastIndex(where: { ".!?".contains($0) }),
           sentenceBreak >= minimumBoundary {
            return String(prefix[...sentenceBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let suffix = " Details are in the task."
        let allowedPrefixLength = max(40, maxLength - suffix.count)
        let allowedIndex = prefix.index(prefix.startIndex, offsetBy: min(prefix.count, allowedPrefixLength))
        let boundedPrefix = String(prefix[..<allowedIndex])
        if let lastComma = boundedPrefix.lastIndex(where: { ",;".contains($0) }),
           lastComma > boundedPrefix.startIndex {
            return String(boundedPrefix[..<lastComma]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
        }
        if let lastSpace = boundedPrefix.lastIndex(of: " "), lastSpace > boundedPrefix.startIndex {
            return String(boundedPrefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
        }
        return boundedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    /// Agent final replies often include useful transcript detail like
    /// "Verified with `swiftc -parse` and `git diff --check`". That is good
    /// on-screen, but TTS used to read up to "verified with" and then lose the
    /// code-like command names. Stop before those verification tails so the
    /// spoken completion stays natural.
    static func trimmedCompletionSpeechBeforeTechnicalTail(_ text: String) -> String {
        var value = text
        let technicalTailPatterns = [
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?verified\s+(?:it\s+)?with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?verified\s+with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?(?:checked|tested)\s+(?:it\s+)?with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?verified\b[^.!?]*(?:swiftc|git\s+diff|diff\s+--check|xcodebuild|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#
        ]
        for pattern in technicalTailPatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
