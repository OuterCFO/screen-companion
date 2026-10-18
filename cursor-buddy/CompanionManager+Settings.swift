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
    func setAgentParkingPosition(_ position: AgentParkingPosition) {
        guard agentParkingPosition != position else { return }
        agentParkingPosition = position
        UserDefaults.standard.set(position.rawValue, forKey: AgentParkingPosition.userDefaultsKey)
        // Re-park the dock immediately if it's already on screen so the
        // user sees the change without having to spawn a new agent.
        showAgentDockWindowNearCurrentScreenIfShowing()
    }

    func setAgentParkingCalibrationOffset(_ offset: CGSize, for position: AgentParkingPosition) {
        AgentParkingPosition.setCalibrationOffset(offset, for: position)
        showAgentDockWindowNearCurrentScreenIfShowing()
    }

    func showAgentDockWindowNearCurrentScreenIfShowing() {
        guard !agentDockItems.isEmpty else { return }
        showAgentDockWindowNearCurrentScreen()
    }

    func refreshAgentDockFollowBehavior() {
        let shouldAutoFollowCursor = !OpenClickyPresentationPolicy.menuBarOnly && agentDockItems.contains { item in
            item.status == .starting || item.status == .running
        }
        if shouldAutoFollowCursor {
            if agentDockFollowTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard !self.agentDockItems.isEmpty else { return }
                        guard !self.agentDockWindowManager.hasUserPinnedFrame else { return }
                        self.showAgentDockWindowNearCurrentScreen()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                agentDockFollowTimer = timer
            }
        } else {
            agentDockFollowTimer?.invalidate()
            agentDockFollowTimer = nil
        }
    }
    static let tutorObservationVoiceCooldown: TimeInterval = 90
    static func initialVoiceResponseModelID() -> String {
        let defaults = UserDefaults.standard
        let storedModel = defaults.string(forKey: "selectedVoiceResponseModel")

        let requestedModel = storedModel
            ?? defaults.string(forKey: "selectedClaudeModel")
            ?? OpenClickyModelCatalog.defaultVoiceResponseModelID
        let resolvedModel = OpenClickyModelCatalog.voiceResponseModel(withID: requestedModel).id

        // Persist alias migrations so retired IDs are not carried forward.
        if storedModel != resolvedModel {
            defaults.set(resolvedModel, forKey: "selectedVoiceResponseModel")
        }

        return resolvedModel
    }

    func setSelectedModel(_ model: String) {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: model)
        let resolvedModel = selectedVoiceResponseModel.id
        selectedModel = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "selectedVoiceResponseModel")
        applyVoiceResponseModelSettings(selectedVoiceResponseModel)
        answerProviders.warmUp(for: selectedVoiceResponseModel, systemPrompt: currentVoiceResponseSystemPrompt())
    }

    /// Coarse family for the bubble / notch selector (Apple / Codex / Claude).
    var selectedVoiceBackendFamily: OpenClickyVoiceBackendFamily? {
        OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel).provider.voiceBackendFamily
    }

    /// Select a terminal-first backend family, mapping to its default model.
    /// Unavailable families are ignored so selection stays discovery-gated.
    func setSelectedVoiceBackendFamily(_ family: OpenClickyVoiceBackendFamily) {
        guard OpenClickyProviderDiscovery.isAvailable(family) else { return }
        setSelectedModel(family.defaultModelID)
    }

    func setSelectedComputerUseModel(_ model: String) {
        let resolvedModel = OpenClickyModelCatalog.computerUseModel(withID: model).id
        selectedComputerUseModel = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "selectedComputerUseModel")
    }

    var selectedComputerUseBackend: OpenClickyComputerUseBackendID {
        OpenClickyComputerUseBackendID.resolving(selectedComputerUseBackendID)
    }

    func applyVoiceResponseModelSettings(_ modelOption: OpenClickyModelOption) {
        for provider in answerProviders.chain(for: modelOption) where provider.isAvailable { provider.prepare(for: modelOption) }
    }

    func setSelectedComputerUseBackend(_ backendID: String) {
        let backend = OpenClickyComputerUseBackendID.resolving(backendID)
        selectedComputerUseBackendID = backend.rawValue
        UserDefaults.standard.set(backend.rawValue, forKey: AppBundleConfiguration.userComputerUseBackendDefaultsKey)
        if backend == .backgroundComputerUse {
            backgroundComputerUseController.refreshStatus()
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "internal",
            event: "computer_use.backend_selected",
            fields: [
                "backend": backend.rawValue,
                "executor": backend.executorID
            ]
        )
    }

    func setNativeComputerUseEnabled(_ enabled: Bool) {
        nativeComputerUseController.setEnabled(enabled)
    }

    func refreshNativeComputerUseStatus() {
        nativeComputerUseController.refreshStatus()
    }

    func refreshNativeComputerUseFocusedTarget() {
        _ = nativeComputerUseController.refreshFocusedTarget()
    }

    func refreshBackgroundComputerUseStatus() {
        backgroundComputerUseController.refreshStatus()
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "internal",
            event: "background_computer_use.status_refreshed",
            fields: [
                "status": backgroundComputerUseController.status.summary,
                "manifestPath": backgroundComputerUseController.status.manifestPath
            ]
        )
    }

    func startBackgroundComputerUseRuntime() {
        backgroundComputerUseController.startRuntime()
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "background_computer_use.start_requested",
            fields: [
                "sourceRoot": backgroundComputerUseController.status.sourceRootPath,
                "manifestPath": backgroundComputerUseController.status.manifestPath
            ]
        )
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(OpenClickyMacPrivacyPermissionProbe.fullDiskAccessSettingsURL)
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(OpenClickyMacPrivacyPermissionProbe.automationSettingsURL)
    }

    func requestRemindersAutomationPermission() {
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.automation_probe.started",
            fields: [
                "target": "Reminders"
            ]
        )

        Task.detached(priority: .userInitiated) {
            let result = OpenClickyLocalAutomationRunner.runAppleScript("""
            tell application "Reminders"
                count reminders
            end tell
            """)

            await MainActor.run {
                if result.terminationStatus == 0 {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "outgoing",
                        event: "native_cua.automation_probe.ready",
                        fields: [
                            "target": "Reminders"
                        ]
                    )
                    self.showShortSystemResponse("Reminders automation is ready.")
                } else {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.automation_probe.blocked",
                        fields: [
                            "target": "Reminders",
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                    self.openAutomationSettings()
                    self.showShortSystemResponse(Self.nativeAutomationErrorMessage(appName: "Reminders", result: result))
                }
            }
        }
    }

    func requestSystemEventsAutomationPermission() {
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.automation_probe.started",
            fields: [
                "target": "System Events"
            ]
        )

        let isGranted = OpenClickyMacPrivacyPermissionProbe.hasSystemEventsAutomationPermission(prompt: true)
        hasSystemEventsAutomationPermission = isGranted

        if isGranted {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.automation_probe.ready",
                fields: [
                    "target": "System Events"
                ]
            )
            showShortSystemResponse("System Events automation is ready.")
        } else {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.automation_probe.blocked",
                fields: [
                    "target": "System Events",
                    "error": "Automation permission is missing or denied for com.apple.systemevents"
                ]
            )
            openAutomationSettings()
            showShortSystemResponse("System Events automation needs approval in Privacy & Security, Automation.")
        }
    }

    func showSettingsWindow() {
        settingsWindowManager.show(companionManager: self)
    }

    func showLogViewerWindow() {
        logViewerWindowManager.show()
    }

    func openOpenClickyDocument(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if Self.isMarkdownDocument(standardizedURL) {
            markdownViewerWindowManager.show(fileURL: standardizedURL)
        } else {
            NSWorkspace.shared.open(standardizedURL)
        }
    }

    func handleApplicationOpenURL(_ url: URL) {
        if url.isFileURL {
            openOpenClickyDocument(url)
            return
        }

        handleOpenClickyDeepLink(url)
    }

    /// Refreshes the menu bar task status after task or reply changes.
    func scheduleStatusSync() {
        agentMenuBarStatusManager.scheduleSync(companionManager: self)
    }

    func handleOpenClickyDeepLink(_ url: URL) {
        guard url.scheme == "openclicky" else { return }

        switch url.host {
        case "agents":
            showCodexHUD()
        case "agent":
            if let sessionIDString = url.pathComponents.dropFirst().first,
               let sessionID = UUID(uuidString: sessionIDString) {
                selectCodexAgentSession(sessionID)
            }
            showCodexHUD()
        case "settings":
            showSettingsWindow()
        case "logs":
            showLogViewerWindow()
        case "memory":
            showMemoryWindow()
        default:
            showSettingsWindow()
        }
    }

    func setTutorModeEnabled(_ enabled: Bool) {
        isTutorModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.tutorModeDefaultsKey)
        if enabled {
            showCursorOverlayIfAvailable()
            if runtimeMode == .menuBar {
                startTutorIdleObservation()
            }
        } else {
            stopTutorIdleObservation()
        }
    }

    func setAdvancedModeEnabled(_ enabled: Bool) {
        isAdvancedModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppBundleConfiguration.userAdvancedModeDefaultsKey)
        if !enabled {
            codexHUDWindowManager.hide()
        }
    }

    func setAnthropicAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey)
        claudeAPI.setAPIKey(AppBundleConfiguration.anthropicAPIKey())
    }

    func setVoiceTranscriptionProvider(_ providerID: String) {
        buddyDictationManager.setTranscriptionProvider(providerID)
    }

    func setCodexAgentAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey)
        openAIAPI.setAPIKey(AppBundleConfiguration.openAIAPIKey())
        codexAgentSessions.forEach { $0.stop(reason: "api_key_reconfigured") }
    }

    func persistOptionalSecret(_ value: String, defaultsKey: String) {
        AppBundleConfiguration.persistSecret(value, defaultsKey: defaultsKey)
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            showCursorOverlayIfAvailable()
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func setActivationShortcutEnabled(_ enabled: Bool) {
        isActivationShortcutEnabled = enabled
        globalPushToTalkShortcutMonitor.setActivationShortcutEnabled(enabled)
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }
}
