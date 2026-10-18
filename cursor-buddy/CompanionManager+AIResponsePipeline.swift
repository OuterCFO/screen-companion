//
//  CompanionManager+AIResponsePipeline.swift
//  cursor-buddy
//

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
    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    /// `routesAgentWork` is false for compact-panel turns, which never hand work to Agent Mode by themselves.
    func sendTranscriptToClaudeWithScreenshot(transcript: String, forceScreenContext: Bool = false, routesAgentWork: Bool = true) {
        rememberMainConversationUserPrompt(transcript, source: "voice_response")
        interruptCurrentVoiceResponse()
        beginCursorReplyPresentation()
        let timing = activeRequestTiming
        var executionFields = voiceResponseExecutionFields()
        executionFields["transcriptLength"] = transcript.count
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.response",
            timing: timing,
            extra: executionFields
        )
        let requestID = timing?.requestID
        let completionToken = UUID()
        let completionState = OpenClickyRequestCompletionState()
        currentVoiceResponseRequestID = requestID
        currentVoiceResponseCompletionToken = completionToken
        currentVoiceResponseCancellationHandler = { [weak self] reason in
            guard let self, !completionState.didComplete else { return }
            completionState.didComplete = true
            var completionFields = self.voiceResponseExecutionFields()
            completionFields["cancelledAt"] = reason
            completionFields["audioPlaybackState"] = "interrupted"
            self.markRequestCompleted(
                route: "voice.response",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "cancelled",
                extra: completionFields
            )
            if self.currentVoiceResponseCompletionToken == completionToken {
                self.currentVoiceResponseCancellationHandler = nil
                self.currentVoiceResponseRequestID = nil
                self.currentVoiceResponseCompletionToken = nil
            }
        }

        let responseTaskToken = UUID()
        currentResponseTaskToken = responseTaskToken
        currentResponseTask = Task {
            defer { self.clearCurrentResponseTask(ifMatches: responseTaskToken) }
            // Stay in processing (spinner) state — no streaming text displayed
            self.voiceState = .processing

            func completeRequest(status: String = "success", extra: [String: Any] = [:]) async {
                await MainActor.run {
                    guard !completionState.didComplete else { return }
                    completionState.didComplete = true
                    if self.currentVoiceResponseCompletionToken == completionToken {
                        self.currentVoiceResponseCancellationHandler = nil
                        self.currentVoiceResponseRequestID = nil
                        self.currentVoiceResponseCompletionToken = nil
                    }
                    self.scheduleVoiceResponseCaptionClear()
                    var completionFields = self.voiceResponseExecutionFields()
                    extra.forEach { completionFields[$0.key] = $0.value }
                    self.markRequestCompleted(
                        route: "voice.response",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: status,
                        extra: completionFields
                    )
                }
            }

            do {
                OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "voice_question")
                let historyForAPI = self.voiceConversationHistoryForAPI()

                // Circle-while-talking: if the user drew a freehand trail during
                // this PTT hold, always attach visual context (crop + full screen).
                let circleHandoff = await self.consumePendingCircleSelectHandoff(instruction: transcript)

                // Only attach screenshots when the utterance actually needs
                // visual context. Text-only turns should not pay the capture,
                // base64, upload, and vision-processing latency tax.
                let captureStartedAt = Date()
                let shouldAttachScreenContext = boundCodexThreadID != nil || forceScreenContext || circleHandoff != nil || Self.shouldAttachScreenContext(
                    to: transcript,
                    recentConversationHistory: historyForAPI
                )
                let screenCaptures: [CompanionScreenCapture]
                if shouldAttachScreenContext {
                    screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()
                } else {
                    prewarmedScreenshotTask?.cancel()
                    prewarmedScreenshotTask = nil
                    prewarmedScreenshotStartedAt = nil
                    screenCaptures = []
                }
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "screen_capture",
                    stageStartedAt: captureStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "screen_capture",
                        "executionMethod": shouldAttachScreenContext ? "captureAllScreensForVoiceResponseIfAvailable" : "skipped_text_only_turn",
                        "controller": "ScreenCaptureKit",
                        "screenContextNeeded": shouldAttachScreenContext,
                        "screenCount": screenCaptures.count,
                        "circleSelectAttached": circleHandoff != nil,
                        "imageBytes": screenCaptures.reduce(0) { $0 + $1.imageData.count }
                            + (circleHandoff?.imageData.count ?? 0)
                    ]
                )

                guard !Task.isCancelled else {
                    await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_screen_capture"])
                    return
                }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                var labeledImages: [(data: Data, label: String)] = []
                if let circleHandoff {
                    let rect = circleHandoff.selection.captureRect
                    labeledImages.append((
                        data: circleHandoff.imageData,
                        label: "circled region crop (primary focus; \(Int(rect.width))x\(Int(rect.height)) pt) — user freehand-selected this area while speaking"
                    ))
                }
                labeledImages.append(contentsOf: screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                })

                let userPromptForClaude: String
                if labeledImages.isEmpty {
                    userPromptForClaude = "\(transcript)\n\nNo screenshot is available. Answer from the transcript only and use [POINT:none]."
                } else if let circleHandoff {
                    let note = circleHandoff.selection.ambientSummary.isEmpty
                        ? "The user circled a screen region while speaking. The first image is the cropped circled area; following images show broader screen context."
                        : "The user circled a screen region while speaking. The first image is the cropped circled area; following images show broader screen context.\n\(circleHandoff.selection.ambientSummary)"
                    userPromptForClaude = "\(transcript)\n\n\(note)"
                } else {
                    userPromptForClaude = transcript
                }

                let visualAnalysisModelID = self.selectedModel


                let voiceSystemPrompt = currentVoiceResponseSystemPrompt()
                    + (routesAgentWork ? "" : "\n\n" + ScreenTutorRoutingPolicy.noAutomaticAgentNote)

                let modelStartedAt = Date()
                var modelResponseFields = self.voiceResponseExecutionFields(
                    effectiveModelID: visualAnalysisModelID == self.selectedModel ? nil : visualAnalysisModelID
                )
                if visualAnalysisModelID != self.selectedModel {
                    modelResponseFields["visualAnalysisModel"] = visualAnalysisModelID
                    modelResponseFields["realtimeVisualPathOverride"] = true
                }
                var didDispatchStreamingPoint = false
                var lastCardPublishedAt: Date = .distantPast
                let cardPublishInterval: TimeInterval = 0.1
                let fullResponseText = try await analyzeVoiceResponse(
                    images: labeledImages,
                    modelID: visualAnalysisModelID,
                    systemPrompt: voiceSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptForClaude,
                    assistantPrefill: nil,
                    onTextChunk: { accumulatedText in
                        let streamed = Self.parsePointingCoordinates(from: accumulatedText)
                        if !Task.isCancelled, !didDispatchStreamingPoint, let point = streamed.coordinate {
                            let capture = self.tutorTargetScreenCapture(from: screenCaptures, screenNumber: streamed.screenNumber)
                            if let capture, SharedCodexSessionContract.isValidScreenshotPoint(point,
                                width: capture.screenshotWidthInPixels, height: capture.screenshotHeightInPixels) {
                                self.voiceState = .idle
                                self.cursorOverlayState.replyPointerIsPinned = true
                                self.cursorOverlayState.replyHasVerifiedTarget = true
                                self.detectedElementDisplayFrame = capture.displayFrame
                                self.detectedElementScreenLocation = self.globalPoint(fromScreenshotPoint: point, in: capture)
                                self.detectedElementBubbleText = Self.pointingBubbleText(for: streamed.elementLabel)
                                self.showCursorOverlayIfAvailable()
                                didDispatchStreamingPoint = true
                            }
                        }
                        let parsedSpoken = streamed.spokenText
                        let trimmed = parsedSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let now = Date()
                            if now.timeIntervalSince(lastCardPublishedAt) >= cardPublishInterval {
                                lastCardPublishedAt = now
                                let displayed = trimmed
                                self.latestVoiceResponseCard = ClickyResponseCard(
                                    source: .voice,
                                    rawText: displayed,
                                    contextTitle: transcript
                                )
                                self.updateVoiceResponseCaption(displayed)
                            }
                        }
                    }
                )
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "model_response",
                    stageStartedAt: modelStartedAt,
                    timing: timing,
                    extra: {
                        modelResponseFields["responseLength"] = fullResponseText.count
                        modelResponseFields["imageCount"] = labeledImages.count
                        return modelResponseFields
                    }()
                )

                guard !Task.isCancelled else {
                    await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_model_response"])
                    return
                }

                // Parse the visual guidance tag from Claude's response.
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                if self.autoEscalateVoiceResponseToAgentIfNeeded(
                    responseText: spokenText,
                    transcript: transcript,
                    source: "voice_response"
                ) {
                    await completeRequest(
                        status: "cancelled",
                        extra: [
                            "cancelledAt": "auto_escalated_to_agent",
                            "autoEscalatedToAgent": true
                        ]
                    )
                    return
                }

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                // Reply display must not depend on TTS or a model deciding to point.
                self.voiceState = .idle
                if !didDispatchStreamingPoint { self.cursorOverlayState.replyPointerIsPinned = true }
                self.showCursorOverlayIfAvailable()

                // Pick the screen capture for the buddy to point on.
                //
                // Resolution order:
                //   1. If Claude returned a screenNumber tag, trust it —
                //      that's a deliberate signal that the element lives on
                //      that specific screen. Honor it even when the cursor
                //      is on a different display (the user may have looked
                //      at screen 2 while the cursor stayed on screen 1).
                //   2. If no screenNumber, use the cursor's current screen
                //      (re-read live, not the stale `isCursorScreen` flag
                //      from capture time — Claude can take several seconds
                //      to respond and the user may have moved in that window).
                //   3. Last resort: the captured `isCursorScreen` flag.
                //
                // Earlier versions of this logic preferred the cursor screen
                // even when Claude returned screenNumber, which broke the
                // common "Claude correctly identified an element on the
                // other screen" case. The current logic keeps the live-cursor
                // benefit when Claude *didn't* tag a screen, and trusts
                // Claude when it did.
                let liveMouseLocation = NSEvent.mouseLocation
                let liveCursorCapture = screenCaptures.first { capture in
                    capture.displayFrame.contains(liveMouseLocation)
                }
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return liveCursorCapture
                        ?? screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture,
                   SharedCodexSessionContract.isValidScreenshotPoint(pointCoordinate,
                       width: targetScreenCapture.screenshotWidthInPixels,
                       height: targetScreenCapture.screenshotHeightInPixels) {
                    if !didDispatchStreamingPoint {
                    self.cursorOverlayState.replyHasVerifiedTarget = true
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let calibrationOffset = Self.visualGuidanceCalibrationOffset(for: displayFrame)
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    ).applying(
                        CGAffineTransform(
                            translationX: calibrationOffset.width,
                            y: calibrationOffset.height
                        )
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                    rememberPointedElement(
                        at: globalLocation,
                        displayFrame: displayFrame,
                        label: parseResult.elementLabel
                    )
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    }
                } else if let visualOverlay = parseResult.visualOverlay,
                          let targetScreenCapture {
                    self.showVisualGuidanceOverlay(
                        self.globalVisualGuidanceOverlay(
                            fromScreenshotOverlay: visualOverlay,
                            in: targetScreenCapture
                        ),
                        sourceCapture: targetScreenCapture
                    )
                    print("🎯 Visual guidance overlay: \(visualOverlay.kind.rawValue) → \"\(parseResult.elementLabel ?? "overlay")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    if self.boundCodexThreadID == nil { await attemptProactiveElementPointingIfUseful(
                        transcript: transcript,
                        spokenText: spokenText,
                        screenCaptures: screenCaptures
                    ) }
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                self.rememberVoiceExchange(
                    userTranscript: transcript,
                    assistantResponse: spokenText,
                    reason: "voice_response"
                )

                print("🧠 Conversation history: \(self.conversationHistory.count) active exchanges")
                do {
                    try codexHomeManager.appendPersistentMemoryEvent(
                        userRequest: transcript,
                        agentResponse: spokenText
                    )
                } catch {
                    print("⚠️ OpenClicky memory update failed: \(error)")
                }

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                self.latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: spokenText,
                    contextTitle: transcript
                )
                self.updateVoiceResponseCaption(spokenText)
                self.scheduleStatusSync()

                // If Haiku just offered to spin up an agent, remember
                // the user's transcript as the candidate task so a
                // confirmation on the next turn ("yes", "okay then")
                // can actually spawn an agent. Otherwise clear any
                // stale offer so a much-later "yes" doesn't suddenly
                // launch unrelated work.
                if Self.responseOffersAgentSpawn(spokenText) {
                    self.pendingAgentOfferInstruction = transcript
                    self.pendingAgentOfferAt = Date()
                } else {
                    self.pendingAgentOfferInstruction = nil
                    self.pendingAgentOfferAt = nil
                }

                var completionFields = self.voiceResponseExecutionFields(
                    effectiveModelID: visualAnalysisModelID == self.selectedModel ? nil : visualAnalysisModelID
                )
                completionFields["spokenTextLength"] = spokenText.count
                completionFields["pointed"] = parseResult.coordinate != nil
                self.latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: spokenText,
                    contextTitle: transcript
                )
                self.updateVoiceResponseCaption(spokenText, force: true)
                await completeRequest(extra: completionFields)
            } catch is CancellationError {
                // User spoke again — response was interrupted
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
            } catch where Self.isExpectedCancellation(error) {
                // User spoke again — URLSession/AVFoundation surfaced cancellation as NSError.
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "incoming",
                    event: "voice.response_error",
                    fields: [
                        "transcript": transcript,
                        "error": error.localizedDescription
                    ]
                )
                speakResponseFailureFallback(error, showsInBubble: true)
                await completeRequest(
                    status: "failed",
                    extra: [
                        "error": error.localizedDescription
                    ]
                )
            }

            if !Task.isCancelled {
                self.lastVoiceInteractionCompletedAt = Date()
                self.voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    func startTutorIdleObservation() {
        userActivityIdleDetector.start()
        bindTutorIdleObservation()
    }

    func stopTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = nil
        userActivityIdleDetector.stop()
        tutorTargetClickTracker.disarm()
        isTutorObservationInFlight = false
    }

    private func bindTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = userActivityIdleDetector.$isUserIdle
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self,
                      self.isTutorModeEnabled,
                      self.voiceState == .idle,
                      !self.isTutorObservationInFlight,
                      Date().timeIntervalSince(self.lastVoiceInteractionCompletedAt) >= Self.tutorObservationVoiceCooldown else { return }

                self.isTutorObservationInFlight = true
                Task {
                    await self.performTutorObservation()
                    self.userActivityIdleDetector.observationDidComplete()
                    self.isTutorObservationInFlight = false
                }
            }
    }

    private func performTutorObservation() async {
        do {
            tutorTargetClickTracker.disarm()
            ensureCursorOverlayVisibleForAgentTask()
            voiceState = .processing

            let screenCaptures = try await CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
            let labeledImages = screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }
            let historyForAPI = voiceConversationHistoryForAPI()

            let fullResponseText = try await analyzeVoiceResponse(
                images: labeledImages,
                systemPrompt: self.currentTutorModeSystemPrompt(),
                conversationHistory: historyForAPI,
                userPrompt: "observe the focused window and guide me to the next useful learning step.",
                onTextChunk: { _ in }
            )

            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
            let spokenText = parseResult.spokenText

            if let pointCoordinate = parseResult.coordinate,
               let targetScreenCapture = tutorTargetScreenCapture(from: screenCaptures, screenNumber: parseResult.screenNumber) {
                let globalLocation = globalPoint(
                    fromScreenshotPoint: pointCoordinate,
                    in: targetScreenCapture
                )
                voiceState = .idle
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = targetScreenCapture.displayFrame
                detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                rememberPointedElement(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel
                )
                armTutorTargetClickTracking(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel
                )
                ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                print("Tutor pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y)))")
            }

            rememberVoiceExchange(
                userTranscript: "[tutor observation]",
                assistantResponse: spokenText,
                reason: "tutor_observation"
            )
        } catch is CancellationError {
            // A normal voice interaction interrupted the tutor observation.
        } catch where Self.isExpectedCancellation(error) {
            // A normal voice interaction interrupted the tutor observation.
        } catch {
            print("Tutor observation error: \(error)")
        }

        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func armTutorTargetClickTracking(at point: CGPoint, displayFrame: CGRect?, label: String?) {
        guard isTutorModeEnabled else { return }
        tutorTargetClickTracker.arm(targetPoint: point, targetRect: nil) { [weak self] clickPoint in
            guard let self else { return }
            self.lastVoiceInteractionCompletedAt = .distantPast
            self.userActivityIdleDetector.recordTutorStepCompleted()
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "tutor.target_clicked",
                fields: [
                    "label": label ?? "",
                    "targetX": Int(point.x),
                    "targetY": Int(point.y),
                    "clickX": Int(clickPoint.x),
                    "clickY": Int(clickPoint.y),
                    "displayFrame": displayFrame.map { frame in
                        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
                    } ?? ""
                ]
            )
        }
    }

    private func tutorTargetScreenCapture(from screenCaptures: [CompanionScreenCapture], screenNumber: Int?) -> CompanionScreenCapture? {
        // Resolution order:
        //   1. If Claude returned a screenNumber tag, trust it — that's a
        //      deliberate signal about which screen the element lives on.
        //   2. Otherwise, fall back to the cursor's live current screen
        //      (re-read so we don't use a stale `isCursorScreen` flag from
        //      capture time).
        //   3. Last resort: the captured `isCursorScreen` flag.
        if let screenNumber,
           screenNumber >= 1,
           screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        }

        let liveMouseLocation = NSEvent.mouseLocation
        let liveCursorCapture = screenCaptures.first { $0.displayFrame.contains(liveMouseLocation) }

        return liveCursorCapture
            ?? screenCaptures.first(where: { $0.isCursorScreen })
            ?? screenCaptures.first
    }

    func globalPoint(
        fromScreenshotPoint point: CGPoint,
        in capture: CompanionScreenCapture,
        applyingCalibration: Bool = true
    ) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let clampedX = max(0, min(point.x, screenshotWidth))
        let clampedY = max(0, min(point.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let calibrationOffset = applyingCalibration
            ? Self.visualGuidanceCalibrationOffset(for: capture.displayFrame)
            : .zero
        return CGPoint(
            x: displayLocalX + capture.displayFrame.origin.x,
            y: (displayHeight - displayLocalY) + capture.displayFrame.origin.y
        ).applying(
            CGAffineTransform(
                translationX: calibrationOffset.width,
                y: calibrationOffset.height
            )
        )
    }

    private func globalRect(
        fromScreenshotRect rect: CGRect,
        in capture: CompanionScreenCapture,
        applyingCalibration: Bool = true
    ) -> CGRect {
        let origin = globalPoint(fromScreenshotPoint: rect.origin, in: capture, applyingCalibration: applyingCalibration)
        let opposite = globalPoint(fromScreenshotPoint: CGPoint(x: rect.maxX, y: rect.maxY), in: capture, applyingCalibration: applyingCalibration)
        return CGRect(
            x: min(origin.x, opposite.x),
            y: min(origin.y, opposite.y),
            width: abs(opposite.x - origin.x),
            height: abs(opposite.y - origin.y)
        )
    }

    private func globalVisualGuidanceOverlay(
        fromScreenshotOverlay overlay: OpenClickyVisualGuidanceOverlay,
        in capture: CompanionScreenCapture
    ) -> OpenClickyVisualGuidanceOverlay {
        switch overlay.kind {
        case .scribble:
            return OpenClickyVisualGuidanceOverlay.scribble(
                points: overlay.points.map { globalPoint(fromScreenshotPoint: $0.cgPoint, in: capture) },
                accentHex: overlay.style.accentHex,
                lineWidth: overlay.style.lineWidth,
                caption: overlay.style.caption,
                duration: overlay.duration
            )
        case .rectangle:
            guard let rect = overlay.rect else {
                return overlay
            }
            let isCalibrationAnchor = Self.isVisualGuidanceCalibrationCaption(overlay.style.caption)
            return OpenClickyVisualGuidanceOverlay.rectangle(
                rect: globalRect(
                    fromScreenshotRect: rect.cgRect,
                    in: capture,
                    applyingCalibration: !isCalibrationAnchor
                ),
                accentHex: overlay.style.accentHex,
                lineWidth: overlay.style.lineWidth,
                fillOpacity: overlay.style.fillOpacity,
                caption: overlay.style.caption,
                duration: overlay.duration
            )
        }
    }

    func analyzeVoiceResponse(
        images: [(data: Data, label: String)],
        modelID: String? = nil,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        if let threadID = boundCodexThreadID {
            return try await sessionLink(for: threadID).submit(threadID: threadID, prompt: userPrompt,
                images: images, onText: onTextChunk)
        }
        let responseSystemPrompt = systemPrompt + "\n\n" + CursorResponseContract.instructions
        let requestedModelID = modelID ?? selectedModel
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: requestedModelID)
        return try await answerProviders.answer(AnswerRequest(
            model: selectedVoiceResponseModel, images: images, systemPrompt: responseSystemPrompt,
            history: conversationHistory, prompt: userPrompt,
            assistantPrefill: nil // Mandatory point-first format forbids a prose prefill.
        ), onText: onTextChunk)
    }

    private static let visualFollowUpHistoryDepth = 3

    static func shouldAttachScreenContext(
        to transcript: String,
        recentConversationHistory: [(userPlaceholder: String, assistantResponse: String)] = []
    ) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)

        if shouldForceAgentClipboardSelection(for: transcript) {
            return true
        }

        if isVisualGuidanceDrawingRequest(normalized: normalized, commandText: commandText) {
            return true
        }

        let explicitVisualPhrases = [
            "my screen", "the screen", "on screen", "on the screen", "this screen",
            "start screen calibration", "begin screen calibration", "run screen calibration",
            "enter calibration mode", "calibration mode",
            "calibrate the screen", "calibrate screen", "calibrate this display",
            "calibrate our screens", "calibrate screens", "calibrate display",
            "screen calibration", "calibration anchor",
            "what am i looking", "what's on", "what is on", "what do you see",
            "look at", "take a look", "can you see", "do you see",
            "this window", "that window", "current window", "active window",
            "this app", "that app", "this page", "that page", "this button", "that button",
            "this field", "that field", "this menu", "that menu",
            "where is", "where's", "point to", "show me where", "highlight",
            "draw around", "draw round", "circle around", "circle round", "rectangle around",
            "rectangle round", "box around", "box round", "outline", "scribble", "trace",
            "selection around", "shape around", "shapes around", "logo",
            "layout", "spacing", "padding", "margin", "margins", "green symbol",
            "green mark",
            "click", "press", "select", "open this", "open that"
        ]
        if explicitVisualPhrases.contains(where: { normalized.contains($0) || commandText.contains($0) }) {
            return true
        }

        let visualTokens: Set<String> = [
            "screen", "window", "button", "field", "menu", "dialog", "popup",
            "page", "tab", "cursor", "visible", "shown", "displayed", "image",
            "screenshot", "icon", "link", "sidebar", "toolbar", "dock", "logo",
            "layout", "spacing", "padding", "margin", "margins", "size", "sized",
            "highlight", "rectangle", "rectangles", "circle", "circles",
            "shape", "shapes", "box", "outline", "scribble", "scribbles", "trace",
            "left", "right", "top", "bottom", "symbol", "green", "calibrate", "calibration"
        ]
        let tokens = commandText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: { visualTokens.contains($0) }) { return true }

        let visualFollowUps: Set<String> = [
            "how about now",
            "what about now",
            "try again",
            "check again",
            "look again",
            "can you try again",
            "can you check again",
            "can you look again"
        ]
        if visualFollowUps.contains(commandText),
           recentConversationHistory
           .suffix(visualFollowUpHistoryDepth)
           .contains(where: { turn in
               let recentText = "\(turn.userPlaceholder) \(turn.assistantResponse)"
                   .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                   .lowercased()
               return explicitVisualPhrases.contains(where: recentText.contains)
                   || recentText
                   .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                   .contains(where: { visualTokens.contains(String($0)) })
           }) {
            return true
        }

        return false
    }

    static func isScreenCalibrationRequest(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)
        let calibrationPhrases = [
            "start screen calibration", "begin screen calibration", "run screen calibration",
            "enter calibration mode", "calibration mode",
            "calibrate the screen", "calibrate screen", "calibrate this display",
            "calibrate our screens", "calibrate screens", "calibrate display",
            "screen calibration", "calibration anchor"
        ]
        return calibrationPhrases.contains { normalized.contains($0) || commandText.contains($0) }
    }

    private static func isVisualGuidanceDrawingRequest(normalized: String, commandText: String) -> Bool {
        let visualDrawPatterns = [
            #"\b(?:draw|put|place|add|show|make)\s+(?:a\s+|an\s+|the\s+)?(?:rectangle|rect|box|circle|oval|ring|outline|shape)\s+(?:around|round|over|on|onto)\b"#,
            #"\b(?:circle|box|outline|mark|highlight)\s+(?:the\s+|this\s+|that\s+|a\s+|an\s+)?[a-z0-9][a-z0-9\s-]{0,80}\b"#,
            #"\b(?:draw|trace|scribble)\s+(?:around|round|over|on|onto)\b"#
        ]

        for text in [normalized, commandText] {
            for pattern in visualDrawPatterns {
                if text.range(of: pattern, options: .regularExpression) != nil {
                    return true
                }
            }
        }

        return false
    }

    func captureAllScreensForVoiceResponseIfAvailable() async throws -> [CompanionScreenCapture] {
        // Prefer the prewarmed capture started at keyDown if it's fresh.
        // Otherwise fall back to a synchronous capture so the AI still
        // gets a screenshot when the prewarm path was skipped (e.g. text
        // input, programmatic transcript).
        if let prewarmed = prewarmedScreenshotTask,
           let startedAt = prewarmedScreenshotStartedAt,
           Date().timeIntervalSince(startedAt) <= Self.prewarmedScreenshotMaxAge {
            prewarmedScreenshotTask = nil
            prewarmedScreenshotStartedAt = nil
            do {
                return try await prewarmed.value
            } catch {
                print("⚠️ Prewarmed screenshot failed, falling back to fresh capture: \(error)")
                return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }
        }

        // Stale or missing prewarm — discard and capture fresh.
        prewarmedScreenshotTask?.cancel()
        prewarmedScreenshotTask = nil
        prewarmedScreenshotStartedAt = nil
        return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
    }

    /// Starts capturing a screenshot in parallel with audio recording.
    /// Called from `.pressed` so the JPEG-encoded captures are usually
    /// ready by the time the user releases the key. No-op when screen
    /// recording permission is missing — the response path falls back
    /// to text-only in that case.
    func startPrewarmedScreenshotCaptureIfPossible() {
        guard hasScreenContentPermission else { return }

        // Cancel any stale capture from a prior press that never landed
        // (e.g. user pressed and released without speaking).
        prewarmedScreenshotTask?.cancel()

        prewarmedScreenshotStartedAt = Date()
        prewarmedScreenshotTask = Task.detached(priority: .userInitiated) {
            try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        }
    }

    func analyzeComputerUsePointingResponse(
        image: (data: Data, label: String),
        capture: CompanionScreenCapture,
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let resolver = Self.computerUsePointingResolver(
            selectedVoiceModelID: selectedModel,
            selectedComputerUseModelID: selectedComputerUseModel
        )

        switch resolver {
        case .anthropicAPI:
            return try await answerProviders.answer(AnswerRequest(
                model: selectedPointingModel, images: [image], systemPrompt: systemPrompt,
                history: [], prompt: userPrompt, assistantPrefill: nil
            ), onText: onTextChunk)
        case .codexCLI:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            let text = try await detector.detectPointTag(
                screenshotData: image.data,
                screenshotLabel: image.label,
                userQuestion: userPrompt,
                systemPrompt: systemPrompt,
                displayWidthInPixels: capture.screenshotWidthInPixels,
                displayHeightInPixels: capture.screenshotHeightInPixels
            )
            onTextChunk(text)
            return text
        case .openAIResponses:
            openAIAPI.model = selectedPointingModel.id
            let (text, _) = try await openAIAPI.analyzeImage(
                images: [image],
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            onTextChunk(text)
            return text
        case .unsupported:
            throw NSError(
                domain: "OpenClickyComputerUsePointing",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "\(selectedPointingModel.id) is not a supported pointing model."]
            )
        }
    }

    static func computerUsePointingResolver(
        selectedVoiceModelID _: String,
        selectedComputerUseModelID: String
    ) -> OpenClickyComputerUsePointingResolver {
        let pointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModelID)

        switch pointingModel.provider {
        case .anthropic:
            return .anthropicAPI
        case .codex:
            return .codexCLI
        case .openAI:
            return .openAIResponses
        case .apple, .commandLine:
            return .unsupported
        }
    }

    static let nativeClickPointingSystemPrompt = """
    You are OpenClicky's visual click target resolver. The user wants OpenClicky to actually click in the visible app, not merely point or explain.

    Identify the single clickable UI element only when it visibly and directly matches the user's request. Do not choose unrelated, nearby, generic, decorative, or merely available controls. Return exactly one short phrase followed by one [POINT:x,y:label] tag. Use screenshot pixel coordinates with origin at the top-left. If there is no safe directly relevant matching target, return [POINT:none].
    """

    private func attemptProactiveElementPointingIfUseful(
        transcript: String,
        spokenText: String,
        screenCaptures: [CompanionScreenCapture]
    ) async {
        guard Self.shouldAttemptProactivePointing(for: transcript) else { return }
        guard let targetScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else { return }

        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let userQuestion = "\(transcript)\n\nOpenClicky's answer: \(spokenText)"
        let displayLocalLocation: CGPoint?

        switch selectedPointingModel.provider {
        case .anthropic:
            guard let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey() else { return }
            let detector = ElementLocationDetector(apiKey: anthropicAPIKey, model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectElementLocation(
                screenshotData: targetScreenCapture.imageData,
                userQuestion: userQuestion,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .codex:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectDisplayLocalPoint(
                screenshotData: targetScreenCapture.imageData,
                screenshotLabel: targetScreenCapture.label,
                userQuestion: userQuestion,
                displayWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                displayHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .apple, .openAI, .commandLine:
            return
        }

        guard let displayLocalLocation else { return }

        let displayFrame = targetScreenCapture.displayFrame
        let globalLocation = CGPoint(
            x: displayLocalLocation.x + displayFrame.origin.x,
            y: displayLocalLocation.y + displayFrame.origin.y
        )

        voiceState = .idle
        detectedElementBubbleText = Self.shortPointingCaption(from: spokenText)
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = globalLocation
        rememberPointedElement(at: globalLocation, displayFrame: displayFrame, label: "proactive")
        ClickyAnalytics.trackElementPointed(elementLabel: "proactive")
        print("🎯 Proactive element pointing: (\(Int(displayLocalLocation.x)), \(Int(displayLocalLocation.y)))")
    }

    private static func shouldAttemptProactivePointing(for transcript: String) -> Bool {
        let normalizedTranscript = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let normalizedCommandText = SpokenText.normalizedSpokenCommandText(transcript)

        let voiceStatusPhrases = [
            "can you hear",
            "hear me",
            "mic",
            "microphone",
            "not speaking",
            "speaking",
            "voice",
            "audio",
            "responding",
            "response",
            "slow",
            "taking so long",
            "lag"
        ]
        if voiceStatusPhrases.contains(where: { normalizedCommandText.contains($0) }) {
            return false
        }

        let screenRelatedPhrases = [
            "screen",
            "window",
            "button",
            "menu",
            "setting",
            "permission",
            "file",
            "folder",
            "tab",
            "click",
            "open",
            "where",
            "how do i",
            "what is this",
            "what's this",
            "this screen",
            "this window",
            "this button",
            "this menu",
            "this file",
            "this folder",
            "this tab",
            "this setting",
            "that screen",
            "that window",
            "that button",
            "that menu",
            "that file",
            "that folder",
            "that tab",
            "that setting",
            "right here",
            "over here",
            "up here",
            "down here",
            "what am i looking at",
            "show me",
            "point",
            "cursor"
        ]

        return screenRelatedPhrases.contains { normalizedTranscript.contains($0) }
    }

    static func pointingBubbleText(for elementLabel: String?) -> String {
        let trimmedLabel = elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedLabel.isEmpty else {
            return "right here"
        }
        return "right here: \(trimmedLabel)"
    }

    private static func shortPointingCaption(from spokenText: String) -> String {
        let flattenedText = spokenText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattenedText.count > 76 else {
            return flattenedText.isEmpty ? "right here" : flattenedText
        }

        let endIndex = flattenedText.index(flattenedText.startIndex, offsetBy: 76)
        let prefix = String(flattenedText[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    /// If the cursor is in transient mode (user toggled "Show OpenClicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // A visible reply belongs to the AI pointer, so keep them together.
            while responseOverlayManager.isVisible {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Logs a response failure but stays SILENT. We never speak with
    /// the macOS system TTS — that introduces a second voice that the
    /// user doesn't recognize. Errors surface through logs and the
    /// response card; the agent simply doesn't speak this turn.
    func speakResponseFailureFallback(_ error: Error, showsInBubble: Bool = false) {
        guard !Self.isExpectedCancellation(error) else { return }
        let message = userFacingResponseFailureMessage(for: error)
        print("⚠️ Voice response failure (silent — no system-voice fallback): \(message)")
        let fields: [String: Any] = [
            "error": error.localizedDescription,
            "message": message
        ]
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.response_failure_silent",
            fields: fields
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: message,
            contextTitle: lastTranscript ?? ""
        )
        // Show answer failures in the pointer bubble; speech failures keep the answer that is already there.
        if showsInBubble { updateVoiceResponseCaption("<cursor_reply>" + message + "</cursor_reply>", force: true, updatesDock: false) }
    }

    static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }

        let description = String(describing: error).lowercased()
        return description == "cancellationerror()" || description.contains("cancelled") || description.contains("canceled")
    }

    private func userFacingResponseFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        let modelLabel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel).label
        if let message = ProviderErrorMessage.userFacing(error.localizedDescription, modelLabel: modelLabel) {
            return message
        }

        switch nsError.domain {
        case "ClaudeAPI":
            if nsError.code == -1000 {
                return "Anthropic is not configured. Set the Anthropic API key and relaunch."
            }
            return "Claude returned an error. Check the app log for the exact response."
        case "CompanionScreenCapture":
            return "Screen capture failed. Grant Screen Recording to this exact app, then quit and reopen."
        default:
            return "Something went wrong. Check the app log for the exact error."
        }
    }

}
