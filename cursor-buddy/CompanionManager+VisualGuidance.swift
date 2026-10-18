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
    func showVisualGuidanceOverlay(
        _ overlay: OpenClickyVisualGuidanceOverlay,
        sourceCapture: CompanionScreenCapture? = nil
    ) {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        var clampedOverlay = overlay.clamped(to: desktopBounds)
        if clampedOverlay.kind == .rectangle {
            clampedOverlay.duration = max(clampedOverlay.duration, 30)
        } else {
            clampedOverlay.duration = max(clampedOverlay.duration, 20)
        }
        if let calibrationAnchor = Self.pendingCalibrationAnchor(from: clampedOverlay, sourceCapture: sourceCapture) {
            clampedOverlay.duration = max(clampedOverlay.duration, 120)
            clampedOverlay.style.accentHex = "#34D399"
            pendingVisualGuidanceCalibrationAnchor = calibrationAnchor
            sampleAutomaticVisualGuidanceCalibrationAnchor(calibrationAnchor)
        }
        guard clampedOverlay.isRenderable else { return }
        cursorOverlayState.visualGuidanceOverlays.removeAll { $0.id == clampedOverlay.id }
        cursorOverlayState.visualGuidanceOverlays.append(clampedOverlay)
        showCursorOverlayIfAvailable()

        visualGuidanceOverlayClearTasks[clampedOverlay.id]?.cancel()
        visualGuidanceOverlayClearTasks[clampedOverlay.id] = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, clampedOverlay.duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self?.removeVisualGuidanceOverlay(clampedOverlay.id)
            }
        }
    }

    func removeVisualGuidanceOverlay(_ id: UUID) {
        visualGuidanceOverlayClearTasks[id]?.cancel()
        visualGuidanceOverlayClearTasks[id] = nil
        cursorOverlayState.visualGuidanceOverlays.removeAll { $0.id == id }
    }

    static func pendingCalibrationAnchor(
        from overlay: OpenClickyVisualGuidanceOverlay,
        sourceCapture: CompanionScreenCapture? = nil
    ) -> OpenClickyPendingVisualGuidanceCalibrationAnchor? {
        guard overlay.kind == .rectangle,
              isVisualGuidanceCalibrationCaption(overlay.style.caption),
              let rect = overlay.rect?.normalized.cgRect,
              !rect.isNull,
              rect.width > 1,
              rect.height > 1 else {
            return nil
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screenFrame = NSScreen.screen(containingOrNearestTo: center)?.frame ?? rect
        return OpenClickyPendingVisualGuidanceCalibrationAnchor(
            overlayID: overlay.id,
            caption: overlay.style.caption ?? "calibration anchor",
            predictedRect: rect,
            screenFrame: screenFrame,
            screenshotWidthInPixels: sourceCapture?.screenshotWidthInPixels,
            screenshotHeightInPixels: sourceCapture?.screenshotHeightInPixels,
            displayNativeWidthInPixels: sourceCapture?.displayNativeWidthInPixels,
            displayNativeHeightInPixels: sourceCapture?.displayNativeHeightInPixels,
            createdAt: Date()
        )
    }

    func sampleAutomaticVisualGuidanceCalibrationAnchor(_ anchor: OpenClickyPendingVisualGuidanceCalibrationAnchor) {
        guard let expectedCenter = Self.expectedVisualGuidanceCalibrationCenter(
            for: anchor.caption,
            predictedRect: anchor.predictedRect,
            screenFrame: anchor.screenFrame,
            screenshotWidthInPixels: anchor.screenshotWidthInPixels,
            screenshotHeightInPixels: anchor.screenshotHeightInPixels
        ) else { return }

        let predictedCenter = CGPoint(
            x: anchor.predictedRect.midX,
            y: anchor.predictedRect.midY
        )
        let delta = CGSize(
            width: expectedCenter.x - predictedCenter.x,
            height: expectedCenter.y - predictedCenter.y
        )
        guard Self.isPlausibleVisualGuidanceCalibrationDelta(delta, for: anchor.screenFrame) else {
            let maxDelta = Self.maximumVisualGuidanceCalibrationDelta(for: anchor.screenFrame)
            OpenClickyMessageLogStore.shared.append(
                lane: "visual_guidance",
                direction: "incoming",
                event: "openclicky.visual_guidance.auto_calibration_rejected",
                fields: [
                    "overlayID": anchor.overlayID.uuidString,
                    "label": anchor.caption,
                    "reason": "implausible_delta",
                    "predictedX": Int(predictedCenter.x.rounded()),
                    "predictedY": Int(predictedCenter.y.rounded()),
                    "expectedX": Int(expectedCenter.x.rounded()),
                    "expectedY": Int(expectedCenter.y.rounded()),
                    "sampleDeltaX": Int(delta.width.rounded()),
                    "sampleDeltaY": Int(delta.height.rounded()),
                    "maxDeltaX": Int(maxDelta.width.rounded()),
                    "maxDeltaY": Int(maxDelta.height.rounded()),
                    "mapKind": "screenshot_to_display_warp_map"
                ]
            )
            return
        }
        let calibration = Self.updatedVisualGuidanceCalibrationOffset(
            delta: delta,
            for: anchor.screenFrame
        )

        OpenClickyMessageLogStore.shared.append(
            lane: "visual_guidance",
            direction: "incoming",
            event: "openclicky.visual_guidance.auto_calibration_sampled",
            fields: [
                "overlayID": anchor.overlayID.uuidString,
                "label": anchor.caption,
                "screenKey": calibration.screenKey,
                "predictedX": Int(predictedCenter.x.rounded()),
                "predictedY": Int(predictedCenter.y.rounded()),
                "expectedX": Int(expectedCenter.x.rounded()),
                "expectedY": Int(expectedCenter.y.rounded()),
                "sampleDeltaX": Int(delta.width.rounded()),
                "sampleDeltaY": Int(delta.height.rounded()),
                "offsetX": Int(calibration.offset.width.rounded()),
                "offsetY": Int(calibration.offset.height.rounded()),
                "sampleCount": calibration.count,
                "mapKind": "screenshot_to_display_warp_map",
                "screenshotWidthInPixels": anchor.screenshotWidthInPixels ?? 0,
                "screenshotHeightInPixels": anchor.screenshotHeightInPixels ?? 0,
                "displayWidthInPoints": Int(anchor.screenFrame.width.rounded()),
                "displayHeightInPoints": Int(anchor.screenFrame.height.rounded()),
                "displayNativeWidthInPixels": anchor.displayNativeWidthInPixels ?? 0,
                "displayNativeHeightInPixels": anchor.displayNativeHeightInPixels ?? 0
            ]
        )
    }

    static func expectedVisualGuidanceCalibrationCenter(
        for caption: String,
        predictedRect: CGRect,
        screenFrame: CGRect,
        screenshotWidthInPixels: Int? = nil,
        screenshotHeightInPixels: Int? = nil
    ) -> CGPoint? {
        let normalized = caption
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        // Calibration compares the model's detected anchor in the actual
        // screenshot it saw (for example 1280x540 after downsampling a
        // 3840x1620 display) to the expected screen-corner anchor, then
        // converts that expected pixel back into AppKit display points.
        let screenshotSize = CGSize(
            width: CGFloat(screenshotWidthInPixels ?? Int(screenFrame.width.rounded())),
            height: CGFloat(screenshotHeightInPixels ?? Int(screenFrame.height.rounded()))
        )
        let scaleX = screenFrame.width / max(1, screenshotSize.width)
        let scaleY = screenFrame.height / max(1, screenshotSize.height)
        let insetPixelX = max(18, min(64, screenshotSize.width * 0.035))
        let insetPixelY = max(12, min(42, screenshotSize.height * 0.032))
        let predictedCenter = CGPoint(x: predictedRect.midX, y: predictedRect.midY)
        let predictedPixelCenter = CGPoint(
            x: (predictedCenter.x - screenFrame.minX) / max(0.0001, scaleX),
            y: (screenFrame.maxY - predictedCenter.y) / max(0.0001, scaleY)
        )
        let predictedIsTopHalf = predictedPixelCenter.y <= screenshotSize.height / 2

        func displayPoint(fromScreenshotPixel pixel: CGPoint) -> CGPoint {
            CGPoint(
                x: screenFrame.minX + (pixel.x * scaleX),
                y: screenFrame.maxY - (pixel.y * scaleY)
            )
        }

        if normalized.contains("time") || normalized.contains("clock") {
            return displayPoint(fromScreenshotPixel: CGPoint(x: screenshotSize.width - max(52, insetPixelX), y: insetPixelY))
        }
        if normalized.contains("trash") || normalized.contains("dustbin") || normalized.contains("bin") {
            return displayPoint(fromScreenshotPixel: CGPoint(x: screenshotSize.width - insetPixelX, y: screenshotSize.height - insetPixelY))
        }
        if normalized.contains("apple") {
            return displayPoint(fromScreenshotPixel: CGPoint(x: insetPixelX, y: insetPixelY))
        }
        if normalized.contains("finder") {
            if normalized.contains("label") || normalized.contains("menu") || predictedIsTopHalf {
                return displayPoint(fromScreenshotPixel: CGPoint(x: max(52, insetPixelX), y: insetPixelY))
            }
            return displayPoint(fromScreenshotPixel: CGPoint(x: insetPixelX, y: screenshotSize.height - insetPixelY))
        }
        return nil
    }

    func handleVisualGuidanceCalibrationCursorSampleIfNeeded(from transcript: String) -> Bool {
        guard let pendingVisualGuidanceCalibrationAnchor else { return false }
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let confirmsSample = [
            "mark it", "mark this", "highlight it", "highlight this",
            "lined up", "line up", "anchor it", "save anchor",
            "got it", "done", "that's it", "thats it",
            "i'm pointing", "im pointing", "pointing at it", "pointing at this",
            "i am going to point", "can you do the same", "do the same",
            "this one", "right here", "it's here", "its here", "here"
        ].contains { normalized.contains($0) }
        guard confirmsSample else { return false }

        let cursorPoint = NSEvent.mouseLocation
        guard pendingVisualGuidanceCalibrationAnchor.screenFrame.contains(cursorPoint) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "visual_guidance",
                direction: "incoming",
                event: "openclicky.visual_guidance.cursor_calibration_rejected",
                fields: [
                    "overlayID": pendingVisualGuidanceCalibrationAnchor.overlayID.uuidString,
                    "label": pendingVisualGuidanceCalibrationAnchor.caption,
                    "reason": "cursor_on_different_screen",
                    "cursorX": Int(cursorPoint.x.rounded()),
                    "cursorY": Int(cursorPoint.y.rounded()),
                    "screenKey": Self.visualGuidanceCalibrationScreenKey(for: pendingVisualGuidanceCalibrationAnchor.screenFrame)
                ]
            )
            self.pendingVisualGuidanceCalibrationAnchor = nil
            return true
        }
        let predictedCenter = CGPoint(
            x: pendingVisualGuidanceCalibrationAnchor.predictedRect.midX,
            y: pendingVisualGuidanceCalibrationAnchor.predictedRect.midY
        )
        let delta = CGSize(
            width: cursorPoint.x - predictedCenter.x,
            height: cursorPoint.y - predictedCenter.y
        )
        guard Self.isPlausibleVisualGuidanceCalibrationDelta(delta, for: pendingVisualGuidanceCalibrationAnchor.screenFrame) else {
            let maxDelta = Self.maximumVisualGuidanceCalibrationDelta(for: pendingVisualGuidanceCalibrationAnchor.screenFrame)
            OpenClickyMessageLogStore.shared.append(
                lane: "visual_guidance",
                direction: "incoming",
                event: "openclicky.visual_guidance.cursor_calibration_rejected",
                fields: [
                    "overlayID": pendingVisualGuidanceCalibrationAnchor.overlayID.uuidString,
                    "label": pendingVisualGuidanceCalibrationAnchor.caption,
                    "reason": "implausible_delta",
                    "predictedX": Int(predictedCenter.x.rounded()),
                    "predictedY": Int(predictedCenter.y.rounded()),
                    "cursorX": Int(cursorPoint.x.rounded()),
                    "cursorY": Int(cursorPoint.y.rounded()),
                    "sampleDeltaX": Int(delta.width.rounded()),
                    "sampleDeltaY": Int(delta.height.rounded()),
                    "maxDeltaX": Int(maxDelta.width.rounded()),
                    "maxDeltaY": Int(maxDelta.height.rounded()),
                    "screenKey": Self.visualGuidanceCalibrationScreenKey(for: pendingVisualGuidanceCalibrationAnchor.screenFrame)
                ]
            )
            self.pendingVisualGuidanceCalibrationAnchor = nil
            return true
        }
        let calibration = Self.updatedVisualGuidanceCalibrationOffset(
            delta: delta,
            for: pendingVisualGuidanceCalibrationAnchor.screenFrame
        )
        let caption = pendingVisualGuidanceCalibrationAnchor.caption
        self.pendingVisualGuidanceCalibrationAnchor = nil

        OpenClickyMessageLogStore.shared.append(
            lane: "visual_guidance",
            direction: "incoming",
            event: "openclicky.visual_guidance.cursor_calibration_sampled",
            fields: [
                "overlayID": pendingVisualGuidanceCalibrationAnchor.overlayID.uuidString,
                "label": caption,
                "screenKey": calibration.screenKey,
                "predictedX": Int(predictedCenter.x.rounded()),
                "predictedY": Int(predictedCenter.y.rounded()),
                "cursorX": Int(cursorPoint.x.rounded()),
                "cursorY": Int(cursorPoint.y.rounded()),
                "sampleDeltaX": Int(delta.width.rounded()),
                "sampleDeltaY": Int(delta.height.rounded()),
                "offsetX": Int(calibration.offset.width.rounded()),
                "offsetY": Int(calibration.offset.height.rounded()),
                "sampleCount": calibration.count
            ]
        )

        showShortSystemResponse(Self.visualGuidanceCalibrationSampleAcknowledgement(for: caption))
        return true
    }

    func showActiveControlGlow(
        around rect: CGRect?,
        label: String? = nil,
        duration: TimeInterval = 2.4
    ) {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let fallbackRect = NSScreen.screen(containingOrNearestTo: NSEvent.mouseLocation)?.frame
            ?? NSScreen.main?.frame
        let candidateRect = (rect?.isNull == false ? rect : fallbackRect) ?? .null
        let clampedRect = candidateRect.intersection(desktopBounds)
        guard !clampedRect.isNull,
              clampedRect.width > 8,
              clampedRect.height > 8 else {
            return
        }

        cursorOverlayState.activeControlGlowRect = clampedRect
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cursorOverlayState.activeControlGlowLabel = trimmedLabel.isEmpty ? nil : trimmedLabel
        showCursorOverlayIfAvailable()

        activeControlGlowClearTask?.cancel()
        activeControlGlowClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.4, min(duration, 12)) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.clearActiveControlGlow()
            }
        }
    }

    func showActiveControlGlowForFocusedWindowOrScreen(
        label: String? = nil,
        duration: TimeInterval = 2.4
    ) {
        let focusedWindow = OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow()
        showActiveControlGlow(
            around: focusedWindow.flatMap { Self.appKitScreenRect(fromComputerUseWindowBounds: $0.bounds) },
            label: label ?? focusedWindow?.displayTitle,
            duration: duration
        )
    }

    func clearActiveControlGlow() {
        activeControlGlowClearTask?.cancel()
        activeControlGlowClearTask = nil
        cursorOverlayState.activeControlGlowRect = nil
        cursorOverlayState.activeControlGlowLabel = nil
    }

    static func appKitScreenRect(fromComputerUseWindowBounds bounds: OpenClickyComputerUseWindowBounds) -> CGRect? {
        let quartzRect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        guard !quartzRect.isNull,
              quartzRect.width > 1,
              quartzRect.height > 1 else {
            return nil
        }

        let matchedScreen = NSScreen.screens.first { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayBounds(displayID).intersects(quartzRect)
        } ?? NSScreen.screens.first { screen in
            screen.frame.intersects(quartzRect)
        }

        guard let screen = matchedScreen else {
            return quartzRect
        }

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return quartzRect
        }

        let quartzFrame = CGDisplayBounds(displayID)
        let localX = quartzRect.minX - quartzFrame.minX
        let localYFromTop = quartzRect.minY - quartzFrame.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localYFromTop - quartzRect.height,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    static func controlTargetGlowRect(centeredOn point: CGPoint, within displayFrame: CGRect?) -> CGRect {
        let sidePaddingRect = CGRect(
            x: point.x - 70,
            y: point.y - 45,
            width: 140,
            height: 90
        )
        guard let displayFrame,
              !displayFrame.isNull else {
            return sidePaddingRect
        }

        return sidePaddingRect.intersection(displayFrame)
    }

    func visualGuidanceCorrectionLearningPrompt() -> String {
        let calibrationSummary = Self.visualGuidanceCalibrationPromptSummary()
        guard !calibrationSummary.isEmpty else { return "" }
        return """

        visual guidance calibration memory:
        calibration is automatic: when a calibration rectangle is emitted for a known screen anchor, OpenClicky compares that detected anchor with the expected corner position and records a screenshot-to-display warp-map sample. Do not ask the user to move OpenClicky's square, move the calibration anchor, put their pointer anywhere, or say "mark it". After anchors are sampled, continue with voice validation by selecting visible UI targets and asking concrete "THIS" confirmation questions, for example "is THIS the Xcode icon?" or "is THIS the close button?". The user's cursor/buddy location is the ground-truth pointer when they point at the correct item and say "this one" or "I'm pointing at it", adding another warp-map correction sample. Paired-pointing checks like "I am going to point to the Finder button, can you do the same" mean OpenClicky should point to its predicted target too, then compare both points. The warp-map validation should include opposite-side/corner targets plus interior anchors, not just one corner; sample horizontally and vertically in OpenClicky's captured screenshot coordinate space at its current resolution, then map back to display points so OpenClicky can correct scale, skew, and local drift; once calibrated, future pointing should use that transform regardless of the current app/content. Existing learned coordinate calibration may still be applied. \(calibrationSummary)
        """
    }

    static let visualGuidanceCalibrationDefaultsPrefix = "openclicky.visualGuidance.coordinateCalibration"

    static func isVisualGuidanceCalibrationCaption(_ caption: String?) -> Bool {
        guard let caption else { return false }
        let normalized = caption
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return normalized.contains("calibration")
            || normalized.contains("calibrate")
            || normalized.contains("anchor")
    }

    static func visualGuidanceCalibrationScreenKey(for displayFrame: CGRect) -> String {
        [
            Int(displayFrame.minX.rounded()),
            Int(displayFrame.minY.rounded()),
            Int(displayFrame.width.rounded()),
            Int(displayFrame.height.rounded())
        ]
        .map(String.init)
        .joined(separator: "_")
    }

    static func visualGuidanceCalibrationDefaultsKey(for displayFrame: CGRect, suffix: String) -> String {
        "\(visualGuidanceCalibrationDefaultsPrefix).\(visualGuidanceCalibrationScreenKey(for: displayFrame)).\(suffix)"
    }

    static func visualGuidanceCalibrationOffset(for displayFrame: CGRect) -> CGSize {
        let defaults = UserDefaults.standard
        let countKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "count")
        guard defaults.integer(forKey: countKey) > 0 else { return .zero }
        let offset = CGSize(
            width: defaults.double(forKey: visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetX")),
            height: defaults.double(forKey: visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetY"))
        )
        guard isPlausibleVisualGuidanceCalibrationDelta(offset, for: displayFrame) else {
            return .zero
        }
        return offset
    }

    static func maximumVisualGuidanceCalibrationDelta(for displayFrame: CGRect) -> CGSize {
        CGSize(
            width: max(48, min(160, displayFrame.width * 0.08)),
            height: max(48, min(160, displayFrame.height * 0.08))
        )
    }

    static func isPlausibleVisualGuidanceCalibrationDelta(_ delta: CGSize, for displayFrame: CGRect) -> Bool {
        let maximum = maximumVisualGuidanceCalibrationDelta(for: displayFrame)
        return abs(delta.width) <= maximum.width
            && abs(delta.height) <= maximum.height
    }

    @discardableResult
    static func updatedVisualGuidanceCalibrationOffset(
        delta: CGSize,
        for displayFrame: CGRect
    ) -> (screenKey: String, offset: CGSize, count: Int) {
        let defaults = UserDefaults.standard
        let countKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "count")
        let offsetXKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetX")
        let offsetYKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetY")
        let storedCount = defaults.integer(forKey: countKey)
        let storedOffset = CGSize(
            width: defaults.double(forKey: offsetXKey),
            height: defaults.double(forKey: offsetYKey)
        )
        let oldCount = isPlausibleVisualGuidanceCalibrationDelta(storedOffset, for: displayFrame)
            ? storedCount
            : 0
        let oldOffset = oldCount > 0 ? storedOffset : .zero
        let newCount = oldCount + 1
        let newOffset = CGSize(
            width: ((oldOffset.width * Double(oldCount)) + delta.width) / Double(newCount),
            height: ((oldOffset.height * Double(oldCount)) + delta.height) / Double(newCount)
        )
        defaults.set(newCount, forKey: countKey)
        defaults.set(newOffset.width, forKey: offsetXKey)
        defaults.set(newOffset.height, forKey: offsetYKey)
        return (visualGuidanceCalibrationScreenKey(for: displayFrame), newOffset, newCount)
    }

    static func visualGuidanceCalibrationPromptSummary() -> String {
        let defaults = UserDefaults.standard
        let summaries = NSScreen.screens.compactMap { screen -> String? in
            let count = defaults.integer(forKey: visualGuidanceCalibrationDefaultsKey(for: screen.frame, suffix: "count"))
            guard count > 0 else { return nil }
            let offset = visualGuidanceCalibrationOffset(for: screen.frame)
            return " screen \(visualGuidanceCalibrationScreenKey(for: screen.frame)) has \(count) calibration sample\(count == 1 ? "" : "s") and applies an offset of x \(Int(offset.width.rounded())), y \(Int(offset.height.rounded())) points."
        }
        guard !summaries.isEmpty else { return "" }
        return " coordinate calibration is active:\(summaries.joined())"
    }

    static func visualGuidanceCalibrationSampleAcknowledgement(for caption: String) -> String {
        let normalized = caption
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        if normalized.contains("finder") {
            return "got the Finder anchor. next, ask OpenClicky to calibrate the Trash or Dustbin anchor."
        }
        if normalized.contains("trash") || normalized.contains("dustbin") || normalized.contains("bin") {
            return "got the Trash anchor. next, ask OpenClicky to calibrate the Apple menu anchor."
        }
        if normalized.contains("apple") {
            return "got the Apple menu anchor. next, ask OpenClicky to calibrate the time or clock anchor."
        }
        if normalized.contains("time") || normalized.contains("clock") {
            return "got the time anchor. that gives OpenClicky the four screen anchors."
        }
        return "got that calibration anchor. repeat with the next screen anchor when you're ready."
    }
}
