import Foundation
import OCComputerUseCore
import Testing
@testable import OpenClicky

struct OpenClickyComputerUseTests {
    @Test func realtimeCompositeAppCommandIsNotReducedToOpenApp() throws {
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Can you open Spotify and play AC/DC Back to Black?"
            ) == nil
        )
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Can you open Spotify and can you play AC/DC Back to Black?"
            ) == nil
        )
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Open Chrome and go to amazon.co.uk"
            ) == nil
        )
        #expect(CompanionManager.testCompositeAppAction(from: "Open Chrome and go to amazon.co.uk") == nil)
        #expect(CompanionManager.testWebOpenTarget(from: "Open Chrome and go to amazon.co.uk")?.url == "https://amazon.co.uk")
        #expect(CompanionManager.testWebOpenTarget(from: "Open Chrome and go to amazon.co.uk")?.browserAppName == "Google Chrome")
    }

    @Test func directRequestRoutersDoNotStealQuestionsOrDesignTasks() throws {
        #expect(CompanionManager.testLocalAppOpenTarget(from: "You open GitHub.") == "GitHub Desktop")
        #expect(CompanionManager.testLocalFolderOpenTarget(from: "Is your working folder currently the OpenClicky folder?") == nil)
        #expect(CompanionManager.testLocalFolderOpenTarget(from: "look into introducing workspaces or project folders in OpenClicky so I can configure named workspaces") == nil)
        #expect(CompanionManager.testLocalFolderOpenTarget(from: "Take a look at /Users/jkneen/clawd/github/hf-realtime-voice — how could we integrate this into OpenClicky?") == nil)
    }

    @Test func pastedLogsDoNotBecomeReminderCountCommands() throws {
        let pastedLogs = """
        find out why we're having issues
        [OpenClickyLog][2026-06-09T11:22:08Z][computer-use/incoming] native_cua.direct_request.reminder_count_detected {"route":"native_cua.reminder_count","transcript":"count tasks reminders"}
        """

        #expect(CompanionManager.testLogEvidenceAnalysisInstruction(from: pastedLogs) != nil)
        #expect(CompanionManager.testReminderCountInstruction(from: pastedLogs) == nil)
    }

    @Test func spokenPlayButtonRequestsMapToARealKey() throws {
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press the play button in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.modifiers == [])
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.key == "k")
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.modifiers == ["command"])
    }

    @Test func conversationalPageNavigationStaysInsideTheVoiceComputerUseTurn() throws {
        #expect(CompanionManager.testNativeKeyPress(from: "To the next page.")?.key == "pagedown")
        #expect(CompanionManager.testNativeKeyPress(from: "Can you take me to the next page?")?.key == "pagedown")
        #expect(CompanionManager.testNativeKeyPress(from: "Go to the previous page.")?.key == "pageup")
        #expect(CompanionManager.testNativeKeyPress(from: "Scroll one page up.")?.key == "pageup")
    }

    @Test func conversationalComputerUseClickRequestsStayOnDirectActionRoute() throws {
        let referential = CompanionManager.testNativeClick(
            from: "OK, can you do computer use then and click that?"
        )
        #expect(referential?.targetPhrase == nil)
        #expect(referential?.prefersLastPointedElement == true)

        let explicitComputerUse = CompanionManager.testNativeClick(
            from: "Okay, use computer use to click that."
        )
        #expect(explicitComputerUse?.prefersLastPointedElement == true)

        let correctedTarget = CompanionManager.testNativeClick(
            from: "Oh, no, no. Click on my basket."
        )
        #expect(correctedTarget?.targetPhrase == "my basket")
        #expect(correctedTarget?.prefersLastPointedElement == false)

        #expect(
            CompanionManager.testWebOpenTarget(
                from: "yeah, open the browser and go to amazon dot co dot uk"
            )?.url == "https://amazon.co.uk"
        )
    }

    @MainActor @Test func compositeAppCommandsPreserveTheFollowUpAction() throws {
        let spotifyAction = CompanionManager.testCompositeAppAction(
            from: "Open Spotify and play AC/DC Back in Black."
        )
        #expect(spotifyAction?.appName == "Spotify")
        #expect(spotifyAction?.actionText == "play AC/DC Back in Black")

        let politeSpotifyAction = CompanionManager.testCompositeAppAction(
            from: "Open Spotify and can you play AC/DC Back in Black?"
        )
        #expect(politeSpotifyAction?.appName == "Spotify")
        #expect(politeSpotifyAction?.actionText == "play AC/DC Back in Black")

        let mailAction = CompanionManager.testCompositeAppAction(
            from: "Open Mail and search for invoices."
        )
        #expect(mailAction?.appName == "Mail")
        #expect(mailAction?.actionText == "search for invoices")

        let bareSpotifyAction = CompanionManager.testCompositeAppAction(
            from: "Spotify and play Back in Black."
        )
        #expect(bareSpotifyAction?.appName == "Spotify")
        #expect(bareSpotifyAction?.actionText == "play Back in Black")
        #expect(CompanionManager.testSpotifyPlaybackQuery(from: "Spotify and play Back in Black.") == "Back in Black")
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "Can you play Back in Black?") == "Back in Black")
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "play the video") == nil)
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "Can you play Spotify?") == nil)
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "play anything in Spotify") == nil)
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "Can you play Spotify?") == "play")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "play anything in Spotify") == "play")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "play music") == "play")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "pause Spotify") == "pause")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "skip in Spotify") == "next")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "go back in Spotify") == "previous")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn shuffle on in Spotify") == "shuffleOn")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn shuffle off in Spotify") == "shuffleOff")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn repeat on in Spotify") == "repeatOn")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn repeat off in Spotify") == "repeatOff")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn Spotify volume up") == "volumeUp")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn Spotify volume down") == "volumeDown")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "increase Spotify volume") == "volumeUp")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "lower Spotify volume") == "volumeDown")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "set Spotify volume to 35 percent") == "volumeSet:35")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "set Spotify volume to 150") == "volumeSet:100")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn volume up") == nil)
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "mute volume") == nil)
    }

    @Test func standaloneSystemVolumeCommandsUseSystemAudioRoute() throws {
        #expect(CompanionManager.testSystemVolumeControlAction(from: "turn volume up") == "volumeUp")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "turn volume down") == "volumeDown")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "mute") == "mute")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "mute volume") == "mute")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "set volume to 35 percent") == "setVolume:35")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "set volume to 150") == "setVolume:100")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "turn Spotify volume up") == nil)
        #expect(CompanionManager.testSystemVolumeControlAction(from: "open Spotify and turn volume up") == nil)
    }

    @MainActor @Test func spotifySearchPlayRouteStaysOnComputerUseExecution() throws {
        let nativeMethods = CompanionManager.testSpotifySearchPlayExecutionMethods(for: .nativeSwift)
        #expect(nativeMethods.started == "NSWorkspace.open_spotify_uri + OpenClickyNativeComputerUseController.pressKey + AppleScript playback verification")
        #expect(nativeMethods.completed == "NSWorkspace.open_spotify_uri + OpenClickyNativeComputerUseController.pressKey + AppleScript playback verification")
        #expect(nativeMethods.completed.localizedCaseInsensitiveContains("AppleScript"))
        #expect(nativeMethods.completed.localizedCaseInsensitiveContains("verification"))

        let backgroundMethods = CompanionManager.testSpotifySearchPlayExecutionMethods(for: .backgroundComputerUse)
        #expect(backgroundMethods.started == "NSWorkspace.open_spotify_uri + BackgroundComputerUse /v1/press_key + AppleScript playback verification")
        #expect(backgroundMethods.completed == "NSWorkspace.open_spotify_uri + BackgroundComputerUse /v1/press_key + AppleScript playback verification")
        #expect(backgroundMethods.completed.localizedCaseInsensitiveContains("AppleScript"))
        #expect(backgroundMethods.completed.localizedCaseInsensitiveContains("verification"))
    }

    @MainActor @Test func voiceAgentStartFingerprintNormalizesDuplicateRealtimeRoutes() throws {
        let first = CompanionManager.testVoiceAgentStartFingerprint(
            instruction: "Figure out why our background computer-use path, C U A, is reporting background agent not started yet.",
            route: "agent.hybrid_start"
        )
        let repeated = CompanionManager.testVoiceAgentStartFingerprint(
            instruction: "figure out why our background computer use path c u a is reporting background agent not started yet",
            route: "agent.hybrid_start"
        )
        #expect(first == repeated)
    }

    @Test func appleFoundationModelIsInVoiceCatalog() throws {
        let apple = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyModelCatalog.appleFoundationModelID)
        #expect(apple.id == OpenClickyModelCatalog.appleFoundationModelID)
        #expect(apple.provider == .apple)
        #expect(apple.provider.voiceBackendFamily == .apple)
        #expect(apple.maxOutputTokens >= 64_000)
        #expect(OpenClickyVoiceBackendFamily.apple.defaultModelID == OpenClickyModelCatalog.appleFoundationModelID)
        #expect(OpenClickyVoiceBackendFamily.claude.defaultModelID == "claude-sonnet-5-5")
        #expect(OpenClickyVoiceBackendFamily.codex.defaultModelID == OpenClickyModelCatalog.defaultCodexActionsModelID)
        #expect(OpenClickyVoiceBackendFamily.allCases.count == 3)

        let claudeDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.claude.defaultModelID)
        #expect(claudeDefault.provider == .anthropic)
        #expect(claudeDefault.provider.voiceBackendFamily == .claude)

        let codexDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.codex.defaultModelID)
        #expect(codexDefault.provider.voiceBackendFamily == .codex)

        // Apple is offered in the settings response grid via responseVoiceModels.
        #expect(OpenClickyModelCatalog.responseVoiceModels.contains { $0.id == OpenClickyModelCatalog.appleFoundationModelID })
    }

    @Test func providerDiscoveryReturnsThreeFamilies() throws {
        let rows = OpenClickyProviderDiscovery.availability()
        #expect(rows.map(\.family) == [.apple, .codex, .claude])
        for row in rows {
            #expect(!row.statusLabel.isEmpty)
            #expect(!row.detail.isEmpty)
            #expect(OpenClickyProviderDiscovery.isAvailable(row.family) == row.isAvailable)
        }
    }

    @Test func manuallyDismissedReplyRejectsLateChunksUntilNewQuestion() {
        var policy = ReplyVisibilityPolicy()
        #expect(policy.canPresent)
        policy.dismiss()
        #expect(!policy.canPresent)
        // Repeated dismissal cannot reopen the reply.
        policy.dismiss()
        #expect(!policy.canPresent)
        policy.beginNewReply()
        #expect(policy.canPresent)
    }

    @Test func voiceResponseModelsDoNotUseShortTTSGenerationCap() throws {
        let responseBudgets = OpenClickyModelCatalog.responseVoiceModels.map(\.maxOutputTokens)
        #expect(responseBudgets.allSatisfy { $0 >= 64_000 })
    }

    @Test func removedRealtimeModelsMigrateToTheTextDefault() throws {
        for legacyID in ["gpt-realtime-2", "gpt-realtime-2.1-mini", "gpt-realtime-2.1", "gpt-realtime-1.5", "deepgram-voice-agent"] {
            #expect(OpenClickyModelCatalog.voiceResponseModel(withID: legacyID).id == OpenClickyModelCatalog.defaultVoiceResponseModelID)
        }
        #expect(OpenClickyModelCatalog.voiceResponseModel(withID: "definitely-not-a-real-model-id").id == OpenClickyModelCatalog.defaultVoiceResponseModelID)
    }

    @Test func nonSpeechModelsRemainSelectedForVoiceAnalysis() throws {
        #expect(OpenClickyModelCatalog.voiceAnalysisModel(withID: "gpt-5.6-sol").id == "gpt-5.6-sol")
        #expect(OpenClickyModelCatalog.codexVoiceSessionModel(withID: "gpt-5.6-sol").id == "gpt-5.6-sol")
    }

    @Test func nonRealtimeVoiceKeepsSelectedComputerUsePointingResolver() throws {
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "gpt-5.6-sol",
                selectedComputerUseModelID: "gpt-5.6-sol"
            ) == "codex_cli"
        )
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "fable-5",
                selectedComputerUseModelID: "gpt-5.6-sol"
            ) == "codex_cli"
        )
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "fable-5",
                selectedComputerUseModelID: "sonnet-5"
            ) == "anthropic_api"
        )
    }

    @Test func codexPointDetectorDoesNotUseRemovedApprovalFlag() throws {
        let arguments = CodexPointDetector.testCodexExecArguments()
        #expect(!arguments.contains("--ask-for-approval"))
        #expect(arguments.contains("-c"))
        #expect(arguments.contains("approval_policy=\"never\""))
    }
}
