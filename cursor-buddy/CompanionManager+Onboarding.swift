//
//  CompanionManager+Onboarding.swift
//  cursor-buddy
//

@preconcurrency import AVFoundation
import AppKit
import ScreenCaptureKit
import Combine
import CoreAudio
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers
import OCCore
import OCUI
import OCMarkdown
import OCMemory

extension CompanionManager {
    // MARK: - Onboarding Video

    /// Onboarding video playback is disabled.
    func setupOnboardingVideo() {
        tearDownOnboardingVideo()
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        showOnboardingPrompt = false
        onboardingPromptText = ""
        onboardingPromptOpacity = 0.0
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()

                guard !screenCaptures.isEmpty else {
                    print("Onboarding demo skipped because no screenshot is available.")
                    return
                }

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let fullResponseText = try await analyzeComputerUsePointingResponse(
                    image: labeledImages[0],
                    capture: cursorScreenCapture,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }

    /// Opens the current Agent screen.  The public entry point retains its
    /// historic name so menu-bar actions, deep links, and SDK callers all land
    /// on the new ChatWorkspace surface rather than a debug-only legacy HUD.
    func showCodexHUD(developerRequested _: Bool = false) {
        guard isAdvancedModeEnabled else { return }
        codexHUDWindowManager.show(
            companionManager: self,
            openMemory: { [weak self] in
                self?.showMemoryWindow()
            },
            prepareVoiceFollowUp: { [weak self] in
                guard let self else { return }
                self.armVoiceFollowUpTarget(self.activeCodexAgentSessionID, source: "agent_hud_voice_button")
                self.prepareForVoiceFollowUp()
            }
        )
    }

    #if DEBUG
    func showDeveloperCodexHUD() {
        showCodexHUD()
    }
    #endif

    func showMemoryWindow() {
        wikiViewerPanelManager.show(
            index: bundledKnowledgeIndex,
            sourceRootURL: codexHomeManager.memoriesDirectory,
            onCreateMemory: { [weak self] title, body in
                guard let self else {
                    throw NSError(domain: "OpenClicky.Memory", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "OpenClicky couldn't reach the memory manager."
                    ])
                }
                return try self.createMemory(title: title, body: body)
            }
        )
    }

    func createMemory(title: String, body: String) throws -> OCCore.WikiManager.Article {
        let article = try codexHomeManager.saveMemory(title: title, body: body)
        loadBundledKnowledgeIndex()
        return article
    }

    func dismissLatestResponseCard() {
        if codexAgentSession.latestResponseCard != nil {
            let sessionID = codexAgentSession.id
            codexAgentSession.dismissLatestResponseCard()
            cancelAgentTask(sessionID: sessionID, removeDockItems: true, reason: "response_card_dismissed")
        } else {
            latestVoiceResponseCard = nil
        }
    }

    func runSuggestedNextAction(_ actionTitle: String) {
        runSuggestedNextAction(actionTitle, toAgentSession: codexAgentSession)
    }

    func runSuggestedNextAction(_ actionTitle: String, forAgentDockItem itemID: UUID) {
        guard let item = agentDockItems.first(where: { $0.id == itemID }),
              let sessionID = item.sessionID,
              let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_suggested_action.missing_session",
                fields: [
                    "itemID": itemID.uuidString,
                    "instructionLength": actionTitle.count
                ]
            )
            return
        }

        runSuggestedNextAction(actionTitle, toAgentSession: session)
    }

    private func runSuggestedNextAction(_ actionTitle: String, toAgentSession session: CodexAgentSession) {
        let trimmedActionTitle = actionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedActionTitle.isEmpty else { return }
        let timing = beginRequestTiming(source: "agent_suggested_action", text: trimmedActionTitle)
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_suggested_action",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedActionTitle.count
            ]
        )
        submitAgentPrompt(trimmedActionTitle, to: session)
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_suggested_action",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        if isAdvancedModeEnabled {
            showCodexHUD()
        }
    }

    func prepareForVoiceFollowUp() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        beginVoiceFollowUpCapture()
    }

    func startSDKVoiceCapture() {
        beginVoiceFollowUpCapture()
    }

    func stopSDKVoiceCapture() {
        voiceFollowUpStopTask?.cancel()
        voiceFollowUpStopTask = nil
        ClickyAnalytics.trackPushToTalkReleased()
        buddyDictationManager.stopPersistentDictationFromMicrophoneButton()
    }

    private func beginVoiceFollowUpCapture() {
        guard !buddyDictationManager.isDictationInProgress else { return }

        showCursorOverlayIfAvailable()
        transientHideTask?.cancel()
        transientHideTask = nil
        voiceFollowUpStopTask?.cancel()
        ClickyAnalytics.trackPushToTalkStarted()

        clearDetectedElementLocation()

        Task {
            await buddyDictationManager.startAutoSubmittingDictationFromMicrophoneButton(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts stay hidden; the cursor waveform is the active state.
                },
                submitDraftText: { [weak self = self] finalTranscript in
                    self?.handleFinalVoiceTranscript(finalTranscript)
                },
                onWillStartRecording: { [weak self = self] in
                    // Avoid chopping the previous reply if the user taps the
                    // mic button and releases before dictation really starts.
                    self?.interruptCurrentVoiceResponse()
                }
            )
        }

        voiceFollowUpStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard let self else { return }
                self.voiceFollowUpStopTask = nil
                self.stopSDKVoiceCapture()
            }
        }
    }

    func queueHandoffRegion(selection: HandoffRegionSelection, imageData: Data) {
        let queued = HandoffQueuedRegionScreenshot(selection: selection, imageData: imageData)
        handoffQueue.append(queued)
        latestVoiceResponseCard = ClickyResponseCard(
            source: .handoff,
            rawText: selection.comment.isEmpty ? "Screen region queued for Agent Mode." : selection.comment,
            contextTitle: "Screen region"
        )
    }

    func clearHandoffQueue() {
        handoffQueue.removeAll()
    }

    func warmUpCodexAgentMode() {
        guard isAdvancedModeEnabled else { return }
        codexAgentSession.warmUp()
    }

    #if DEBUG
    func debugCaptureTutorReview() {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let screen = NSScreen.main,
                      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == displayID.uint32Value }) else { return }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let windows = content.windows.filter {
                    $0.owningApplication?.processID == ownPID ||
                    ($0.owningApplication?.bundleIdentifier == "com.google.Chrome" && ($0.title?.hasPrefix("Example Domains") == true))
                }
                let config = SCStreamConfiguration()
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor)
                config.showsCursor = true
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, including: windows), configuration: config)
                if let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                    try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("OpenClicky-tutor-review.png"), options: .atomic)
                }
                OpenClickyMessageLogStore.shared.append(lane: "voice", direction: "internal", event: "tutor.presentation.review", fields: [
                    "publicBackdropIncluded": windows.contains { $0.owningApplication?.bundleIdentifier == "com.google.Chrome" },
                    "coachCursorCount": self.agentDockItems.filter { $0.title == "Workflow Coach" }.count,
                    "historyEntries": self.homeChatEntries.count,
                    "windows": NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? $0.title):\(NSStringFromRect($0.frame))" }.joined(separator: ";")
                ])
            } catch { print("Tutor presentation review failed: \(error.localizedDescription)") }
        }
    }

    func debugPreviewSecondaryPointer() {
        guard let screen = NSScreen.screen(containingOrNearestTo: NSEvent.mouseLocation) else { return }
        let id = UUID()
        cursorOverlayState.externalSecondaryCursors.append(OpenClickyExternalProxyCursor(
            id: id,
            screenLocation: CGPoint(x: screen.frame.midX, y: screen.frame.midY),
            caption: "Clipped label regression preview",
            accentHex: "#34D399"
        ))
        showCursorOverlayIfAvailable()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                for nativeWindow in NSApp.windows where nativeWindow is OverlayWindow {
                    guard let window = content.windows.first(where: { $0.windowID == CGWindowID(nativeWindow.windowNumber) }) else { continue }
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(nativeWindow.frame.width * nativeWindow.backingScaleFactor)
                    configuration.height = Int(nativeWindow.frame.height * nativeWindow.backingScaleFactor)
                    configuration.showsCursor = false
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration),
                       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenClicky-pointer-preview.png")
                        try? png.write(to: url)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(5))
            self?.cursorOverlayState.externalSecondaryCursors.removeAll { $0.id == id }
        }
    }

    func debugTestCursorFlight() {
        ensureCursorOverlayVisibleForAgentTask()
        let screen = NSScreen.screen(containingOrNearestTo: NSEvent.mouseLocation)
        guard let screen else { return }

        detectedElementScreenLocation = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        detectedElementDisplayFrame = screen.frame
        detectedElementBubbleText = "Developer test"
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "Developer cursor flight test armed at the center of the cursor screen.",
            contextTitle: "Developer"
        )
    }

    func debugShowResponseCard() {
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "This is a developer smoke test for OpenClicky's compact response card. Suggested actions and dismiss behavior should remain usable from the panel and chat.",
            contextTitle: "Developer"
        )
    }

    func debugCaptureAgentScreenContext() {
        Task {
            do {
                let captures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                let context = try writeCapturedScreenContext(captures, minimumPasteboardChangeCount: NSPasteboard.general.changeCount)
                let fileSummary = context.attachments
                    .map { $0.fileURL.lastPathComponent }
                    .joined(separator: ", ")

                latestVoiceResponseCard = ClickyResponseCard(
                    source: .handoff,
                    rawText: "Captured \(context.attachments.count) screen context file(s): \(fileSummary)",
                    contextTitle: "Developer"
                )
            } catch {
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .handoff,
                    rawText: "Screen context capture failed: \(error.localizedDescription)",
                    contextTitle: "Developer"
                )
            }
        }
    }

    func debugResetTransientUI() {
        interruptCurrentVoiceResponse()
        clearDetectedElementLocation()
        dismissLatestResponseCard()
        clearHandoffQueue()
        voiceState = .idle

        if !isClickyCursorEnabled {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }
    #endif
}

@MainActor
final class UserActivityIdleDetector: ObservableObject {
    static let idleThresholdSeconds: TimeInterval = 3.0

    @Published private(set) var isUserIdle = false

    private var lastUserInputTimestamp = Date()
    private var hasUserActedSinceLastObservation = true
    private var globalEventMonitor: Any?
    private var idleCheckTimer: Timer?

    func start() {
        stop()
        lastUserInputTimestamp = Date()
        hasUserActedSinceLastObservation = true

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordUserActivity()
            }
        }

        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateIdleState()
            }
        }
    }

    func stop() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        isUserIdle = false
    }

    func observationDidComplete() {
        hasUserActedSinceLastObservation = false
        isUserIdle = false
    }

    func recordTutorStepCompleted() {
        hasUserActedSinceLastObservation = true
        lastUserInputTimestamp = Date()
        isUserIdle = false
    }

    private func recordUserActivity() {
        lastUserInputTimestamp = Date()
        hasUserActedSinceLastObservation = true
        isUserIdle = false
    }

    private func evaluateIdleState() {
        let secondsSinceLastInput = Date().timeIntervalSince(lastUserInputTimestamp)
        let isNowIdle = secondsSinceLastInput >= Self.idleThresholdSeconds && hasUserActedSinceLastObservation
        if isNowIdle != isUserIdle {
            isUserIdle = isNowIdle
        }
    }
}

@MainActor
final class TutorTargetClickTracker {
    nonisolated private static let pointOnlyHitToleranceInScreenPoints: CGFloat = 44
    nonisolated private static let rectInflationInScreenPoints: CGFloat = 8

    private var targetPoint: CGPoint?
    private var targetRect: CGRect?
    private var globalEventMonitor: Any?
    private var onTargetClicked: ((CGPoint) -> Void)?

    func arm(targetPoint: CGPoint, targetRect: CGRect?, onTargetClicked: @escaping (CGPoint) -> Void) {
        self.targetPoint = targetPoint
        self.targetRect = targetRect
        self.onTargetClicked = onTargetClicked
        startEventMonitorIfNeeded()
    }

    func disarm() {
        targetPoint = nil
        targetRect = nil
        onTargetClicked = nil
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func startEventMonitorIfNeeded() {
        guard globalEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleClick(at: NSEvent.mouseLocation)
            }
        }
    }

    private func handleClick(at clickPoint: CGPoint) {
        guard Self.isHit(
            clickPoint: clickPoint,
            targetPoint: targetPoint,
            targetRect: targetRect
        ) else { return }

        let callback = onTargetClicked
        disarm()
        callback?(clickPoint)
    }

    static func isHit(
        clickPoint: CGPoint,
        targetPoint: CGPoint?,
        targetRect: CGRect?,
        pointTolerance: CGFloat = pointOnlyHitToleranceInScreenPoints,
        rectInflation: CGFloat = rectInflationInScreenPoints
    ) -> Bool {
        if let targetRect {
            let inflatedRect = targetRect.insetBy(dx: -rectInflation, dy: -rectInflation)
            if inflatedRect.contains(clickPoint) {
                return true
            }
        }

        guard let targetPoint else { return false }
        let distance = hypot(clickPoint.x - targetPoint.x, clickPoint.y - targetPoint.y)
        return distance <= pointTolerance
    }
}

nonisolated private struct OpenClickyDirectActionStoredMemory: Codable, Sendable {
    var folderShortcuts: [OpenClickyDirectActionStoredFolderShortcut]
}

nonisolated private struct OpenClickyDirectActionStoredFolderShortcut: Codable, Sendable {
    var aliases: [String]
    var path: String
    var displayName: String
    var lastUsedAt: Date
}

final class OpenClickyDirectActionMemoryStore: @unchecked Sendable {
    static let shared = OpenClickyDirectActionMemoryStore()

    struct FolderShortcut {
        let url: URL
        let displayName: String
    }

    private let fileManager: FileManager
    private let memoryFile: URL
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "openclicky.direct-action-memory-writes", qos: .utility)
    private var cachedMemory: OpenClickyDirectActionStoredMemory?

    init(fileManager: FileManager = .default, memoryFile: URL? = nil) {
        self.fileManager = fileManager
        self.memoryFile = memoryFile ?? Self.defaultMemoryFile(fileManager: fileManager)
    }

    func folderShortcut(matching normalizedTranscript: String) -> FolderShortcut? {
        lock.lock()
        defer { lock.unlock() }

        let memory = loadMemoryLocked()
        for shortcut in memory.folderShortcuts {
            guard fileManager.fileExists(atPath: shortcut.path) else { continue }
            guard shortcut.aliases.contains(where: { alias in
                !alias.isEmpty && normalizedTranscript.contains(alias)
            }) else { continue }

            return FolderShortcut(
                url: URL(fileURLWithPath: shortcut.path, isDirectory: true),
                displayName: shortcut.displayName
            )
        }

        return nil
    }

    func recordFolderShortcut(instruction: String, url: URL, displayName: String) {
        lock.lock()
        defer { lock.unlock() }

        let path = url.standardizedFileURL.path
        var memory = loadMemoryLocked()
        let aliases = Self.aliases(forInstruction: instruction, displayName: displayName, path: path)
        guard !aliases.isEmpty else { return }

        if let index = memory.folderShortcuts.firstIndex(where: { $0.path == path }) {
            let mergedAliases = Array(Set(memory.folderShortcuts[index].aliases + aliases)).sorted()
            memory.folderShortcuts[index].aliases = mergedAliases
            memory.folderShortcuts[index].displayName = displayName
            memory.folderShortcuts[index].lastUsedAt = Date()
        } else {
            memory.folderShortcuts.append(
                OpenClickyDirectActionStoredFolderShortcut(
                    aliases: aliases,
                    path: path,
                    displayName: displayName,
                    lastUsedAt: Date()
                )
            )
        }

        cachedMemory = memory
        saveMemoryLocked(memory)
    }

    private func loadMemoryLocked() -> OpenClickyDirectActionStoredMemory {
        if let cachedMemory {
            return cachedMemory
        }

        var memory: OpenClickyDirectActionStoredMemory
        if let data = try? Data(contentsOf: memoryFile),
           let decoded = try? JSONDecoder().decode(OpenClickyDirectActionStoredMemory.self, from: data) {
            memory = decoded
        } else {
            memory = OpenClickyDirectActionStoredMemory(folderShortcuts: [])
        }

        if seedBuiltInShortcutsIfNeeded(&memory) {
            cachedMemory = memory
            saveMemoryLocked(memory)
            return memory
        }

        cachedMemory = memory
        return memory
    }

    private func saveMemoryLocked(_ memory: OpenClickyDirectActionStoredMemory) {
        cachedMemory = memory
        let fileManager = fileManager
        let memoryFile = memoryFile
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(memory)
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.direct_action_memory.write_failed",
                fields: [
                    "path": memoryFile.path,
                    "error": error.localizedDescription
                ]
            )
            return
        }

        writeQueue.async {
            do {
                try fileManager.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: memoryFile, options: [.atomic])
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.direct_action_memory.write_failed",
                    fields: [
                        "path": memoryFile.path,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    @discardableResult
    private func seedBuiltInShortcutsIfNeeded(_ memory: inout OpenClickyDirectActionStoredMemory) -> Bool {
        // Debug-only developer convenience: seed a shortcut to the local source
        // checkout. The hardcoded absolute path only resolves on the developer's
        // machine (guarded by fileExists), but gating behind DEBUG keeps it out
        // of release builds entirely so it can't collide with a user's own
        // "project folder" intent on a machine that happens to have that path.
        #if DEBUG
        let sourcePath = "/Users/jkneen/Documents/GitHub/openclicky"
        guard fileManager.fileExists(atPath: sourcePath) else { return false }
        guard !memory.folderShortcuts.contains(where: { $0.path == sourcePath }) else { return false }

        memory.folderShortcuts.append(
            OpenClickyDirectActionStoredFolderShortcut(
                aliases: [
                    "clicky folder",
                    "code folder",
                    "open clicky folder",
                    "open clicky source",
                    "openclicky folder",
                    "openclicky source",
                    "project folder",
                    "repo folder",
                    "repository folder",
                    "source code folder",
                    "source folder"
                ],
                path: sourcePath,
                displayName: "the source code folder",
                lastUsedAt: Date()
            )
        )
        return true
        #else
        return false
        #endif
    }

    private static func aliases(forInstruction instruction: String, displayName: String, path: String) -> [String] {
        var aliases = Set<String>()

        for candidate in [instruction, displayName] {
            let normalized = normalize(candidate)
            if normalized.count >= 4 {
                aliases.insert(normalized)
            }

            let withoutOpenVerbs = normalized
                .replacingOccurrences(of: "open ", with: "")
                .replacingOccurrences(of: "show ", with: "")
                .replacingOccurrences(of: "reveal ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutOpenVerbs.count >= 4 {
                aliases.insert(withoutOpenVerbs)
            }
        }

        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
        let normalizedName = normalize(lastPathComponent)
        if normalizedName.count >= 4 {
            aliases.insert(normalizedName)
            aliases.insert("\(normalizedName) folder")
            aliases.insert("\(normalizedName) source")
        }

        return Array(aliases).sorted()
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func defaultMemoryFile(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("direct-computer-use-shortcuts.json", isDirectory: false)
    }
}
