//
//  cursor_buddyTests.swift
//  cursor-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
@testable import OpenClicky

@MainActor
struct cursor_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func agentRoutingHandlesNoisyAndTruncatedDelegationTranscripts() async throws {
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "Makesomething, ask an agent to review the OpenClicky code changes."
            ) == "review the OpenClicky code changes"
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "—an agent to look at today's conversation logs, summarize findings, and look for areas of improvement."
            ) == "look at today's conversation logs, summarize findings, and look for areas of improvement"
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "Question: Can you take a look at my desktop and see if there's any files that could be cleaned up?"
            ) == "take a look at my desktop and see if there's any files that could be cleaned up"
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "That's great, but when I asked for the agent to be launched, it didn't zoom off to the corner of the screen. Why was that?"
            ) == nil
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "How do I ask an agent to review logs?"
            ) == nil
        )
    }

    @Test func voiceResponseCompletionStateWaitsForPlaybackToFinish() async throws {
        #expect(
            CompanionManager.voiceResponseCompletionAudioPlaybackState(
                spokenText: "yes, i can hear you.",
                playbackFinished: true
            ) == "finished"
        )
        #expect(
            CompanionManager.voiceResponseCompletionAudioPlaybackState(
                spokenText: "yes, i can hear you.",
                playbackFinished: false
            ) == "interrupted"
        )
        #expect(
            CompanionManager.voiceResponseCompletionAudioPlaybackState(
                spokenText: "   ",
                playbackFinished: false
            ) == "empty"
        )
    }

    @Test func clearOverlayAnnotationsIntentMatcherIsAccurate() async throws {
        // Explicit noun forms match regardless of overlay state.
        #expect(
            CompanionManager.isClearOverlayAnnotationsRequest(
                "clear those rectangles", hasActiveOverlayAnnotation: false
            )
        )
        #expect(
            CompanionManager.isClearOverlayAnnotationsRequest(
                "hide the highlights", hasActiveOverlayAnnotation: false
            )
        )
        // Pronoun-only requires an active annotation.
        #expect(
            !CompanionManager.isClearOverlayAnnotationsRequest(
                "clear those", hasActiveOverlayAnnotation: false
            )
        )
        #expect(
            CompanionManager.isClearOverlayAnnotationsRequest(
                "clear those", hasActiveOverlayAnnotation: true
            )
        )
        // Agent phrasing should NOT match.
        #expect(
            !CompanionManager.isClearOverlayAnnotationsRequest(
                "dismiss those agents", hasActiveOverlayAnnotation: true
            )
        )
    }

    @Test func voiceHealthChecksUseLocalFastPath() async throws {
        #expect(
            CompanionManager.quickLocalVoiceResponseText(
                for: "Learning Buddy, can you hear me?"
            ) == "yes, i can hear you."
        )
        #expect(
            CompanionManager.quickLocalVoiceResponseText(
                for: "Hey Clicky, are you there?"
            ) == "i'm here."
        )
        #expect(
            CompanionManager.quickLocalVoiceResponseText(
                for: "Can you hear me out before you answer?"
            ) == nil
        )
    }

    @Test func tutorTargetClickHitTestingUsesPointAndRectTolerance() async throws {
        #expect(TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 120, y: 120),
            targetPoint: CGPoint(x: 100, y: 100),
            targetRect: nil
        ))
        #expect(!TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 180, y: 180),
            targetPoint: CGPoint(x: 100, y: 100),
            targetRect: nil
        ))
        #expect(TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 49, y: 72),
            targetPoint: nil,
            targetRect: CGRect(x: 50, y: 70, width: 20, height: 20)
        ))
        #expect(!TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 30, y: 30),
            targetPoint: nil,
            targetRect: CGRect(x: 50, y: 70, width: 20, height: 20)
        ))
    }
}
