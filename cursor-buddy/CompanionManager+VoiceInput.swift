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
    func dismissCoachingOverlays() {
        interruptCurrentVoiceResponse()
        // Suppress late chunks until a new question starts a fresh reply.
        responseOverlayManager.dismissCurrentReply()
        clearDetectedElementLocation()
        visualGuidanceOverlayClearTasks.values.forEach { $0.cancel() }
        visualGuidanceOverlayClearTasks.removeAll()
        cursorOverlayState.visualGuidanceOverlays.removeAll()
        latestVoiceResponseCard = nil
    }

    func handleEscapeKeyPressed() {
        let isVoiceActive = voiceState == .responding
            || voiceState == .processing
            || currentResponseTask != nil
        guard isVoiceActive || responseOverlayManager.isVisible || hasActiveOverlayAnnotation else { return }
        cancelCircleSelectSession(clearPending: true)
        dismissCoachingOverlays()
    }

    func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }

            ClickyAnalytics.trackPushToTalkStarted()

            // Kick off the screenshot the moment the key goes down so it
            // captures in parallel with audio recording instead of blocking
            // the response path after the final transcript arrives.
            startPrewarmedScreenshotCaptureIfPossible()
            beginCircleSelectSessionIfEnabled()

            pendingKeyboardShortcutStartTask?.cancel()

            clearDetectedElementLocation()
            liveHandledComputerUseFingerprints.removeAll()

            pendingKeyboardShortcutStartTask = Task { [weak self] in
                guard let buddyDictationManager = self?.buddyDictationManager else { return }

                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        self?.circleSelectLivePartialTranscript = partialTranscript
                        self?.circleSelectSession.refreshSnapUsingLatestTranscript()
                        self?.handleLiveComputerUseTranscript(partialTranscript)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.handleFinalVoiceTranscript(finalTranscript)
                    },
                    onWillStartRecording: { [weak self] in
                        // Only cut playback once the non-Realtime dictation
                        // path is actually going to capture audio. A quick
                        // press/release during provider or permission startup
                        // should not skip the current spoken reply.
                        self?.interruptCurrentVoiceResponse()
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            finishCircleSelectSessionForVoiceTurn()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            // Keep the prewarmed screenshot — even on a quick press the user
            // may still produce a final transcript (e.g. wake-word). The
            // freshness check in the consumer discards stale captures.
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    func beginCircleSelectSessionIfEnabled() {
        guard AppBundleConfiguration.isCircleWhileTalkingEnabled() else {
            cancelCircleSelectSession(clearPending: false)
            return
        }
        pendingCircleSelectCaptureTask?.cancel()
        pendingCircleSelectCaptureTask = nil
        pendingCircleSelectExpiryTask?.cancel()
        pendingCircleSelectExpiryTask = nil
        pendingCircleSelectStroke = nil
        circleSelectLivePartialTranscript = ""
        clearCircleSelectOverlay()
        // Drop prior circle handoffs so a new hold never reuses a stale region.
        handoffQueue.removeAll { $0.selection.hasFreehandPath }

        let requireClick = AppBundleConfiguration.isCircleWhileTalkingRequireClickEnabled()
        circleSelectSession.start(
            requireClick: requireClick,
            partialTranscriptProvider: { [weak self] in
                guard let self else { return nil }
                let live = self.circleSelectLivePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !live.isEmpty { return live }
                let last = self.lastTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return last.isEmpty ? nil : last
            },
            onPointsChanged: { [weak self] points in
                self?.cursorOverlayState.circleSelectLivePoints = points
            },
            onSnapChanged: { [weak self] snap in
                self?.cursorOverlayState.circleSelectSnappedRect = snap?.rect
                self?.cursorOverlayState.circleSelectSnapLabel = snap?.label
            }
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.circle_select.started",
            fields: [
                "requireClick": requireClick
            ]
        )
    }

    func finishCircleSelectSessionForVoiceTurn() {
        guard AppBundleConfiguration.isCircleWhileTalkingEnabled() || circleSelectSession.isActive else {
            clearCircleSelectOverlay()
            return
        }

        let sealed = circleSelectSession.stop()
        // Keep snapped rect visible briefly after seal so the handoff feels deliberate.
        if let snap = sealed?.snap {
            cursorOverlayState.circleSelectSnappedRect = snap.rect
            cursorOverlayState.circleSelectSnapLabel = snap.label
        }
        cursorOverlayState.circleSelectLivePoints = sealed?.points ?? []
        pendingCircleSelectStroke = sealed

        if let sealed {
            // Keep the trail / snap visible briefly so the user sees the sealed region.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self else { return }
                if self.pendingCircleSelectStroke?.sealedAt == sealed.sealedAt {
                    self.clearCircleSelectOverlay()
                }
            }
            pendingCircleSelectCaptureTask?.cancel()
            pendingCircleSelectCaptureTask = Task { @MainActor in
                do {
                    let crop = try await CompanionScreenCaptureUtility.captureRegionAsJPEG(sealed.captureRect)
                    let selection = sealed.handoffSelection(instruction: "")
                    let queued = HandoffQueuedRegionScreenshot(selection: selection, imageData: crop.imageData)
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.circle_select.sealed",
                        fields: [
                            "pointCount": sealed.points.count,
                            "pathLength": Int(sealed.pathLength.rounded()),
                            "width": Int(sealed.captureRect.width.rounded()),
                            "height": Int(sealed.captureRect.height.rounded()),
                            "imageBytes": crop.imageData.count
                        ]
                    )
                    return queued
                } catch {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "error",
                        event: "voice.circle_select.capture_failed",
                        fields: ["error": error.localizedDescription]
                    )
                    return nil
                }
            }
            pendingCircleSelectExpiryTask?.cancel()
            pendingCircleSelectExpiryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard let self,
                      self.pendingCircleSelectStroke?.sealedAt == sealed.sealedAt else {
                    return
                }
                self.cancelCircleSelectSession()
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "voice.circle_select.expired",
                    fields: ["reason": "no_matching_voice_turn"]
                )
            }
        } else {
            clearCircleSelectOverlay()
            pendingCircleSelectCaptureTask = nil
            pendingCircleSelectExpiryTask?.cancel()
            pendingCircleSelectExpiryTask = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.circle_select.discarded",
                fields: ["reason": "below_threshold_or_disabled"]
            )
        }
    }

    func cancelCircleSelectSession(clearPending: Bool = true) {
        circleSelectSession.cancel()
        clearCircleSelectOverlay()
        if clearPending {
            pendingCircleSelectStroke = nil
            pendingCircleSelectCaptureTask?.cancel()
            pendingCircleSelectCaptureTask = nil
            pendingCircleSelectExpiryTask?.cancel()
            pendingCircleSelectExpiryTask = nil
        }
    }

    func clearCircleSelectOverlay() {
        cursorOverlayState.circleSelectLivePoints = []
        cursorOverlayState.circleSelectSnappedRect = nil
        cursorOverlayState.circleSelectSnapLabel = nil
    }

    /// Consumes a sealed circle-select capture for the current voice/agent turn.
    /// Returns crop attachment data plus ambient note when the user circled while talking.
    func consumePendingCircleSelectHandoff(instruction: String) async -> HandoffQueuedRegionScreenshot? {
        let sealed = pendingCircleSelectStroke
        let captureTask = pendingCircleSelectCaptureTask
        pendingCircleSelectStroke = nil
        pendingCircleSelectCaptureTask = nil
        pendingCircleSelectExpiryTask?.cancel()
        pendingCircleSelectExpiryTask = nil
        clearCircleSelectOverlay()

        guard sealed != nil || captureTask != nil else { return nil }

        let queued = await captureTask?.value
        if var existing = queued {
            existing.selection.comment = instruction
            if let sealed {
                existing.selection.pathPoints = sealed.points
                existing.selection.ambientSummary = sealed.ambient.summaryLine
                existing.selection.startPositionInScreen = sealed.startPositionInScreen
                existing.selection.endPositionInScreen = sealed.endPositionInScreen
                existing.selection.screenFrame = sealed.screenFrame
            }
            return existing
        }

        guard let sealed else { return nil }
        do {
            let crop = try await CompanionScreenCaptureUtility.captureRegionAsJPEG(sealed.captureRect)
            return HandoffQueuedRegionScreenshot(
                selection: sealed.handoffSelection(instruction: instruction),
                imageData: crop.imageData
            )
        } catch {
            return nil
        }
    }

    /// Fires from the processing watchdog when voiceState has been stuck
    /// at .processing for longer than processingWatchdogTimeout seconds.
    /// Resets UI state only — does NOT cancel in-flight tasks so a late
    /// response can still arrive and transition to .responding normally.
    func recoverFromStuckProcessingStateIfNeeded() {
        guard voiceState == .processing else { return }
        voiceState = .idle
        currentAudioPowerLevel = 0
        clearVoiceResponseCaption()
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.state.processing_watchdog_recovered",
            fields: [
                "timeoutSeconds": Int(Self.processingWatchdogTimeout),
                "model": selectedModel
            ]
        )
    }

    func handleFinalVoiceTranscript(_ finalTranscript: String) {
        lastTranscript = finalTranscript
        let requestTiming = beginRequestTiming(source: "voice_final_transcript", text: finalTranscript)
        activeRequestTiming = requestTiming
        defer {
            activeRequestTiming = nil
            clearDeferredLiveAgentRoutePartial()
        }
        print("Companion received transcript: \(finalTranscript)")
        lastVoiceInteractionCompletedAt = Date()
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.transcript",
            fields: [
                "text": finalTranscript,
                "requestID": requestTiming.requestID
            ]
        )
        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)

        // The final transcript ends the live-partial window for every route.

        if submitHomeChatVoiceTranscriptIfNeeded(finalTranscript, source: "voice_home_chat") {
            return
        }

        if routeFinalVoiceTranscriptActionIfNeeded(
            finalTranscript,
            source: "voice",
            selectionSource: "voice_final_transcript",
            directComputerUseSource: "final_transcript",
            includeQuickLocalResponses: true
        ) {
            return
        }
        // Remember this prompt in the same shared conversation context used
        // by instant text and Realtime voice, so later "on it" / "do that"
        // agent handoffs can resolve to the actual previous message.
        rememberMainConversationUserPrompt(finalTranscript, source: "voice_final_transcript")

        sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
    }

    func routeFinalVoiceTranscriptActionIfNeeded(
        _ transcript: String,
        source: String,
        selectionSource: String,
        directComputerUseSource: String,
        includeQuickLocalResponses: Bool,
        hybridAgentStartCountsAsHandled: Bool = false
    ) -> Bool {
        if handleAgentCancellationRequestIfNeeded(from: transcript) {
            return true
        }
        if handleAgentStatusQuestionIfNeeded(from: transcript) {
            return true
        }
        if handleClearOverlayAnnotationsRequestIfNeeded(from: transcript) {
            return true
        }
        if handleVisualGuidanceCalibrationCursorSampleIfNeeded(from: transcript) {
            return true
        }
        // Screen calibration is a voice visual-guidance flow, not Agent Mode.
        // Keep it in the screenshot-aware voice lane even when the user
        // phrases a retry as "get an agent to do a screen calibration."
        if ScreenTutorRoutingPolicy.shouldStayInTutor(transcript) || Self.isScreenCalibrationRequest(transcript) {
            return false
        }
        if handleAgentSelectionRequestIfNeeded(from: transcript, source: selectionSource) {
            return true
        }
        if acceptPendingAgentOfferIfConfirmed(from: transcript) {
            return true
        }
        if submitPendingAgentVoiceFollowUp(transcript) {
            return true
        }
        if startHybridAgentTaskIfNeeded(from: transcript) {
            return hybridAgentStartCountsAsHandled
        }
        if startExplicitAgentTaskIfRequested(from: transcript) {
            return true
        }
        if startAgentTaskFromDeferredLiveAgentRouteIfNeeded(transcript) {
            return true
        }
        if handleDirectComputerUseRequest(from: transcript, source: directComputerUseSource) {
            return true
        }
        if includeQuickLocalResponses, handleQuickLocalVoiceResponseIfNeeded(from: transcript) {
            return true
        }
        if submitContextualAgentFollowUp(transcript, source: source) {
            return true
        }
        if startSmartAgentTaskIfNeeded(from: transcript) {
            return true
        }
        if startImplicitAgentTaskIfNeeded(from: transcript) {
            return true
        }
        return false
    }

    // MARK: - Companion Prompt

    func handleLiveComputerUseTranscript(_ partialTranscript: String) {
        let trimmedTranscript = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        let isShortKnownAppRequest = Self.bareLocalAppOpenRequest(from: trimmedTranscript) != nil
        guard trimmedTranscript.count >= 8 || isShortKnownAppRequest else { return }

        let shouldTraceMiss = Self.isPotentialDirectComputerUseTranscript(trimmedTranscript)
        if Self.shouldDeferLiveComputerUseForAgentRoute(trimmedTranscript) {
            recordDeferredLiveAgentRoutePartial(trimmedTranscript)
            if shouldTraceMiss {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "incoming",
                    event: "native_cua.live_partial.deferred_agent_route",
                    fields: [
                        "partialTranscript": trimmedTranscript
                    ]
                )
            }
            return
        }

        if let folderRequest = folderOpenRequest(from: trimmedTranscript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "folder", value: folderRequest.url.path)
            guard !liveHandledComputerUseFingerprints.contains(fingerprint) else { return }
            liveHandledComputerUseFingerprints.insert(fingerprint)
            let requestTiming = beginRequestTiming(source: "voice_live_partial", text: trimmedTranscript)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.live_partial.folder_detected",
                fields: [
                    "partialTranscript": trimmedTranscript,
                    "executor": "native_cua",
                    "route": "native_cua.open_folder",
                    "executionMethod": "NSWorkspace.open",
                    "path": folderRequest.url.path,
                    "requestID": requestTiming.requestID
                ]
            )
            withActiveRequestTiming(requestTiming) {
                openRequestedFolder(folderRequest, shouldSpeak: false)
            }
            return
        }

        if Self.compositeAppActionRequest(from: trimmedTranscript) != nil {
            // Composite app commands need the final transcript so the
            // action is complete. Do not let the live-partial open-app
            // shortcut swallow the action as just "Open <app>."
            return
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: trimmedTranscript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "app", value: appOpenRequest.appName)
            guard !liveHandledComputerUseFingerprints.contains(fingerprint) else { return }
            guard Self.canResolveApplicationWithoutShellOpen(named: appOpenRequest.appName) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "incoming",
                    event: "native_cua.live_partial.app_candidate_unresolved",
                    fields: [
                        "partialTranscript": trimmedTranscript,
                        "executor": "native_cua",
                        "route": "native_cua.open_app",
                        "executionMethod": "launchApplication(named:)",
                        "appName": appOpenRequest.appName
                    ]
                )
                return
            }
            let requestTiming = beginRequestTiming(source: "voice_live_partial", text: trimmedTranscript)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.live_partial.app_detected",
                fields: [
                    "partialTranscript": trimmedTranscript,
                    "executor": "native_cua",
                    "route": "native_cua.open_app",
                    "executionMethod": "launchApplication(named:)",
                    "appName": appOpenRequest.appName,
                    "requestID": requestTiming.requestID
                ]
            )
            withActiveRequestTiming(requestTiming) {
                if openRequestedApplication(appOpenRequest, shouldSpeak: false) {
                    liveHandledComputerUseFingerprints.insert(fingerprint)
                }
            }
            return
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: trimmedTranscript) {
            let backend = selectedComputerUseBackend
            let fingerprint = Self.directComputerUseFingerprint(
                kind: "key",
                value: "\(keyPressRequest.modifiers.joined(separator: "+"))+\(keyPressRequest.key)"
            )
            guard !liveHandledComputerUseFingerprints.contains(fingerprint) else { return }
            liveHandledComputerUseFingerprints.insert(fingerprint)
            let requestTiming = beginRequestTiming(source: "voice_live_partial", text: trimmedTranscript)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).live_partial.key_detected",
                fields: [
                    "partialTranscript": trimmedTranscript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).press_key",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/press_key"
                        : "OpenClickyNativeComputerUseController.pressKey",
                    "key": keyPressRequest.key,
                    "modifiers": keyPressRequest.modifiers.joined(separator: ","),
                    "requestID": requestTiming.requestID
                ]
            )
            withActiveRequestTiming(requestTiming) {
                pressKeyUsingSelectedComputerUse(keyPressRequest, shouldSpeak: false)
            }
            return
        }

        if shouldTraceMiss {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.live_partial.no_direct_match",
                fields: [
                    "partialTranscript": trimmedTranscript
                ]
            )
        }
    }

    func recordDeferredLiveAgentRoutePartial(_ partialTranscript: String) {
        deferredLiveAgentRoutePartial = partialTranscript
        deferredLiveAgentRoutePartialAt = Date()
    }

    func clearDeferredLiveAgentRoutePartial() {
        deferredLiveAgentRoutePartial = nil
        deferredLiveAgentRoutePartialAt = nil
    }

    func startAgentTaskFromDeferredLiveAgentRouteIfNeeded(_ finalTranscript: String) -> Bool {
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty,
              let partialTranscript = deferredLiveAgentRoutePartial,
              let partialAt = deferredLiveAgentRoutePartialAt else {
            return false
        }

        let partialAge = Date().timeIntervalSince(partialAt)
        guard partialAge <= Self.deferredLiveAgentRoutePartialTTL,
              let instruction = Self.deferredLiveAgentRouteInstruction(
                partialTranscript: partialTranscript,
                finalTranscript: trimmedTranscript
              ) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "incoming",
            event: "native_cua.final_transcript.deferred_agent_route_recovered",
            fields: [
                "partialTranscript": partialTranscript,
                "finalTranscript": trimmedTranscript,
                "partialAgeMs": Int(partialAge * 1000),
                "executor": "agent_mode",
                "route": "agent.start",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(instruction: instruction)
        return true
    }

    func startImplicitAgentTaskIfNeeded(from finalTranscript: String) -> Bool {
        guard let instruction = Self.implicitAgentTaskInstruction(from: finalTranscript) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.implicit_route",
            fields: [
                "transcript": finalTranscript,
                "instruction": instruction,
                "executor": "agent_mode",
                "route": "agent.start",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(
            instruction: instruction,
            acknowledgement: "i’ll take care of that in the background.",
            voiceContextUserTranscript: finalTranscript
        )
        return true
    }

    func startSmartAgentTaskIfNeeded(from finalTranscript: String) -> Bool {
        guard let decision = Self.smartAgentRouteDecision(from: finalTranscript) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.smart_route",
            fields: [
                "transcript": finalTranscript,
                "instruction": decision.instruction,
                "reason": decision.reason,
                "confidence": decision.confidence,
                "executor": "agent_mode",
                "route": "agent.start",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(
            instruction: decision.instruction,
            acknowledgement: decision.acknowledgement,
            voiceContextUserTranscript: finalTranscript
        )
        return true
    }

    func startHybridAgentTaskIfNeeded(from transcript: String) -> Bool {
        guard let instruction = Self.hybridAgentTaskInstruction(from: transcript) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.hybrid_route",
            fields: [
                "transcript": transcript,
                "instruction": instruction,
                "executor": "agent_mode",
                "route": "agent.hybrid_start",
                "foregroundRoute": "voice.response",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(
            instruction: instruction,
            acknowledgement: "i’ll handle the background part too.",
            route: "agent.hybrid_start",
            interruptVoiceResponse: false,
            voiceContextUserTranscript: transcript
        )
        return true
    }

    func autoEscalateVoiceResponseToAgentIfNeeded(
        responseText: String,
        transcript: String,
        source: String,
        route: String = "agent.auto_escalate"
    ) -> Bool {
        guard Self.shouldEscalateVoiceResponseToAgent(
            responseText: responseText,
            transcript: transcript
        ) else {
            return false
        }

        let acknowledgement: String
        let instruction: String
        let reason: String
        if let decision = Self.smartAgentRouteDecision(from: transcript) {
            acknowledgement = decision.acknowledgement
            instruction = decision.instruction
            reason = "smart_\(decision.reason)"
        } else if let filesystemInstruction = Self.implicitFilesystemTaskInstruction(from: transcript) {
            acknowledgement = Self.filesystemTaskAcknowledgement(from: transcript)
            instruction = filesystemInstruction
            reason = "filesystem_refusal_recovery"
        } else if let implicitInstruction = Self.implicitAgentTaskInstruction(from: transcript) {
            acknowledgement = "i’ll take care of that in the background."
            instruction = implicitInstruction
            reason = "implicit_refusal_recovery"
        } else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.voice_auto_escalated",
            fields: [
                "source": source,
                "transcript": transcript,
                "responseText": responseText,
                "instruction": instruction,
                "reason": reason,
                "executor": "agent_mode",
                "route": route,
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )

        pendingAgentOfferInstruction = nil
        pendingAgentOfferAt = nil
        startVoiceAgentTaskPlan(
            instruction: instruction,
            acknowledgement: acknowledgement,
            route: route,
            speakAcknowledgement: false,
            interruptVoiceResponse: true,
            voiceContextUserTranscript: transcript
        )
        return true
    }
}
