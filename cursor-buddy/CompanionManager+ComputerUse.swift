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
    func handleDirectComputerUseRequest(from transcript: String, source: String) -> Bool {
        guard Self.logEvidenceAnalysisInstruction(from: transcript) == nil else {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "internal",
                event: "native_cua.direct_request.skipped_log_evidence",
                fields: [
                    "source": source,
                    "transcriptLength": transcript.count,
                    "executor": "agent_mode",
                    "route": "agent.start",
                    "reason": "pasted_log_evidence"
                ]
            )
            return false
        }

        if let folderRequest = folderOpenRequest(from: transcript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "folder", value: folderRequest.url.path)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.folder_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.open_folder",
                    "executionMethod": "NSWorkspace.open",
                    "path": folderRequest.url.path,
                    "alreadyHandledLive": liveHandledComputerUseFingerprints.contains(fingerprint),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if liveHandledComputerUseFingerprints.contains(fingerprint) {
                let executionStartedAt = markRequestExecutionStarted(
                    route: "native_cua.open_folder.already_handled_live",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "path": folderRequest.url.path
                    ]
                )
                showShortSystemResponse("opening \(folderRequest.displayName).")
                markRequestCompleted(
                    route: "native_cua.open_folder.already_handled_live",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "path": folderRequest.url.path
                    ]
                )
            } else {
                openRequestedFolder(folderRequest)
            }
            return true
        }

        if let webOpenRequest = Self.webOpenRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.web_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.open_url",
                    "executionMethod": "NSWorkspace.open",
                    "url": webOpenRequest.url.absoluteString,
                    "browserAppName": webOpenRequest.browserAppName ?? "",
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            openRequestedWebsite(webOpenRequest)
            return true
        }

        if let compositeRequest = Self.compositeAppActionRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.composite_app_action_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).composite_app_action",
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": compositeRequest.appName,
                    "actionText": compositeRequest.actionText,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if handleSupportedCompositeAppActionRequest(compositeRequest, backend: backend) {
                return true
            }

            let executionStartedAt = markRequestExecutionStarted(
                route: "\(backend.executorID).composite_app_action.unsupported",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": compositeRequest.appName,
                    "actionText": compositeRequest.actionText
                ]
            )
            pendingAgentOfferInstruction = Self.compositeAppActionAgentInstruction(from: compositeRequest)
            pendingAgentOfferAt = Date()
            let response = "that app action needs Agent Mode. Say: start an agent to \(compositeRequest.instruction)."
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: response,
                contextTitle: compositeRequest.instruction
            )
            showShortSystemResponse(response)
            markRequestCompleted(
                route: "\(backend.executorID).composite_app_action.unsupported",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": compositeRequest.appName,
                    "actionText": compositeRequest.actionText,
                    "error": "No supported live composite app-action executor matched"
                ]
            )
            return true
        }

        if let spotifyPlaybackRequest = Self.standaloneSpotifyPlaybackRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.spotify_playback_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).spotify_search_play",
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": spotifyPlaybackRequest.appName,
                    "actionText": spotifyPlaybackRequest.actionText,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if handleSpotifyCompositeAppActionRequest(spotifyPlaybackRequest, backend: backend) {
                return true
            }
        }

        if let systemVolumeAction = Self.systemVolumeControlAction(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.system_volume_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.system_volume",
                    "executionMethod": "CoreAudio default output volume",
                    "action": systemVolumeAction.rawValue,
                    "requiresAccessibility": false,
                    "requiresSystemEventsAutomation": false,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            runSystemVolumeControl(systemVolumeAction, instruction: transcript)
            return true
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: transcript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "app", value: appOpenRequest.appName)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.app_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.open_app",
                    "executionMethod": "launchApplication(named:)",
                    "appName": appOpenRequest.appName,
                    "alreadyHandledLive": liveHandledComputerUseFingerprints.contains(fingerprint),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if liveHandledComputerUseFingerprints.contains(fingerprint) {
                let executionStartedAt = markRequestExecutionStarted(
                    route: "native_cua.open_app.already_handled_live",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "appName": appOpenRequest.appName
                    ]
                )
                showShortSystemResponse("opening \(appOpenRequest.appName).")
                markRequestCompleted(
                    route: "native_cua.open_app.already_handled_live",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "appName": appOpenRequest.appName
                    ]
                )
            } else {
                _ = openRequestedApplication(appOpenRequest)
            }
            return true
        }

        if let reminderAddRequest = Self.reminderAddRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.reminder_add_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.reminder_add",
                    "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                    "title": reminderAddRequest.title,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            addReminderUsingNativeAutomation(reminderAddRequest)
            return true
        }

        if let reminderCountRequest = Self.reminderCountRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.reminder_count_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.reminder_count",
                    "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            countRemindersUsingNativeAutomation(reminderCountRequest)
            return true
        }

        if let messagesSearchRequest = Self.messagesSearchRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.messages_search_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).messages_search",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                        : "OpenClickyNativeComputerUseController.pressKey/typeText",
                    "personName": messagesSearchRequest.personName,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            searchMessagesUsingSelectedComputerUse(messagesSearchRequest)
            return true
        }

        if let clickRequest = Self.nativeClickRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.click_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.click",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "targetPhrase": clickRequest.targetPhrase ?? "",
                    "prefersLastPointedElement": clickRequest.prefersLastPointedElement,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            clickUsingSelectedComputerUse(clickRequest)
            return true
        }

        if let typeRequest = Self.nativeTypeRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.type_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).type_text",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/type_text"
                        : "OpenClickyNativeComputerUseController.typeText",
                    "textLength": typeRequest.text.count,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            typeTextUsingSelectedComputerUse(typeRequest)
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            let fingerprint = Self.directComputerUseFingerprint(
                kind: "key",
                value: "\(keyPressRequest.modifiers.joined(separator: "+"))+\(keyPressRequest.key)"
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.key_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).press_key",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/press_key"
                        : "OpenClickyNativeComputerUseController.pressKey",
                    "key": keyPressRequest.key,
                    "modifiers": keyPressRequest.modifiers.joined(separator: ","),
                    "alreadyHandledLive": liveHandledComputerUseFingerprints.contains(fingerprint),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if liveHandledComputerUseFingerprints.contains(fingerprint) {
                let modifierText = keyPressRequest.modifiers.isEmpty ? "" : keyPressRequest.modifiers.joined(separator: " ") + " "
                let executionStartedAt = markRequestExecutionStarted(
                    route: "\(backend.executorID).press_key.already_handled_live",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": "live_partial_preexecuted",
                        "key": keyPressRequest.key,
                        "modifiers": keyPressRequest.modifiers.joined(separator: ",")
                    ]
                )
                showShortSystemResponse("pressed \(modifierText)\(keyPressRequest.key).")
                markRequestCompleted(
                    route: "\(backend.executorID).press_key.already_handled_live",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": "live_partial_preexecuted",
                        "key": keyPressRequest.key,
                        "modifiers": keyPressRequest.modifiers.joined(separator: ",")
                    ]
                )
            } else {
                pressKeyUsingSelectedComputerUse(keyPressRequest)
            }
            return true
        }

        return false
    }

    func openRequestedWebsite(_ request: OpenClickyWebOpenRequest, shouldSpeak: Bool = true) {
        let executionMethod = request.browserAppName == nil
            ? "NSWorkspace.open"
            : "NSWorkspace.open_withApplication"
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.open_url",
            extra: [
                "executor": "native_cua",
                "executionMethod": executionMethod,
                "controller": "NSWorkspace",
                "url": request.url.absoluteString,
                "browserAppName": request.browserAppName ?? "",
                "shouldSpeak": shouldSpeak
            ]
        )
        var openedInRequestedBrowser = false
        if let browserAppName = request.browserAppName,
           let browserURL = Self.resolvedApplicationURL(named: browserAppName) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [request.url],
                withApplicationAt: browserURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.open_url.browser_activation_failed",
                        fields: [
                            "browserAppName": browserAppName,
                            "path": browserURL.path,
                            "url": request.url.absoluteString,
                            "error": error.localizedDescription
                        ]
                    )
                }
            }
            openedInRequestedBrowser = true
        }
        if !openedInRequestedBrowser {
            NSWorkspace.shared.open(request.url)
        }
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "opening \(request.displayName).",
            contextTitle: request.instruction
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.open_url",
            fields: [
                "executor": "native_cua",
                "executionMethod": openedInRequestedBrowser ? "NSWorkspace.open_withApplication" : "NSWorkspace.open",
                "controller": "NSWorkspace",
                "url": request.url.absoluteString,
                "browserAppName": request.browserAppName ?? "",
                "instruction": request.instruction
            ]
        )
        if shouldSpeak {
            showShortSystemResponse("opening \(request.displayName).")
        }
        markRequestCompleted(
            route: "native_cua.open_url",
            executionStartedAt: executionStartedAt,
            extra: [
                "executor": "native_cua",
                "executionMethod": openedInRequestedBrowser ? "NSWorkspace.open_withApplication" : "NSWorkspace.open",
                "controller": "NSWorkspace",
                "url": request.url.absoluteString,
                "browserAppName": request.browserAppName ?? ""
            ]
        )
    }

    func handleSupportedCompositeAppActionRequest(
        _ request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) -> Bool {
        if request.appName == "Spotify",
           handleSpotifyCompositeAppActionRequest(request, backend: backend) {
            return true
        }

        if let searchQuery = Self.compositeAppSearchQuery(from: request.actionText) {
            searchInApplicationUsingSelectedComputerUse(
                OpenClickyCompositeAppSearchActionRequest(
                    appName: request.appName,
                    query: searchQuery,
                    instruction: request.instruction
                ),
                backend: backend
            )
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: request.actionText) {
            pressKeyInApplicationUsingSelectedComputerUse(
                keyPressRequest,
                appName: request.appName,
                instruction: request.instruction,
                backend: backend
            )
            return true
        }

        return false
    }

    func handleSpotifyCompositeAppActionRequest(
        _ request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) -> Bool {
        if let controlAction = Self.spotifyPlaybackControlAction(from: request.actionText) {
            runSpotifyPlaybackControl(controlAction, request: request, backend: backend)
            return true
        }

        if let query = Self.spotifyPlaybackQuery(from: request.actionText) {
            openSpotifySearchAndPlayTopResult(query: query, request: request, backend: backend)
            return true
        }

        return false
    }

    func openSpotifySearchAndPlayTopResult(
        query: String,
        request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).spotify_search_play"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                "controller": backend == .backgroundComputerUse
                    ? "OpenClickyBackgroundComputerUseController"
                    : "OpenClickyNativeComputerUseController",
                "appName": request.appName,
                "actionText": request.actionText,
                "query": query
            ]
        )

        guard let spotifyURL = Self.spotifySearchURL(for: query),
              NSWorkspace.shared.open(spotifyURL) else {
            showShortSystemResponse("i couldn't open Spotify search for \(query).")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "NSWorkspace.open_spotify_uri",
                    "appName": request.appName,
                    "query": query,
                    "error": "Spotify search URL could not be opened"
                ]
            )
            return
        }

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching Spotify for \(query).",
            contextTitle: request.instruction
        )
        showShortSystemResponse("searching Spotify for \(query).")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await pressKeyInApplication(
                    "enter",
                    modifiers: [],
                    appName: "Spotify",
                    backend: backend
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let verification = await Task.detached(priority: .userInitiated) {
                    OpenClickyLocalAutomationRunner.runAppleScript("""
                    tell application "Spotify"
                        return player state as string
                    end tell
                    """)
                }.value
                let playerState = verification.output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let verificationError = verification.errorOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard verification.terminationStatus == 0, playerState == "playing" else {
                    if verification.terminationStatus == 0, playerState != "playing" {
                        let retry = await Task.detached(priority: .userInitiated) {
                            OpenClickyLocalAutomationRunner.runAppleScript("""
                            tell application "Spotify"
                                activate
                                play
                                delay 0.2
                                return player state as string
                            end tell
                            """)
                        }.value
                        let retryPlayerState = retry.output
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        if retry.terminationStatus == 0, retryPlayerState == "playing" {
                            latestVoiceResponseCard = ClickyResponseCard(
                                source: .voice,
                                rawText: "playing \(query) on Spotify.",
                                contextTitle: request.instruction
                            )
                            showShortSystemResponse("playing \(query) on Spotify.")
                            OpenClickyMessageLogStore.shared.append(
                                lane: "computer-use",
                                direction: "outgoing",
                                event: "\(backend.executorID).spotify_search_play_voice_retry",
                                fields: [
                                    "executor": backend.executorID,
                                    "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                                    "appName": request.appName,
                                    "query": query,
                                    "initialPlayerState": playerState,
                                    "playerState": retryPlayerState,
                                    "instruction": request.instruction
                                ]
                            )
                            markRequestCompleted(
                                route: route,
                                executionStartedAt: executionStartedAt,
                                timing: timing,
                                extra: [
                                    "executor": backend.executorID,
                                    "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                                    "appName": request.appName,
                                    "query": query,
                                    "initialPlayerState": playerState,
                                    "playerState": retryPlayerState,
                                    "voicePathRetry": true
                                ]
                            )
                            return
                        }
                    }
                    let errorText = verification.terminationStatus == 0
                        ? "Spotify stayed \(playerState.isEmpty ? "unknown" : playerState) after search selection."
                        : (verificationError.isEmpty ? "Spotify playback verification failed." : verificationError)
                    showShortSystemResponse("i opened Spotify search, but it didn't start playing.")
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "\(backend.executorID).spotify_search_play_not_playing",
                        fields: [
                            "executor": backend.executorID,
                            "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                            "appName": request.appName,
                            "query": query,
                            "playerState": playerState,
                            "error": errorText
                        ]
                    )
                    markRequestCompleted(
                        route: route,
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": backend.executorID,
                            "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                            "appName": request.appName,
                            "query": query,
                            "playerState": playerState,
                            "error": errorText
                        ]
                    )
                    return
                }
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).spotify_search_play",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "playerState": playerState,
                        "instruction": request.instruction
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "playerState": playerState
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "\(backend.executorID).spotify_search_play_error",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "error": error.localizedDescription
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func runSystemVolumeControl(_ action: OpenClickySystemVolumeControlAction, instruction: String) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "native_cua.system_volume"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "CoreAudio default output volume",
                "controller": "OpenClickySystemOutputVolume",
                "action": action.rawValue,
                "requiresAccessibility": false,
                "requiresSystemEventsAutomation": false
            ]
        )

        let currentVolume = OpenClickySystemOutputVolume.currentScalar()
        let targetVolume: Float
        let acknowledgement: String
        switch action.kind {
        case .volumeUp:
            targetVolume = min((currentVolume ?? 0.5) + 0.1, 1.0)
            acknowledgement = "turned system volume up."
        case .volumeDown:
            targetVolume = max((currentVolume ?? 0.5) - 0.1, 0.0)
            acknowledgement = "turned system volume down."
        case .mute:
            targetVolume = 0
            acknowledgement = "muted system volume."
        case .setVolume:
            let percent = min(100, max(0, action.volumePercent ?? 50))
            targetVolume = Float(percent) / 100
            acknowledgement = "set system volume to \(percent) percent."
        }

        let didApply = OpenClickySystemOutputVolume.setScalar(targetVolume)
        if didApply {
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: instruction
            )
            showShortSystemResponse(acknowledgement)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.system_volume",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "controller": "OpenClickySystemOutputVolume",
                    "action": action.rawValue,
                    "previousVolume": currentVolume.map { Double($0) } ?? -1,
                    "targetVolume": Double(targetVolume),
                    "requiresAccessibility": false,
                    "requiresSystemEventsAutomation": false
                ]
            )
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "action": action.rawValue,
                    "targetVolume": Double(targetVolume)
                ]
            )
        } else {
            let errorText = "default output volume is unavailable or not settable for the current audio device"
            showShortSystemResponse("System volume hit a blocker: \(errorText).")
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.system_volume_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "controller": "OpenClickySystemOutputVolume",
                    "action": action.rawValue,
                    "error": errorText,
                    "requiresAccessibility": false,
                    "requiresSystemEventsAutomation": false
                ]
            )
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "action": action.rawValue,
                    "error": errorText
                ]
            )
        }
    }

    func runSpotifyPlaybackControl(
        _ action: OpenClickySpotifyPlaybackControlAction,
        request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).spotify_playback_control"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "selectedComputerUseBackend": backend.rawValue,
                "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                "controller": "/usr/bin/osascript",
                "appName": request.appName,
                "action": action.rawValue
            ]
        )

        let appleScriptCommand: String
        let acknowledgement: String
        switch action.kind {
        case .play:
            appleScriptCommand = "play"
            acknowledgement = "playing Spotify."
        case .pause:
            appleScriptCommand = "pause"
            acknowledgement = "paused Spotify."
        case .playPause:
            appleScriptCommand = "playpause"
            acknowledgement = "toggled Spotify playback."
        case .next:
            appleScriptCommand = "next track"
            acknowledgement = "skipped Spotify."
        case .previous:
            appleScriptCommand = "previous track"
            acknowledgement = "went back in Spotify."
        case .shuffleOn:
            appleScriptCommand = "set shuffling to true"
            acknowledgement = "turned shuffle on in Spotify."
        case .shuffleOff:
            appleScriptCommand = "set shuffling to false"
            acknowledgement = "turned shuffle off in Spotify."
        case .repeatOn:
            appleScriptCommand = "set repeating to true"
            acknowledgement = "turned repeat on in Spotify."
        case .repeatOff:
            appleScriptCommand = "set repeating to false"
            acknowledgement = "turned repeat off in Spotify."
        case .volumeUp:
            appleScriptCommand = """
            set currentVolume to sound volume
            if currentVolume > 90 then
                set sound volume to 100
            else
                set sound volume to currentVolume + 10
            end if
            """
            acknowledgement = "turned Spotify volume up."
        case .volumeDown:
            appleScriptCommand = """
            set currentVolume to sound volume
            if currentVolume < 10 then
                set sound volume to 0
            else
                set sound volume to currentVolume - 10
            end if
            """
            acknowledgement = "turned Spotify volume down."
        case .volumeMute:
            appleScriptCommand = "set sound volume to 0"
            acknowledgement = "muted Spotify."
        case .volumeSet:
            let volumePercent = min(100, max(0, action.volumePercent ?? 50))
            appleScriptCommand = "set sound volume to \(volumePercent)"
            acknowledgement = "set Spotify volume to \(volumePercent) percent."
        }

        let script = """
        tell application "Spotify"
            activate
            \(appleScriptCommand)
        end tell
        """

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                OpenClickyLocalAutomationRunner.runAppleScript(script)
            }.value
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.terminationStatus == 0 {
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: request.instruction
                )
                showShortSystemResponse(acknowledgement)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).spotify_playback_control",
                    fields: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue,
                        "output": output
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue
                    ]
                )
            } else {
                let errorText = errorOutput.isEmpty ? "Spotify automation failed." : errorOutput
                showShortSystemResponse("Spotify hit a blocker: \(errorText)")
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "\(backend.executorID).spotify_playback_control_error",
                    fields: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue,
                        "error": errorText
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue,
                        "error": errorText
                    ]
                )
            }
        }
    }

    func searchInApplicationUsingSelectedComputerUse(
        _ request: OpenClickyCompositeAppSearchActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).composite_app_search"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "executionMethod": backend == .backgroundComputerUse
                    ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                    : "OpenClickyNativeComputerUseController.pressKey/typeText",
                "controller": backend == .backgroundComputerUse
                    ? "OpenClickyBackgroundComputerUseController"
                    : "OpenClickyNativeComputerUseController",
                "appName": request.appName,
                "query": request.query
            ]
        )

        let appRequest = OpenClickyAppOpenRequest(
            appName: request.appName,
            instruction: "Open \(request.appName)."
        )
        guard openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false) else {
            showShortSystemResponse("i couldn't open \(request.appName) for that search.")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "launchApplication(named:)",
                    "appName": request.appName,
                    "query": request.query,
                    "error": "Application could not be opened"
                ]
            )
            return
        }

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching \(request.appName) for \(request.query).",
            contextTitle: request.instruction
        )
        showShortSystemResponse("searching \(request.appName) for \(request.query).")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            do {
                try await pressKeyInApplication("f", modifiers: ["command"], appName: request.appName, backend: backend)
                try? await Task.sleep(nanoseconds: 150_000_000)
                try await pressKeyInApplication("a", modifiers: ["command"], appName: request.appName, backend: backend)
                try await typeTextInApplication(request.query, appName: request.appName, backend: backend)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).composite_app_search",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query,
                        "instruction": request.instruction
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "\(backend.executorID).composite_app_search_error",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query,
                        "error": error.localizedDescription
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func pressKeyInApplicationUsingSelectedComputerUse(
        _ request: OpenClickyNativeKeyPressRequest,
        appName: String,
        instruction: String,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).composite_app_key"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "executionMethod": backend == .backgroundComputerUse
                    ? "BackgroundComputerUse /v1/press_key"
                    : "OpenClickyNativeComputerUseController.pressKey",
                "controller": backend == .backgroundComputerUse
                    ? "OpenClickyBackgroundComputerUseController"
                    : "OpenClickyNativeComputerUseController",
                "appName": appName,
                "key": request.key,
                "modifiers": request.modifiers.joined(separator: ",")
            ]
        )

        let appRequest = OpenClickyAppOpenRequest(
            appName: appName,
            instruction: "Open \(appName)."
        )
        guard openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false) else {
            showShortSystemResponse("i couldn't open \(appName) for that key press.")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "launchApplication(named:)",
                    "appName": appName,
                    "key": request.key,
                    "error": "Application could not be opened"
                ]
            )
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            do {
                try await pressKeyInApplication(
                    request.key,
                    modifiers: request.modifiers,
                    appName: appName,
                    backend: backend
                )
                let modifierText = request.modifiers.isEmpty ? "" : request.modifiers.joined(separator: " ") + " "
                let acknowledgement = "pressed \(modifierText)\(request.key) in \(appName)."
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: instruction
                )
                showShortSystemResponse(acknowledgement)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).composite_app_key",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key"
                            : "OpenClickyNativeComputerUseController.pressKey",
                        "appName": appName,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key"
                            : "OpenClickyNativeComputerUseController.pressKey",
                        "appName": appName,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
            } catch {
                showShortSystemResponse("\(appName) key press hit a blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key"
                            : "OpenClickyNativeComputerUseController.pressKey",
                        "appName": appName,
                        "key": request.key,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func pressKeyInApplication(
        _ key: String,
        modifiers: [String],
        appName: String,
        backend: OpenClickyComputerUseBackendID
    ) async throws {
        switch backend {
        case .backgroundComputerUse:
            _ = try await backgroundComputerUseController.pressKey(
                key,
                modifiers: modifiers,
                targetAppName: appName
            )
        case .nativeSwift:
            guard ensureNativeComputerUseEnabledOrRefuse(spokenAction: "press that key") else {
                throw NSError(
                    domain: "OpenClickyComputerUse",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Native computer use is disabled."]
                )
            }
            Self.activateRunningApplication(named: appName)
            guard let targetWindow = await waitForNativeComputerUseWindow(for: appName) else {
                throw NSError(
                    domain: "OpenClickyCompositeAppAction",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No \(appName) window available"]
                )
            }
            try nativeComputerUseController.pressKey(key, modifiers: modifiers, toPid: targetWindow.pid)
        }
    }

    func typeTextInApplication(
        _ text: String,
        appName: String,
        backend: OpenClickyComputerUseBackendID
    ) async throws {
        switch backend {
        case .backgroundComputerUse:
            _ = try await backgroundComputerUseController.typeText(text, targetAppName: appName)
        case .nativeSwift:
            guard ensureNativeComputerUseEnabledOrRefuse(spokenAction: "type that") else {
                throw NSError(
                    domain: "OpenClickyComputerUse",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Native computer use is disabled."]
                )
            }
            Self.activateRunningApplication(named: appName)
            guard let targetWindow = await waitForNativeComputerUseWindow(for: appName) else {
                throw NSError(
                    domain: "OpenClickyCompositeAppAction",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No \(appName) window available"]
                )
            }
            try nativeComputerUseController.typeText(text, delayMilliseconds: 8, toPid: targetWindow.pid)
        }
    }

    func nativeComputerUseWindow(for appName: String) -> OpenClickyComputerUseWindowInfo? {
        let windows = nativeComputerUseController.visibleWindows()
        if let matchingWindow = windows.first(where: { Self.applicationOwner($0.owner, matches: appName) }) {
            return matchingWindow
        }
        if let focusedWindow = nativeComputerUseController.refreshFocusedTarget(),
           Self.applicationOwner(focusedWindow.owner, matches: appName) {
            return focusedWindow
        }
        return nil
    }

    func waitForNativeComputerUseWindow(
        for appName: String,
        timeout: TimeInterval = 3.0,
        pollIntervalNanoseconds: UInt64 = 150_000_000
    ) async -> OpenClickyComputerUseWindowInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let targetWindow = nativeComputerUseWindow(for: appName) {
                return targetWindow
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        } while !Task.isCancelled
        return nativeComputerUseWindow(for: appName)
    }

    @discardableResult
    func openRequestedApplication(
        _ request: OpenClickyAppOpenRequest,
        shouldSpeak: Bool = true,
        logTiming: Bool = true
    ) -> Bool {
        let executionStartedAt = logTiming
            ? markRequestExecutionStarted(
                route: "native_cua.open_app",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "launchApplication(named:)",
                    "controller": "NSWorkspace.openApplication_or_open_a",
                    "appName": request.appName,
                    "shouldSpeak": shouldSpeak
                ]
            )
            : Date()
        if launchApplication(named: request.appName) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.open_app",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "launchApplication(named:)",
                    "controller": "NSWorkspace.openApplication_or_open_a",
                    "appName": request.appName,
                    "instruction": request.instruction
                ]
            )
            if shouldSpeak {
                showShortSystemResponse("opening \(request.appName).")
            }
            if logTiming {
                markRequestCompleted(
                    route: "native_cua.open_app",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "launchApplication(named:)",
                        "controller": "NSWorkspace.openApplication_or_open_a",
                        "appName": request.appName
                    ]
                )
            }
            return true
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.open_app.failed",
            fields: [
                "executor": "native_cua",
                "executionMethod": "launchApplication(named:)",
                "controller": "NSWorkspace.openApplication_or_open_a",
                "appName": request.appName,
                "instruction": request.instruction
            ]
        )

        if shouldSpeak {
            showShortSystemResponse("i couldn't open \(request.appName) through native CUA.")
        }
        if logTiming {
            markRequestCompleted(
                route: "native_cua.open_app",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "launchApplication(named:)",
                    "controller": "NSWorkspace.openApplication_or_open_a",
                    "appName": request.appName
                ]
            )
        }
        return false
    }

    func openRequestedFolder(_ request: OpenClickyFolderOpenRequest, shouldSpeak: Bool = true) {
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.open_folder",
            extra: [
                "executor": "native_cua",
                "executionMethod": "NSWorkspace.open",
                "controller": "NSWorkspace",
                "path": request.url.path,
                "shouldSpeak": shouldSpeak
            ]
        )
        NSWorkspace.shared.open(request.url)
        currentFolderContextURL = request.url.standardizedFileURL
        OpenClickyDirectActionMemoryStore.shared.recordFolderShortcut(
            instruction: request.instruction,
            url: request.url,
            displayName: request.displayName
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "opening \(request.displayName).",
            contextTitle: request.instruction
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.open_folder",
            fields: [
                "executor": "native_cua",
                "executionMethod": "NSWorkspace.open",
                "controller": "NSWorkspace",
                "path": request.url.path,
                "instruction": request.instruction
            ]
        )
        if shouldSpeak {
            showShortSystemResponse("opening \(request.displayName).")
        }
        markRequestCompleted(
            route: "native_cua.open_folder",
            executionStartedAt: executionStartedAt,
            extra: [
                "executor": "native_cua",
                "executionMethod": "NSWorkspace.open",
                "controller": "NSWorkspace",
                "path": request.url.path
            ]
        )
    }

    func folderOpenRequest(from transcript: String) -> OpenClickyFolderOpenRequest? {
        if let request = Self.localFolderOpenRequest(from: transcript) {
            return request
        }

        guard let currentFolderContextURL,
              let relativeRequest = Self.relativeFolderOpenRequest(
                from: transcript,
                baseURL: currentFolderContextURL
              ) else {
            return nil
        }

        return relativeRequest
    }

    func addReminderUsingNativeAutomation(_ request: OpenClickyReminderAddRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.reminder_add",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                "controller": "/usr/bin/osascript",
                "automationTarget": "Reminders",
                "title": request.title
            ]
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "adding \(request.title) to Reminders.",
            contextTitle: "Native CUA"
        )

        let title = request.title
        let instruction = request.instruction
        Task.detached(priority: .userInitiated) {
            let titleLiteral = OpenClickyLocalAutomationRunner.appleScriptStringLiteral(title)
            let script = """
            tell application "Reminders"
                set targetList to default list
                make new reminder at end of reminders of targetList with properties {name:\(titleLiteral)}
            end tell
            """
            let result = OpenClickyLocalAutomationRunner.runAppleScript(script)

            await MainActor.run {
                if result.terminationStatus == 0 {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "outgoing",
                        event: "native_cua.reminder_added",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title,
                            "instruction": instruction
                        ]
                    )
                    self.showShortSystemResponse("added \(title) to Reminders.")
                    self.markRequestCompleted(
                        route: "native_cua.reminder_add",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title
                        ]
                    )
                } else {
                    let message = Self.nativeAutomationErrorMessage(
                        appName: "Reminders",
                        result: result
                    )
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.reminder_add_error",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title,
                            "instruction": instruction,
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                    self.showShortSystemResponse(message)
                    self.markRequestCompleted(
                        route: "native_cua.reminder_add",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title,
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                }
            }
        }
    }

    func countRemindersUsingNativeAutomation(_ request: OpenClickyReminderCountRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.reminder_count",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                "controller": "/usr/bin/osascript",
                "automationTarget": "Reminders"
            ]
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "checking Reminders directly.",
            contextTitle: "Native CUA"
        )

        let instruction = request.instruction
        Task.detached(priority: .userInitiated) {
            let script = """
            tell application "Reminders"
                set openReminderCount to count of (reminders whose completed is false)
            end tell
            return openReminderCount as text
            """
            let result = OpenClickyLocalAutomationRunner.runAppleScript(script)

            await MainActor.run {
                if result.terminationStatus == 0 {
                    let rawCount = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let count = Int(rawCount) ?? 0
                    let noun = count == 1 ? "open reminder" : "open reminders"
                    let response = "you have \(count) \(noun)."
                    self.latestVoiceResponseCard = ClickyResponseCard(
                        source: .voice,
                        rawText: response,
                        contextTitle: "Reminders"
                    )
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "outgoing",
                        event: "native_cua.reminder_count",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "count": count,
                            "instruction": instruction
                        ]
                    )
                    self.showShortSystemResponse(response)
                    self.markRequestCompleted(
                        route: "native_cua.reminder_count",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "count": count
                        ]
                    )
                } else {
                    let message = Self.nativeAutomationErrorMessage(
                        appName: "Reminders",
                        result: result
                    )
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.reminder_count_error",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "instruction": instruction,
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                    self.showShortSystemResponse(message)
                    self.markRequestCompleted(
                        route: "native_cua.reminder_count",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                }
            }
        }
    }

    func searchMessagesUsingSelectedComputerUse(_ request: OpenClickyMessagesSearchRequest) {
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            searchMessagesUsingBackgroundComputerUse(request)
        case .nativeSwift:
            searchMessagesUsingNativeComputerUse(request)
        }
    }

    func typeTextUsingSelectedComputerUse(_ request: OpenClickyNativeTypeRequest) {
        showActiveControlGlowForFocusedWindowOrScreen(label: "Typing", duration: 3.0)
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            typeTextUsingBackgroundComputerUse(request)
        case .nativeSwift:
            typeTextUsingNativeComputerUse(request)
        }
    }

    func pressKeyUsingSelectedComputerUse(_ request: OpenClickyNativeKeyPressRequest, shouldSpeak: Bool = true) {
        showActiveControlGlowForFocusedWindowOrScreen(label: "Key press", duration: 1.8)
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            pressKeyUsingBackgroundComputerUse(request, shouldSpeak: shouldSpeak)
        case .nativeSwift:
            pressKeyUsingNativeComputerUse(request, shouldSpeak: shouldSpeak)
        }
    }

    func clickUsingSelectedComputerUse(_ request: OpenClickyNativeClickRequest) {
        showActiveControlGlowForFocusedWindowOrScreen(label: request.targetPhrase ?? "Click target", duration: 2.2)
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            clickUsingBackgroundComputerUse(request)
        case .nativeSwift:
            clickUsingNativeComputerUse(request)
        }
    }

    /// M10: native computer use "disabled" is the user's authoritative choice.
    /// Previously every action path force-enabled it (`setEnabled(true)`),
    /// silently overriding the preference and persisting the override. Now
    /// action paths call this and bail with a spoken prompt when disabled.
    /// Returns true when enabled (action may proceed).
    @discardableResult
    func ensureNativeComputerUseEnabledOrRefuse(spokenAction: String) -> Bool {
        if nativeComputerUseController.isEnabled { return true }
        showShortSystemResponse("computer use is turned off. turn it on in settings if you want me to \(spokenAction).")
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "error",
            event: "native_cua.refused_disabled",
            fields: [
                "executor": "native_cua",
                "reason": "Native computer use is disabled; action refused instead of force-enabling."
            ]
        )
        return false
    }

    func clickUsingBackgroundComputerUse(_ request: OpenClickyNativeClickRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.click",
            timing: timing,
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                "controller": "OpenClickyBackgroundComputerUseController",
                "targetPhrase": request.targetPhrase ?? ""
            ]
        )

        Task { @MainActor in
            do {
                // Background Computer Use clicks in WINDOW-SCREENSHOT pixel
                // space, not global display points. Capture the BCU window,
                // point against THAT screenshot, then send the raw screenshot
                // coordinate straight to /v1/click.
                let capture = try await backgroundComputerUseController.captureFrontmostWindowAsJPEG()
                let pointingCapture = CompanionScreenCapture(
                    imageData: capture.imageData,
                    label: capture.displayTitle,
                    appName: request.targetPhrase,
                    bundleIdentifier: capture.bundleID,
                    isCursorScreen: false,
                    displayWidthInPoints: capture.screenshotWidthInPixels,
                    displayHeightInPoints: capture.screenshotHeightInPixels,
                    displayNativeWidthInPixels: capture.screenshotWidthInPixels,
                    displayNativeHeightInPixels: capture.screenshotHeightInPixels,
                    displayFrame: .zero,
                    screenshotWidthInPixels: capture.screenshotWidthInPixels,
                    screenshotHeightInPixels: capture.screenshotHeightInPixels
                )
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                let response = try await analyzeComputerUsePointingResponse(
                    image: (data: capture.imageData, label: pointingCapture.label + dimensionInfo),
                    capture: pointingCapture,
                    systemPrompt: Self.nativeClickPointingSystemPrompt,
                    userPrompt: request.targetDescription,
                    onTextChunk: { _ in }
                )
                let parseResult = Self.parsePointingCoordinates(from: response)
                guard let pointCoordinate = parseResult.coordinate else {
                    showShortSystemResponse("i couldn't find that to click.")
                    markRequestCompleted(
                        route: "background_computer_use.click",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "background_computer_use",
                            "executionMethod": "analyzeComputerUsePointingResponse",
                            "targetPhrase": request.targetPhrase ?? "",
                            "error": "No click coordinate"
                        ]
                    )
                    return
                }

                let result = try await backgroundComputerUseController.click(
                    at: pointCoordinate,
                    window: capture.windowID,
                    targetAppName: request.targetPhrase,
                    stateToken: capture.stateToken
                )
                let spokenLabel = parseResult.elementLabel ?? request.targetPhrase
                showShortSystemResponse(spokenLabel.map { "clicked \($0)." } ?? "clicked that.")
                markRequestCompleted(
                    route: "background_computer_use.click",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "window": capture.windowID,
                        "x": Int(pointCoordinate.x),
                        "y": Int(pointCoordinate.y),
                        "summary": result.summary
                    ]
                )
            } catch {
                showShortSystemResponse("i couldn't click that through background computer use.")
                markRequestCompleted(
                    route: "background_computer_use.click",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func clickUsingNativeComputerUse(_ request: OpenClickyNativeClickRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let pointingResolver = Self.computerUsePointingResolver(
            selectedVoiceModelID: selectedModel,
            selectedComputerUseModelID: selectedComputerUseModel
        )
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.click",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.click",
                "controller": "OpenClickyNativeComputerUseController",
                "targetPhrase": request.targetPhrase ?? "",
                "prefersLastPointedElement": request.prefersLastPointedElement,
                "pointingResolver": pointingResolver.rawValue,
                "pointingModel": selectedComputerUseModel
            ]
        )

        if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "click that") {
            return
        }

        if request.prefersLastPointedElement,
           let point = lastPointedElementScreenLocation,
           let pointedAt = lastPointedElementAt,
           Date().timeIntervalSince(pointedAt) <= 120 {
            performNativeClick(
                at: point,
                displayFrame: lastPointedElementDisplayFrame,
                label: lastPointedElementLabel,
                request: request,
                executionStartedAt: executionStartedAt,
                timing: timing
            )
            return
        }

        Task { @MainActor in
            do {
                let screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()
                let liveMouseLocation = NSEvent.mouseLocation
                let targetScreenCapture = screenCaptures.first { $0.displayFrame.contains(liveMouseLocation) }
                    ?? screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first

                guard let targetScreenCapture else {
                    throw NSError(
                        domain: "OpenClickyNativeClick",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No screen capture available"]
                    )
                }

                let dimensionInfo = " (image dimensions: \(targetScreenCapture.screenshotWidthInPixels)x\(targetScreenCapture.screenshotHeightInPixels) pixels)"
                let response = try await analyzeComputerUsePointingResponse(
                    image: (data: targetScreenCapture.imageData, label: targetScreenCapture.label + dimensionInfo),
                    capture: targetScreenCapture,
                    systemPrompt: Self.nativeClickPointingSystemPrompt,
                    userPrompt: request.targetDescription,
                    onTextChunk: { _ in }
                )
                let parseResult = Self.parsePointingCoordinates(from: response)
                guard let pointCoordinate = parseResult.coordinate else {
                    showShortSystemResponse("i couldn't find that to click.")
                    markRequestCompleted(
                        route: "native_cua.click",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "analyzeComputerUsePointingResponse",
                            "controller": "OpenClickyNativeComputerUseController",
                            "targetPhrase": request.targetPhrase ?? "",
                            "error": "No click coordinate"
                        ]
                    )
                    return
                }

                let globalLocation = globalPoint(fromScreenshotPoint: pointCoordinate, in: targetScreenCapture)
                performNativeClick(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel ?? request.targetPhrase,
                    request: request,
                    executionStartedAt: executionStartedAt,
                    timing: timing
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.click_error",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.click",
                        "controller": "OpenClickyNativeComputerUseController",
                        "targetPhrase": request.targetPhrase ?? "",
                        "error": error.localizedDescription
                    ]
                )
                showShortSystemResponse("clicking hit a blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "native_cua.click",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.click",
                        "controller": "OpenClickyNativeComputerUseController",
                        "targetPhrase": request.targetPhrase ?? "",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func performNativeClick(
        at point: CGPoint,
        displayFrame: CGRect?,
        label: String?,
        request: OpenClickyNativeClickRequest,
        executionStartedAt: Date,
        timing: OpenClickyRequestTiming?
    ) {
        do {
            try nativeComputerUseController.click(at: point)
            detectedElementScreenLocation = point
            detectedElementDisplayFrame = displayFrame
            detectedElementBubbleText = Self.pointingBubbleText(for: label)
            showActiveControlGlow(
                around: Self.controlTargetGlowRect(centeredOn: point, within: displayFrame),
                label: label ?? request.targetPhrase,
                duration: 2.4
            )
            rememberPointedElement(at: point, displayFrame: displayFrame, label: label)
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: "clicked \(label ?? request.targetPhrase ?? "that").",
                contextTitle: request.targetDescription
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.click",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "label": label ?? "",
                    "x": Int(point.x),
                    "y": Int(point.y)
                ]
            )
            showShortSystemResponse("clicked \(label ?? request.targetPhrase ?? "that").")
            markRequestCompleted(
                route: "native_cua.click",
                executionStartedAt: executionStartedAt,
                timing: timing,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "label": label ?? "",
                    "x": Int(point.x),
                    "y": Int(point.y)
                ]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.click_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "error": error.localizedDescription
                ]
            )
            showShortSystemResponse("native clicking hit a blocker: \(error.localizedDescription)")
            markRequestCompleted(
                route: "native_cua.click",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "error": error.localizedDescription
                ]
            )
        }
    }

    func searchMessagesUsingBackgroundComputerUse(_ request: OpenClickyMessagesSearchRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.messages_search",
            timing: timing,
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                "controller": "OpenClickyBackgroundComputerUseController",
                "appName": "Messages",
                "personName": request.personName,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )
        let appRequest = OpenClickyAppOpenRequest(appName: "Messages", instruction: "Open Messages.")
        _ = openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false)
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching Messages for \(request.personName).",
            contextTitle: "Background Computer Use"
        )

        let personName = request.personName
        let instruction = request.instruction
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "background_computer_use.messages_search_started",
            fields: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                "controller": "OpenClickyBackgroundComputerUseController",
                "appName": "Messages",
                "personName": personName,
                "instruction": instruction,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )

        Task { @MainActor in
            do {
                try? await Task.sleep(nanoseconds: 650_000_000)
                Self.activateRunningApplication(named: "Messages")
                try? await Task.sleep(nanoseconds: 200_000_000)
                let openSearch = try await backgroundComputerUseController.pressKey(
                    "f",
                    modifiers: ["command"],
                    targetAppName: "Messages"
                )
                try? await Task.sleep(nanoseconds: 150_000_000)
                let selectAll = try await backgroundComputerUseController.pressKey(
                    "a",
                    modifiers: ["command"],
                    targetAppName: "Messages"
                )
                let typed = try await backgroundComputerUseController.typeText(
                    personName,
                    targetAppName: "Messages"
                )
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "background_computer_use.messages_search",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "instruction": instruction,
                        "openSearch": openSearch.summary,
                        "selectAll": selectAll.summary,
                        "typed": typed.summary,
                        "windowID": typed.windowID
                    ]
                )
                showShortSystemResponse("searching Messages for \(personName).")
                markRequestCompleted(
                    route: "background_computer_use.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "windowID": typed.windowID
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "background_computer_use.messages_search_error",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "instruction": instruction,
                        "runtimeStatus": backgroundComputerUseController.status.summary,
                        "error": error.localizedDescription
                    ]
                )
                showShortSystemResponse("Background Computer Use hit a blocker searching Messages: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "background_computer_use.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func typeTextUsingBackgroundComputerUse(_ request: OpenClickyNativeTypeRequest) {
        interruptCurrentVoiceResponse()
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.type_text",
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/type_text",
                "controller": "OpenClickyBackgroundComputerUseController",
                "textLength": request.text.count,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )

        Task { @MainActor in
            do {
                let result = try await backgroundComputerUseController.typeText(request.text)
                let acknowledgement = "typed that with Background Computer Use."
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: request.targetDescription
                )
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "background_computer_use.type_text",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "summary": result.summary,
                        "textLength": request.text.count
                    ]
                )
                showShortSystemResponse(acknowledgement)
                markRequestCompleted(
                    route: "background_computer_use.type_text",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "textLength": request.text.count
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "background_computer_use.type_text_error",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "runtimeStatus": backgroundComputerUseController.status.summary,
                        "error": error.localizedDescription
                    ]
                )
                showShortSystemResponse("Background Computer Use typing hit a blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "background_computer_use.type_text",
                    executionStartedAt: executionStartedAt,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func pressKeyUsingBackgroundComputerUse(_ request: OpenClickyNativeKeyPressRequest, shouldSpeak: Bool = true) {
        if shouldSpeak {
            interruptCurrentVoiceResponse()
        }
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.press_key",
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/press_key",
                "controller": "OpenClickyBackgroundComputerUseController",
                "key": request.key,
                "modifiers": request.modifiers.joined(separator: ","),
                "shouldSpeak": shouldSpeak,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )

        Task { @MainActor in
            do {
                let result = try await backgroundComputerUseController.pressKey(
                    request.key,
                    modifiers: request.modifiers
                )
                let modifierText = request.modifiers.isEmpty ? "" : request.modifiers.joined(separator: " ") + " "
                let acknowledgement = "pressed \(modifierText)\(request.key) with Background Computer Use."
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: request.targetDescription
                )
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "background_computer_use.press_key",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "summary": result.summary,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
                if shouldSpeak {
                    showShortSystemResponse(acknowledgement)
                }
                markRequestCompleted(
                    route: "background_computer_use.press_key",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "background_computer_use.press_key_error",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "runtimeStatus": backgroundComputerUseController.status.summary,
                        "key": request.key,
                        "error": error.localizedDescription
                    ]
                )
                if shouldSpeak {
                    showShortSystemResponse("Background Computer Use key press hit a blocker: \(error.localizedDescription)")
                }
                markRequestCompleted(
                    route: "background_computer_use.press_key",
                    executionStartedAt: executionStartedAt,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "key": request.key,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func searchMessagesUsingNativeComputerUse(_ request: OpenClickyMessagesSearchRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.messages_search",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                "controller": "OpenClickyNativeComputerUseController",
                "appName": "Messages",
                "personName": request.personName
            ]
        )
        let appRequest = OpenClickyAppOpenRequest(appName: "Messages", instruction: "Open Messages.")
        _ = openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false)
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching Messages for \(request.personName).",
            contextTitle: "Native CUA"
        )

        let personName = request.personName
        let instruction = request.instruction
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.messages_search_started",
            fields: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                "controller": "OpenClickyNativeComputerUseController",
                "appName": "Messages",
                "personName": personName,
                "instruction": instruction
            ]
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            Self.activateRunningApplication(named: "Messages")

            if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "search messages") {
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let targetWindow = nativeComputerUseController.refreshFocusedTarget() else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.messages_search_error",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "instruction": instruction,
                        "error": "No focused Messages window"
                    ]
                )
                showShortSystemResponse("opened Messages, but I couldn't focus its search field.")
                markRequestCompleted(
                    route: "native_cua.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "error": "No focused Messages window"
                    ]
                )
                return
            }

            do {
                try nativeComputerUseController.pressKey("f", modifiers: ["command"], toPid: targetWindow.pid)
                try? await Task.sleep(nanoseconds: 150_000_000)
                try nativeComputerUseController.pressKey("a", modifiers: ["command"], toPid: targetWindow.pid)
                try nativeComputerUseController.typeText(personName, delayMilliseconds: 8, toPid: targetWindow.pid)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "native_cua.messages_search",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote,
                        "instruction": instruction
                    ]
                )
                showShortSystemResponse("searching Messages for \(personName).")
                markRequestCompleted(
                    route: "native_cua.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.messages_search_error",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote,
                        "instruction": instruction,
                        "error": error.localizedDescription
                    ]
                )
                showShortSystemResponse("Messages search hit a native CUA blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "native_cua.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func typeTextUsingNativeComputerUse(_ request: OpenClickyNativeTypeRequest) {
        interruptCurrentVoiceResponse()
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.type_text",
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                "controller": "OpenClickyNativeComputerUseController",
                "textLength": request.text.count
            ]
        )

        if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "type that") {
            return
        }

        guard let targetWindow = nativeComputerUseController.refreshFocusedTarget() else {
            showShortSystemResponse("i don't have a target window to type into.")
            markRequestCompleted(
                route: "native_cua.type_text",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                    "controller": "OpenClickyNativeComputerUseController",
                    "error": "No focused target window"
                ]
            )
            return
        }

        do {
            try nativeComputerUseController.typeText(request.text, delayMilliseconds: 10, toPid: targetWindow.pid)
            let target = targetWindow.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let acknowledgement = target.isEmpty ? "typed that into the focused window." : "typed that into \(target)."
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: request.targetDescription
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.type_text",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "textLength": request.text.count
                ]
            )
            showShortSystemResponse(acknowledgement)
            markRequestCompleted(
                route: "native_cua.type_text",
                executionStartedAt: executionStartedAt,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "textLength": request.text.count
                ]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.type_text_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "error": error.localizedDescription
                ]
            )
            showShortSystemResponse("native typing hit a blocker: \(error.localizedDescription)")
            markRequestCompleted(
                route: "native_cua.type_text",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    func pressKeyUsingNativeComputerUse(_ request: OpenClickyNativeKeyPressRequest, shouldSpeak: Bool = true) {
        if shouldSpeak {
            interruptCurrentVoiceResponse()
        }
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.press_key",
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                "controller": "OpenClickyNativeComputerUseController",
                "key": request.key,
                "modifiers": request.modifiers.joined(separator: ","),
                "shouldSpeak": shouldSpeak
            ]
        )

        if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "press that key") {
            return
        }

        guard let targetWindow = nativeComputerUseController.refreshFocusedTarget() else {
            if shouldSpeak {
                showShortSystemResponse("i don't have a target window for that key press.")
            }
            markRequestCompleted(
                route: "native_cua.press_key",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                    "controller": "OpenClickyNativeComputerUseController",
                    "key": request.key,
                    "error": "No focused target window"
                ]
            )
            return
        }

        do {
            try nativeComputerUseController.pressKey(request.key, modifiers: request.modifiers, toPid: targetWindow.pid)
            let modifierText = request.modifiers.isEmpty ? "" : request.modifiers.joined(separator: " ") + " "
            let target = targetWindow.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let acknowledgement = target.isEmpty
                ? "pressed \(modifierText)\(request.key) in the focused window."
                : "pressed \(modifierText)\(request.key) in \(target)."
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: request.targetDescription
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.press_key",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "modifiers": request.modifiers.joined(separator: ",")
                ]
            )
            if shouldSpeak {
                showShortSystemResponse(acknowledgement)
            }
            markRequestCompleted(
                route: "native_cua.press_key",
                executionStartedAt: executionStartedAt,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "modifiers": request.modifiers.joined(separator: ",")
                ]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.press_key_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "error": error.localizedDescription
                ]
            )
            if shouldSpeak {
                showShortSystemResponse("native key press hit a blocker: \(error.localizedDescription)")
            }
            markRequestCompleted(
                route: "native_cua.press_key",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    func launchApplication(named appName: String) -> Bool {
        if let appURL = Self.resolvedApplicationURL(named: appName) {
            Self.openApplication(at: appURL, appName: appName)
            return true
        }

        return runOpenApplication(arguments: ["-a", appName])
    }

    static func resolvedApplicationURL(named appName: String) -> URL? {
        for bundleIdentifier in applicationBundleIdentifiers(for: appName) {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return appURL
            }
        }

        return standardApplicationURL(named: appName)
    }

    static func openApplication(at appURL: URL, appName: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.open_app.activation_failed",
                    fields: [
                        "appName": appName,
                        "path": appURL.path,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func runOpenApplication(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("OpenClicky app open failed for arguments \(arguments): \(error)")
            return false
        }
    }
}
