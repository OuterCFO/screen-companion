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
    func openAgentDockItem(_ itemID: UUID) {
        if showCompactConversationForAgentDockItem(itemID) { return }
        guard isAdvancedModeEnabled else {
            prepareVoiceFollowUpForAgentDockItem(itemID)
            return
        }
        if let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID {
            selectCodexAgentSession(sessionID)
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_overlay.opened_selection_only",
                fields: [
                    "source": "agent_overlay_open",
                    "sessionID": sessionID.uuidString
                ]
            )
            showAgentTask(sessionID)
            return
        }
        showAgentTask(nil)
    }

    /// Opens an agent task's conversation in the compact panel, or the current compact task when none is given.
    func showAgentTask(_ sessionID: UUID?) {
        if let sessionID {
            selectCodexAgentSession(sessionID)
            if showCompactConversationForAgentDockItem(sessionID) { return }
        }
        showTutorConversation()
    }

    func closeAgentDockPanel() {
        agentDockWindowManager.hide()
    }

    func dismissAgentDockItem(_ itemID: UUID) {
        // The dock/menu "Archive" affordance should archive the underlying
        // task, not just hide its visual parked/menu item. Menu-bar task
        // items may be synthesized directly from Codex sessions, so their
        // item ID is the session ID and there may be no matching dock item.
        if let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID
            ?? codexAgentSessions.first(where: { $0.id == itemID })?.id {
            cancelPendingAgentDockItemRemoval(for: sessionID)
            archiveSession(sessionID, allowIncomplete: true)
            return
        }

        // Unsessioned completed cues are visual-only; remove those directly.
        agentDockItems.removeAll { $0.id == itemID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        scheduleStatusSync()
    }

    func stopAgentDockItem(_ itemID: UUID) {
        if let stoppedSessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID
            ?? codexAgentSessions.first(where: { $0.id == itemID })?.id {
            cancelAgentTask(sessionID: stoppedSessionID, removeDockItems: true, reason: "agent_dock_stop")
            lastNarratedAgentOutcomeBySessionID.removeValue(forKey: stoppedSessionID)
        } else {
            agentDockItems.removeAll { $0.id == itemID }
            if agentDockItems.isEmpty {
                agentDockWindowManager.hide()
            }
            scheduleStatusSync()
        }
    }

    func prepareVoiceFollowUpForAgentDockItem(_ itemID: UUID) {
        if itemID == tutorDockItemID { showTutorInput(startDictation: true); return }
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else {
            prepareForVoiceFollowUp()
            return
        }
        armVoiceFollowUpTarget(sessionID, source: "agent_overlay_voice_button")
        prepareForVoiceFollowUp()
    }

    func armVoiceFollowUpTarget(_ sessionID: UUID, source: String) {
        pendingAgentVoiceFollowUpSessionID = sessionID
        pendingAgentVoiceFollowUpCreatedAt = Date()
        pendingAgentVoiceFollowUpSource = source
        selectCodexAgentSession(sessionID)
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "internal",
            event: "openclicky.agent_followup.voice_target_armed",
            fields: [
                "source": source,
                "sessionID": sessionID.uuidString,
                "ttlSeconds": Int(Self.pendingAgentVoiceFollowUpTTL)
            ]
        )
    }

    func showTextFollowUpForAgentDockItem(_ itemID: UUID) {
        if itemID == tutorDockItemID { showTutorInput(startDictation: false); return }
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else { return }
        showTextFollowUpForAgentSession(sessionID)
    }

    func showTextFollowUpForAgentSession(_ sessionID: UUID) {
        selectCodexAgentSession(sessionID)
        showNotchTextInput { [weak self] submittedText in
            self?.submitTextFollowUp(submittedText, toAgentSessionID: sessionID)
        }
    }

    func beginAgentDockDrag() {
        agentDockWindowManager.beginDrag()
    }

    func dragAgentDock(by translation: CGSize) {
        agentDockWindowManager.drag(by: translation)
    }

    func endAgentDockDrag() {
        agentDockWindowManager.endDrag()
    }

    func submitTextFollowUp(_ submittedText: String, toAgentSessionID sessionID: UUID) {
        let trimmedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_followup.missing_session",
                fields: [
                    "source": "agent_text_followup",
                    "sessionID": sessionID.uuidString,
                    "instructionLength": trimmedText.count
                ]
            )
            return
        }
        let timing = beginRequestTiming(source: "agent_text_followup", text: trimmedText)
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedText.count
            ]
        )
        submitAgentPrompt(trimmedText, to: session)
        lastAgentContextSessionID = session.id
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
    }

    func attachDroppedAgentFiles(_ urls: [URL], toAgentDockItem itemID: UUID, source: String) {
        let standardizedURLs = urls
            .map(\.standardizedFileURL)
            .filter(\.isFileURL)
        guard !standardizedURLs.isEmpty else { return }
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID,
              let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_attachment_drop.missing_session",
                fields: [
                    "source": source,
                    "itemID": itemID.uuidString,
                    "attachmentCount": standardizedURLs.count
                ]
            )
            return
        }

        let prompt = Self.agentAttachmentPrompt(for: standardizedURLs)
        let timing = beginRequestTiming(source: source, text: prompt)
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
                "attachmentCount": standardizedURLs.count
            ]
        )

        selectCodexAgentSession(session.id)
        submitAgentPrompt(prompt, to: session)
        lastAgentContextSessionID = session.id

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
                "model": session.model,
                "attachmentCount": standardizedURLs.count
            ]
        )

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_attachment_drop.received",
            fields: [
                "source": source,
                "sessionID": session.id.uuidString,
                "attachmentCount": standardizedURLs.count
            ]
        )
    }

    static func agentAttachmentPrompt(for urls: [URL]) -> String {
        let attachmentLines = urls.enumerated().map { index, url in
            "\(index + 1). \(agentAttachmentKindLabel(for: url)): \(url.path)"
        }.joined(separator: "\n")

        return """
        Please review the attached file(s).

        OpenClicky dropped attachments:
        \(attachmentLines)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func agentAttachmentKindLabel(for url: URL) -> String {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased()) ? "Image" : "Document"
    }

    @discardableResult
    func submitNewAgentTaskFromUI(_ prompt: String, source: String = "agent_new_task_prompt") -> CodexAgentSession? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }
        var taskPrompt = trimmedPrompt
        if Self.isRawTransportDiagnosticEvent(trimmedPrompt) {
            // Typed/pasted prompts that mix user intent with log evidence
            // are real tasks; only refuse pure transport echo that yields
            // no analysis instruction.
            guard let logInstruction = Self.logEvidenceAnalysisInstruction(from: trimmedPrompt) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.raw_transport_event_ignored",
                    fields: [
                        "source": source,
                        "instructionPreview": Self.voiceArchiveSnippet(trimmedPrompt, limit: 240)
                    ]
                )
                showShortSystemResponse("that looks like an internal OpenClicky runtime event, not a task.")
                return nil
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.log_evidence_rescued",
                fields: [
                    "source": source,
                    "instructionPreview": Self.voiceArchiveSnippet(trimmedPrompt, limit: 240)
                ]
            )
            taskPrompt = logInstruction
        }

        let timing = beginRequestTiming(source: source, text: trimmedPrompt)
        activeRequestTiming = timing
        defer { activeRequestTiming = nil }

        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.new_task",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "instructionLength": trimmedPrompt.count
            ]
        )

        let launchPrompt = resolvedNewAgentTaskPrompt(from: taskPrompt)

        let session = createAndLaunchCodexAgentSession(
            title: Self.shortAgentInstructionSummary(launchPrompt),
            prompt: launchPrompt,
            includeScreenContext: Self.shouldAttachScreenContext(to: launchPrompt)
        )
        agentRequestTimingsBySessionID[session.id] = timing
        agentExecutionStartDatesBySessionID[session.id] = executionStartedAt
        agentSessionsStartedThisLaunch.insert(session.id)

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.created",
            fields: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "model": session.model,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instruction": launchPrompt,
                "originalInstruction": trimmedPrompt,
                "requestID": timing.requestID,
                "source": source
            ]
        )

        markRequestStageCompleted(
            route: "agent.new_task",
            stage: "agent_queued",
            stageStartedAt: executionStartedAt,
            timing: timing,
            status: "queued",
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        return session
    }

    func submitAgentPromptFromUI(_ prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let timing = beginRequestTiming(source: "agent_hud_prompt", text: trimmedPrompt)
        activeRequestTiming = timing
        defer { activeRequestTiming = nil }
        if handleAgentSelectionRequestIfNeeded(from: trimmedPrompt, source: "agent_hud_prompt") {
            return
        }

        if !Self.shouldSendAgentHUDPromptStraightToAgent(trimmedPrompt),
           handleDirectComputerUseRequest(from: trimmedPrompt, source: "agent_hud_prompt") {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_prompt.intercepted_native_cua",
                fields: [
                    "source": "agent_hud_prompt",
                    "instruction": trimmedPrompt,
                    "requestID": timing.requestID
                ]
            )
            return
        }

        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_hud_prompt",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "instructionLength": trimmedPrompt.count
            ]
        )
        if codexAgentSession.isTurnActiveForChatQueue {
            codexAgentSession.submitPromptFromUI(trimmedPrompt, screenContext: nil)
        } else {
            stageDashboardAgentSubmission(prompt: trimmedPrompt, session: codexAgentSession)
            submitAgentPrompt(trimmedPrompt, to: codexAgentSession)
        }
        markRequestStageCompleted(
            route: "agent.followup",
            stage: "prompt_queued",
            stageStartedAt: executionStartedAt,
            timing: timing,
            status: "queued",
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_hud_prompt",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "model": codexAgentSession.model
            ]
        )
    }

    static func shouldSendAgentHUDPromptStraightToAgent(_ prompt: String) -> Bool {
        let lineBreakCount = prompt.reduce(0) { partial, character in
            partial + (character.isNewline ? 1 : 0)
        }
        guard lineBreakCount > 0 else { return false }

        let normalized = prompt.lowercased()
        let pastedDiagnosticSignals = [
            "[openclickylog]",
            "openclicky:",
            "voice.realtime_bidirectional",
            "codex.rpc",
            "nw_read_request_report",
            "error domain=",
            "throwing -",
            "failed!"
        ]
        return pastedDiagnosticSignals.contains { normalized.contains($0) }
    }

    /// Keeps chat-driven turns aligned with the same corner-dock UX as
    /// voice starts: hoverable dock card and a quick buddy flight to the
    /// parking corner before returning to the user's cursor.
    func stageDashboardAgentSubmission(prompt: String, session: CodexAgentSession) {
        let summary = Self.shortAgentInstructionSummary(prompt)
        let activity = "Starting \(summary)"
        let screen = agentDockTargetScreen()
        clearDetectedElementLocation()

        let spawnAccentTheme: ClickyAccentTheme
        let spawnDockItemID: UUID
        if let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == session.id }) {
            agentDockItems[itemIndex].title = summary
            agentDockItems[itemIndex].userInstruction = prompt
            agentDockItems[itemIndex].status = .starting
            agentDockItems[itemIndex].progressStageLabel = "Starting"
            agentDockItems[itemIndex].progressStepText = activity
            agentDockItems[itemIndex].activityStatusLines = [activity]
            agentDockItems[itemIndex].caption = "on it."
            spawnAccentTheme = agentDockItems[itemIndex].accentTheme
            spawnDockItemID = agentDockItems[itemIndex].id
        } else {
            let accentTheme = Self.nextAgentDockAccentTheme(existingCount: agentDockItems.count)
            let dockItem = ClickyAgentDockItem(
                id: UUID(),
                sessionID: session.id,
                title: summary,
                userInstruction: prompt,
                accentTheme: accentTheme,
                status: .starting,
                progressStageLabel: "Starting",
                progressStepText: activity,
                activityStatusLines: [activity],
                caption: "on it.",
                suggestedNextActions: [],
                createdAt: Date()
            )
            agentDockItems.append(dockItem)
            if agentDockItems.count > 6 {
                agentDockItems.removeFirst(agentDockItems.count - 6)
            }
            spawnAccentTheme = accentTheme
            spawnDockItemID = dockItem.id
        }

        refreshAgentDockFollowBehavior()
        scheduleStatusSync()

        if let screen {
            agentDockWindowManager.show(
                companionManager: self,
                onScreen: screen,
                position: agentParkingPosition
            )
        } else {
            showAgentDockWindowNearCurrentScreen()
        }
        animateAgentSpawnProxyFromCursorToDock(accentTheme: spawnAccentTheme, dockItemID: spawnDockItemID)
    }

    func submitAgentPrompt(
        _ prompt: String,
        to session: CodexAgentSession,
        includeScreenContext: Bool = true,
        attachPendingVoiceCircle: Bool = false
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        lastAgentContextSessionID = session.id
        activeCodexAgentSessionID = session.id
        let baselinePasteboardChangeCount = NSPasteboard.general.changeCount
        let forceClipboardSelection = Self.shouldForceAgentClipboardSelection(for: trimmedPrompt)
        OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "agent_prompt")
        Task {
            // Agent allocation should not make the main OpenClicky panel feel
            // frozen. Stage the dock card synchronously, then let the run loop
            // render pending panel/window changes before screen-context capture
            // and Codex process startup begin.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))

            // A freehand selection is scoped to the voice turn that explicitly
            // requested it. Typed HUD and delayed background prompts must never
            // inherit a prior sensitive crop.
            if attachPendingVoiceCircle,
               includeScreenContext,
               handoffQueue.allSatisfy({ !$0.selection.hasFreehandPath }),
               let circleHandoff = await consumePendingCircleSelectHandoff(instruction: trimmedPrompt) {
                queueHandoffRegion(selection: circleHandoff.selection, imageData: circleHandoff.imageData)
            }

            let screenContext = includeScreenContext ? await prepareAgentScreenContextForNextTurn(
                minimumPasteboardChangeCount: baselinePasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ) : nil
            if !includeScreenContext {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "internal",
                    event: "openclicky.agent_screen_context.skipped",
                    fields: [
                        "reason": "text_only_agent_turn",
                        "sessionID": session.id.uuidString,
                        "instructionLength": trimmedPrompt.count
                    ]
                )
            }
            session.submitPromptFromUI(trimmedPrompt, screenContext: screenContext)
        }
    }

    func interruptCurrentVoiceResponse() {
        cursorOverlayState.replyPointerIsPinned = false
        currentVoiceResponseCancellationHandler?("interrupted")
        currentVoiceResponseCancellationHandler = nil
        currentVoiceResponseRequestID = nil
        currentVoiceResponseCompletionToken = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskToken = nil
        codexVoiceSession.cancelActiveTurn(reason: "voice_response_interrupted")
        clearVoiceResponseCaptionAndInteractiveBubble()
        if !buddyDictationManager.isDictationInProgress {
            currentAudioPowerLevel = 0
            voiceState = .idle
        }
    }

    func prepareAgentScreenContextForNextTurn(
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) async -> CodexAgentScreenContext? {
        // Drop stale circle-while-talking regions so an older hold cannot
        // leak into an unrelated agent turn.
        let circleHandoffMaxAge: TimeInterval = 45
        let now = Date()
        handoffQueue.removeAll { queued in
            queued.selection.hasFreehandPath
                && now.timeIntervalSince(queued.queuedAt) > circleHandoffMaxAge
        }

        if !handoffQueue.isEmpty {
            let queuedRegions = handoffQueue
            do {
                let context = try writeQueuedHandoffScreenContext(
                    queuedRegions,
                    minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                    forceClipboardSelection: forceClipboardSelection
                )
                handoffQueue.removeAll { queued in
                    queuedRegions.contains { $0.id == queued.id }
                }
                return context
            } catch {
                print("OpenClicky Agent Mode: failed to write queued screen context: \(error)")
            }
        }

        do {
            if selectedComputerUseBackend == .backgroundComputerUse {
                do {
                    let capture = try await backgroundComputerUseController.captureFrontmostWindowAsJPEG()
                    return try writeBackgroundComputerUseScreenContext(
                        capture,
                        minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                        forceClipboardSelection: forceClipboardSelection
                    )
                } catch {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "background_computer_use.screen_context_error",
                        fields: [
                            "backend": selectedComputerUseBackend.rawValue,
                            "error": error.localizedDescription,
                            "status": backgroundComputerUseController.status.summary
                        ]
                    )
                    print("OpenClicky Agent Mode: Background Computer Use context unavailable: \(error)")
                }
            } else if nativeComputerUseController.isEnabled {
                do {
                    let capture = try await nativeComputerUseController.captureFocusedWindowAsJPEG()
                    return try writeNativeComputerUseScreenContext(
                        capture,
                        minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                        forceClipboardSelection: forceClipboardSelection
                    )
                } catch {
                    print("OpenClicky Agent Mode: native CUA Swift focused-window context unavailable: \(error)")
                }
            }

            let captures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
            return try writeCapturedScreenContext(
                captures,
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            )
        } catch {
            print("OpenClicky Agent Mode: current screen context unavailable: \(error)")
            return nil
        }
    }

    func writeQueuedHandoffScreenContext(
        _ queuedRegions: [HandoffQueuedRegionScreenshot],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try queuedRegions.enumerated().map { index, queuedRegion in
            let fileURL = directory.appendingPathComponent("\(batchID)-handoff-\(index + 1).jpg", isDirectory: false)
            try queuedRegion.imageData.write(to: fileURL, options: .atomic)

            let rect = queuedRegion.selection.captureRect
            let comment = queuedRegion.selection.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            var noteParts: [String] = [
                "Selected region x:\(Int(rect.minX)) y:\(Int(rect.minY)) width:\(Int(rect.width)) height:\(Int(rect.height))."
            ]
            if queuedRegion.selection.hasFreehandPath {
                noteParts.append(
                    "User freehand-circled this region while speaking (\(queuedRegion.selection.pathPoints.count) path points)."
                )
            }
            let ambient = queuedRegion.selection.ambientSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ambient.isEmpty {
                noteParts.append(ambient)
            }
            if !comment.isEmpty {
                noteParts.append("User note / instruction: \(comment)")
            }

            return CodexAgentScreenContextAttachment(
                label: queuedRegion.selection.hasFreehandPath
                    ? "Circled handoff region \(index + 1)"
                    : "Queued handoff region \(index + 1)",
                fileURL: fileURL,
                note: noteParts.joined(separator: " ")
            )
        }

        let queuedNotes = queuedRegions
            .compactMap { $0.selection.comment.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return CodexAgentScreenContext(
            source: queuedRegions.contains(where: { $0.selection.hasFreehandPath })
                ? "circled screen handoff"
                : "queued screen handoff",
            capturedAt: Date(),
            selectedText: resolveSelectedText(
                from: queuedNotes,
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: attachments
        )
    }

    func writeNativeComputerUseScreenContext(
        _ capture: OpenClickyComputerUseWindowCapture,
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: capture.window.owner,
            bundleIdentifier: capture.window.bundleIdentifier,
            source: "native_cua_agent_context"
        )
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-cua-swift-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "native CUA Swift focused-window context",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    func writeBackgroundComputerUseScreenContext(
        _ capture: OpenClickyBackgroundComputerUseWindowCapture,
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: capture.appName,
            bundleIdentifier: capture.bundleID,
            source: "background_computer_use_agent_context"
        )
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-background-computer-use-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "Background Computer Use focused-window context",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    func writeCapturedScreenContext(
        _ captures: [CompanionScreenCapture],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try captures.enumerated().map { index, capture in
            let suffix = capture.isCursorScreen ? "primary" : "secondary-\(index + 1)"
            let fileURL = directory.appendingPathComponent("\(batchID)-\(suffix).jpg", isDirectory: false)
            try capture.imageData.write(to: fileURL, options: .atomic)
            OpenClickyApplicationUsageLogStore.shared.recordApplication(
                name: capture.appName,
                bundleIdentifier: capture.bundleIdentifier,
                source: "agent_screen_context"
            )

            let note = "Image dimensions \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels; display frame x:\(Int(capture.displayFrame.minX)) y:\(Int(capture.displayFrame.minY)) width:\(capture.displayWidthInPoints) height:\(capture.displayHeightInPoints)."

            return CodexAgentScreenContextAttachment(
                label: capture.label,
                fileURL: fileURL,
                note: note
            )
        }

        return CodexAgentScreenContext(
            source: "current desktop screenshot",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: attachments
        )
    }

    func readSelectedTextForAgentContext(
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) -> String? {
        let selection = readSelectedTextFromPasteboard(
            minimumChangeCount: minimumPasteboardChangeCount,
            allowUnchangedPasteboard: forceClipboardSelection
        )
        guard let selection else { return nil }
        return selection
    }

    func resolveSelectedText(
        from notes: [String],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) -> String? {
        let cleanedNotes = notes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = cleanedNotes.first {
            return first
        }

        return readSelectedTextForAgentContext(
            minimumPasteboardChangeCount: minimumPasteboardChangeCount,
            forceClipboardSelection: forceClipboardSelection
        )
    }

    func readSelectedTextFromPasteboard(
        minimumChangeCount: Int,
        allowUnchangedPasteboard: Bool = false
    ) -> String? {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard allowUnchangedPasteboard || currentChangeCount > minimumChangeCount else { return nil }
        guard let rawText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return nil
        }

        let compact = rawText.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(1_500))
    }

    static func shouldForceAgentClipboardSelection(for prompt: String) -> Bool {
        let normalized = prompt
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard normalized.contains("clipboard") || normalized.contains("pasteboard") else {
            return false
        }

        let explicitClipboardUsePattern = #"\b(?:take|pull|use|read|get|grab|fetch|bring|copy|paste|include|attach)\b.{0,40}\b(?:my|the)?\s*(?:clipboard|pasteboard)\b|\bfrom\s+(?:my|the)\s+(?:clipboard|pasteboard)\b"#
        return normalized.range(of: explicitClipboardUsePattern, options: .regularExpression) != nil
    }

    func createAgentScreenContextDirectory() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("AgentMode", isDirectory: true)
            .appendingPathComponent("ScreenContext", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func agentContextBatchID(date: Date = Date()) -> String {
        let rawID = ISO8601DateFormatter().string(from: date)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = rawID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return sanitized + "-" + String(UUID().uuidString.prefix(8))
    }

    func agentDockTargetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screen(containingOrNearestTo: mouseLocation)
    }

    func pointAtPermissionDragAssistant() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screen(containingOrNearestTo: mouseLocation)
        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        let assistantCenterY = visibleFrame.minY + max(70, visibleFrame.height * 0.22) + 70
        detectedElementBubbleText = WindowPositionManager.permissionDragAssistantMessage
        detectedElementDisplayFrame = targetScreen.frame
        detectedElementScreenLocation = CGPoint(
            x: visibleFrame.midX - 285,
            y: assistantCenterY
        )
    }

    func showAgentDockWindowNearCurrentScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screen(containingOrNearestTo: mouseLocation)
        guard let targetScreen else { return }
        agentDockWindowManager.show(
            companionManager: self,
            onScreen: targetScreen,
            position: agentParkingPosition
        )
    }
}
