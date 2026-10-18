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
    func testVoiceResponseCaptionPlayback() {
        let line = "This is OpenClicky's caption playback test. The selected caption font should show beside the cursor."
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: line,
            contextTitle: "Caption playback test"
        )
        showShortSystemResponse(line)
        updateVoiceResponseCaption(line, force: true)
        let currentCaption = cursorOverlayState.externalPrimaryCaptionText
        externalProxyClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            await MainActor.run {
                guard let self, self.cursorOverlayState.externalPrimaryCaptionText == currentCaption else { return }
                self.clearVoiceResponseCaption()
            }
        }
    }

    func updateVoiceResponseCaption(_ text: String, force: Bool = false, updatesDock: Bool = true) {
        // Interactive bubble always tracks spoken replies so the provider
        // selector is reachable without opening Settings.
        let caption = Self.voiceResponseCaptionText(from: text)
        if !caption.isEmpty {
            showCursorOverlayIfAvailable()
            if updatesDock, let index = agentDockItems.firstIndex(where: { $0.id == tutorDockItemID }) {
                agentDockItems[index].caption = caption
                agentMenuBarStatusManager.scheduleSync(companionManager: self)
            }
            presentInteractiveResponseBubble(with: caption)
        }

        guard force || voiceResponseCaptionsEnabled else { return }
        guard !caption.isEmpty else { return }
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        showCursorOverlayIfAvailable()
        cursorOverlayState.externalPrimaryCaptionText = caption
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    /// Update the manually dismissed reply beside the AI pointer.
    func presentInteractiveResponseBubble(with caption: String) {
        responseOverlayManager.bind(companion: self)
        if !responseOverlayManager.isVisible {
            responseOverlayManager.showOverlayAndBeginStreaming(clearText: true)
        }
        responseOverlayManager.updateStreamingText(caption)
    }

    /// Clears the cursor-following caption only. Does NOT dismiss the interactive
    /// provider-selector bubble — that has its own longer auto-hide hold so the
    /// user can still switch Apple/Codex/Claude after speech ends.
    func clearVoiceResponseCaption() {
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        cursorOverlayState.externalPrimaryCaptionText = nil
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    /// Hard dismiss for interrupt/cancel paths — drops cursor caption and bubble.
    func clearVoiceResponseCaptionAndInteractiveBubble() {
        clearVoiceResponseCaption()
        responseOverlayManager.hideOverlay()
    }

    func scheduleVoiceResponseCaptionClear(after delay: TimeInterval = 2.2) {
        let currentCaption = cursorOverlayState.externalPrimaryCaptionText
        guard currentCaption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        externalProxyClearTask?.cancel()
        externalProxyClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.1, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self, self.cursorOverlayState.externalPrimaryCaptionText == currentCaption else { return }
                // Cursor caption only — keep the interactive bubble alive for its own hold.
                self.clearVoiceResponseCaption()
            }
        }
    }

    static func voiceResponseCaptionText(from text: String) -> String {
        let parsed = parsePointingCoordinates(from: text).spokenText
        // Keep the complete Markdown and paragraph boundaries for the reply renderer.
        return parsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows a short system message (confirmation, prompt, or announcement) in the pointer bubble.
    func showShortSystemResponse(
        _ text: String,
        interruptExisting: Bool = true,
        route: String? = nil,
        timing: OpenClickyRequestTiming? = nil,
        executionStartedAt: Date? = nil,
        extra: [String: Any] = [:]
    ) {
        if interruptExisting { interruptCurrentVoiceResponse() }
        beginCursorReplyPresentation()
        updateVoiceResponseCaption("<cursor_reply>" + text + "</cursor_reply>", force: true, updatesDock: false)
        guard let route else { return }
        var fields = extra
        fields["responseTextLength"] = text.count
        markRequestCompleted(route: route, executionStartedAt: executionStartedAt, timing: timing, extra: fields)
    }
}
