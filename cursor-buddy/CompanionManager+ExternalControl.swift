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
    func startExternalControlBridgeIfNeeded() {
        guard externalControlBridgeServer == nil else { return }
        let server = OpenClickyExternalControlBridgeServer { [weak self] command in
            guard let self else {
                return .error(503, "OpenClicky is not ready")
            }
            return await self.handleExternalControlCommand(command)
        }
        externalControlBridgeServer = server
        server.start()
    }

    func handleExternalControlCommand(_ command: OpenClickyExternalControlCommand) async -> OpenClickyExternalControlResponse {
        switch command {
        case .showCursor(let point, let caption, let duration, let accentHex, let mode, let travelDuration):
            switch mode {
            case .primary:
                showExternalPrimaryCursor(at: point, caption: caption, duration: duration, accentHex: accentHex, travelDuration: travelDuration)
                return .ok(["displayed": "primary_cursor", "durationMs": Int(duration * 1000), "travelMs": Int(travelDuration * 1000)])
            case .secondary:
                showExternalSecondaryCursor(at: point, caption: caption, duration: duration, accentHex: accentHex)
                return .ok(["displayed": "secondary_cursor", "durationMs": Int(duration * 1000)])
            }
        case .showCursors(let specs):
            for spec in specs {
                showExternalSecondaryCursor(at: spec.point, caption: spec.caption, duration: spec.duration, accentHex: spec.accentHex)
            }
            return .ok(["displayed": "secondary_cursors", "count": specs.count])
        case .showVisualGuidanceOverlay(let overlay):
            showVisualGuidanceOverlay(overlay)
            return .ok(["displayed": overlay.kind.rawValue, "id": overlay.id.uuidString, "durationMs": Int(overlay.duration * 1000)])
        case .showCaption(let text, let point, let duration, let accentHex):
            let resolvedPoint = point ?? NSEvent.mouseLocation
            showExternalPrimaryCursor(at: resolvedPoint, caption: text, duration: duration, accentHex: accentHex, travelDuration: 0.35)
            return .ok(["displayed": "primary_caption", "durationMs": Int(duration * 1000)])
        case .captureScreenshot(let focused):
            return await captureExternalControlScreenshots(focused: focused)
        case .click(let point, let caption):
            return clickExternalControlPoint(point, caption: caption)
        case .clear:
            clearExternalProxyOverlay()
            return .ok(["cleared": true])
        case .speak(let text, let interrupt):
            return speakExternalProxyText(text, interrupt: interrupt)
        case .notify(let title, let body, let threadID, let sound):
            let identifier = OpenClickyDesktopNotificationCenter.shared.post(
                title: title,
                body: body,
                threadID: threadID ?? "openclicky.external",
                playSound: sound,
                userInfo: ["source": "external_control_bridge"]
            )
            return .accepted(["notified": true, "identifier": identifier])
        case .unavailable(let statusCode, let body):
            return OpenClickyExternalControlResponse(statusCode: statusCode, body: body)
        }
    }

    func showExternalPrimaryCursor(at point: CGPoint, caption: String?, duration: TimeInterval, accentHex: String?, travelDuration: TimeInterval) {
        let targetPoint = Self.clampedExternalCursorPoint(point)
        // Use OpenClicky's existing smooth pointing choreography — the same
        // path used when voice asks "show me the Apple menu". This makes the
        // little OpenClicky triangle detach, zip to the target, caption it, and
        // fly back to the user's real pointer. Do not warp the system pointer
        // here and do not draw a duplicate primary cursor icon.
        detectedElementScreenLocation = targetPoint
        detectedElementDisplayFrame = NSScreen.screen(containingOrNearestTo: targetPoint)?.frame
            ?? CGRect(origin: targetPoint, size: .zero)
        detectedElementBubbleText = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedElementReturnsImmediately = false
        cursorOverlayState.externalPrimaryCaptionText = nil
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
        showCursorOverlayIfAvailable()
    }

    func showExternalSecondaryCursor(at point: CGPoint, caption: String?, duration: TimeInterval, accentHex: String?) {
        let targetPoint = Self.clampedExternalCursorPoint(point)
        let id = UUID()
        let cursor = OpenClickyExternalProxyCursor(
            id: id,
            screenLocation: targetPoint,
            caption: caption?.trimmingCharacters(in: .whitespacesAndNewlines),
            accentHex: accentHex
        )
        cursorOverlayState.externalSecondaryCursors.append(cursor)
        showCursorOverlayIfAvailable()

        externalSecondaryCursorClearTasks[id]?.cancel()
        externalSecondaryCursorClearTasks[id] = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self?.removeExternalSecondaryCursor(id)
            }
        }
    }

    func animateAgentSpawnProxyFromCursorToDock(accentTheme: ClickyAccentTheme, caption: String? = nil, dockItemID: UUID? = nil) {
        guard !OpenClickyPresentationPolicy.menuBarOnly else { return }
        let startPoint = Self.clampedExternalCursorPoint(NSEvent.mouseLocation)
        let targetPoint = dockItemID
            .flatMap { agentDockWindowManager.dockIconCenter(for: $0, in: agentDockItems) }
            .map(Self.clampedExternalCursorPoint)
            ?? agentDockSpawnProxyTargetPoint(from: startPoint)

        // For agent starts, use the primary OpenClicky buddy itself rather
        // than a disposable proxy cursor: it should visibly fly to the agent
        // corner, tag the handoff, and immediately return to the user's real
        // pointer so the working cursor never feels abandoned.
        detectedElementDisplayFrame = NSScreen.screens.first { $0.frame.contains(targetPoint) }?.frame
            ?? NSScreen.screens.first { $0.frame.contains(startPoint) }?.frame
            ?? NSScreen.main?.frame
            ?? CGRect(origin: targetPoint, size: .zero)
        detectedElementBubbleText = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedElementReturnsImmediately = true
        detectedElementScreenLocation = targetPoint
        showCursorOverlayIfAvailable()
    }

    func agentDockSpawnProxyTargetPoint(from startPoint: CGPoint) -> CGPoint {
        let screen = agentDockTargetScreen()
            ?? NSScreen.screen(containingOrNearestTo: startPoint)

        guard let screen else { return startPoint }

        let dockSize = NSSize(width: 760, height: 500)
        let edgeInset: CGFloat
        switch agentParkingPosition {
        case .topLeft, .topCenter, .topRight:
            edgeInset = max(56, screen.frame.maxY - screen.visibleFrame.maxY + 56)
        default:
            edgeInset = 16
        }

        var origin = agentParkingPosition.originForWindow(size: dockSize, on: screen, edgeInset: edgeInset)
        if agentParkingPosition == .topRight {
            origin.x += 70
            origin.y += 70
        }

        let approximateDockIconCenter = CGPoint(
            x: origin.x + dockSize.width - 50,
            y: origin.y + dockSize.height - 50
        )
        return Self.clampedExternalCursorPoint(approximateDockIconCenter)
    }

    static func clampedExternalCursorPoint(_ point: CGPoint) -> CGPoint {
        NSScreen.pointClampedToDesktop(point)
    }

    func clearExternalPrimaryCaption() {
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        externalPrimaryCursorMoveTask?.cancel()
        externalPrimaryCursorMoveTask = nil
        cursorOverlayState.externalPrimaryCaptionText = nil
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    func removeExternalSecondaryCursor(_ id: UUID) {
        externalSecondaryCursorClearTasks[id]?.cancel()
        externalSecondaryCursorClearTasks[id] = nil
        cursorOverlayState.externalSecondaryCursors.removeAll { $0.id == id }
    }

    func clearExternalProxyOverlay() {
        clearExternalPrimaryCaption()
        externalSecondaryCursorClearTasks.values.forEach { $0.cancel() }
        externalSecondaryCursorClearTasks.removeAll()
        cursorOverlayState.externalSecondaryCursors.removeAll()
        visualGuidanceOverlayClearTasks.values.forEach { $0.cancel() }
        visualGuidanceOverlayClearTasks.removeAll()
        cursorOverlayState.visualGuidanceOverlays.removeAll()
        clearActiveControlGlow()
    }

    func captureExternalControlScreenshots(focused: Bool) async -> OpenClickyExternalControlResponse {
        do {
            let captures = try await (focused
                ? CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
                : CompanionScreenCaptureUtility.captureAllScreensAsJPEG())
            let rootDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenClickyExternalControlScreenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

            // External callers receive paths so they can consume the image,
            // but those paths must not become an unbounded screenshot archive.
            let now = Date()
            if let oldEntries = try? FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in oldEntries {
                    let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    if let modifiedAt = values?.contentModificationDate,
                       now.timeIntervalSince(modifiedAt) > 600 {
                        try? FileManager.default.removeItem(at: entry)
                    }
                }
            }

            let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let screens: [[String: Any]] = try captures.enumerated().map { index, capture in
                let fileURL = directory.appendingPathComponent("screen-\(timestamp)-\(index + 1).jpg")
                try capture.imageData.write(to: fileURL, options: .atomic)
                return [
                    "label": capture.label,
                    "path": fileURL.path,
                    "isCursorScreen": capture.isCursorScreen,
                    "displayFrame": [
                        "x": capture.displayFrame.origin.x,
                        "y": capture.displayFrame.origin.y,
                        "width": capture.displayFrame.width,
                        "height": capture.displayFrame.height
                    ],
                    "displayWidthInPoints": capture.displayWidthInPoints,
                    "displayHeightInPoints": capture.displayHeightInPoints,
                    "screenshotWidthInPixels": capture.screenshotWidthInPixels,
                    "screenshotHeightInPixels": capture.screenshotHeightInPixels
                ]
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                try? FileManager.default.removeItem(at: directory)
            }
            return .ok(["screens": screens, "count": screens.count, "focused": focused])
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    func clickExternalControlPoint(_ point: CGPoint, caption: String?) -> OpenClickyExternalControlResponse {
        let targetPoint = Self.clampedExternalCursorPoint(point)
        // H3/M10: previously this force-enabled native CUA (`setEnabled(true)`)
        // and always called `nativeComputerUseController.click` regardless of
        // the selected backend — so a user who selected Background Computer Use
        // still got a cursor-warping native click, and a user who *disabled* CUA
        // had their preference silently overridden. Now: honor the selector, and
        // treat "disabled" as authoritative (return an error, let the caller
        // decide) instead of flipping it back on.
        if !nativeComputerUseController.isEnabled && selectedComputerUseBackend == .nativeSwift {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "external_control.click_disabled",
                fields: [
                    "executor": "openClickyControl",
                    "reason": "Native computer use is disabled. Enable it in Settings to allow bridge clicks."
                ]
            )
            return .error(409, "Computer use is disabled")
        }
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            return clickExternalControlPointViaBackgroundComputerUse(targetPoint, caption: caption)
        case .nativeSwift:
            return clickExternalControlPointViaNativeComputerUse(targetPoint, caption: caption)
        }
    }

    func clickExternalControlPointViaNativeComputerUse(_ targetPoint: CGPoint, caption: String?) -> OpenClickyExternalControlResponse {
        do {
            try nativeComputerUseController.click(at: targetPoint)
            detectedElementScreenLocation = targetPoint
            detectedElementDisplayFrame = NSScreen.screen(containingOrNearestTo: targetPoint)?.frame
            detectedElementBubbleText = Self.pointingBubbleText(for: caption)
            rememberPointedElement(at: targetPoint, displayFrame: detectedElementDisplayFrame, label: caption)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "external_control.click",
                fields: [
                    "executor": "openClickyControl",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "backend": "nativeSwift",
                    "x": Int(targetPoint.x),
                    "y": Int(targetPoint.y),
                    "caption": caption ?? ""
                ]
            )
            return .ok([
                "clicked": true,
                "x": targetPoint.x,
                "y": targetPoint.y,
                "caption": caption ?? ""
            ])
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "external_control.click_error",
                fields: [
                    "executor": "openClickyControl",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "backend": "nativeSwift",
                    "x": Int(targetPoint.x),
                    "y": Int(targetPoint.y),
                    "caption": caption ?? "",
                    "error": error.localizedDescription
                ]
            )
            return .error(500, error.localizedDescription)
        }
    }

    func clickExternalControlPointViaBackgroundComputerUse(_ targetPoint: CGPoint, caption: String?) -> OpenClickyExternalControlResponse {
        // The bridge caller gave us a GLOBAL display point. BCU clicks in
        // window-screenshot pixel space, so we capture the frontmost window
        // (which also yields the stateToken BCU requires — H4), convert the
        // global point into the window's local screenshot space using the AX
        // window bounds, and post the click through the selected backend. This
        // keeps the bridge honest about the user's backend choice (no cursor
        // warp when BCU is selected). Coordinate conversion: localPoint =
        // (globalPoint - windowOrigin) * (screenshotPixels / windowPoints).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.backgroundComputerUseController.captureFrontmostWindowAsJPEG()
                guard let window = OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow() else {
                    throw OpenClickyComputerUseError.noTargetWindow
                }
                // AX bounds use AppKit bottom-left origin; BCU screenshot is
                // top-left. Convert: flip Y, subtract window origin, scale by
                // retina factor derived from screenshot pixels vs window points.
                let screenFrame = (NSScreen.screen(containingOrNearestTo: targetPoint) ?? NSScreen.main)?.frame ?? .zero
                let globalTopLeftY = screenFrame.height - targetPoint.y
                let localX = (targetPoint.x - window.bounds.x)
                let localY = (globalTopLeftY - (screenFrame.height - window.bounds.y))
                let pointsW = max(window.bounds.width, 1)
                let pointsH = max(window.bounds.height, 1)
                let scaleX = Double(capture.screenshotWidthInPixels) / pointsW
                let scaleY = Double(capture.screenshotHeightInPixels) / pointsH
                let scaled = CGPoint(x: localX * scaleX, y: localY * scaleY)
                _ = try await self.backgroundComputerUseController.click(
                    at: scaled,
                    window: capture.windowID,
                    targetAppName: caption,
                    stateToken: capture.stateToken
                )
                self.detectedElementScreenLocation = targetPoint
                self.detectedElementDisplayFrame = NSScreen.screen(containingOrNearestTo: targetPoint)?.frame
                self.detectedElementBubbleText = Self.pointingBubbleText(for: caption)
                self.rememberPointedElement(at: targetPoint, displayFrame: self.detectedElementDisplayFrame, label: caption)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "external_control.click",
                    fields: [
                        "executor": "openClickyControl",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "backend": "backgroundComputerUse",
                        "x": Int(targetPoint.x),
                        "y": Int(targetPoint.y),
                        "caption": caption ?? ""
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "external_control.click_error",
                    fields: [
                        "executor": "openClickyControl",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "backend": "backgroundComputerUse",
                        "x": Int(targetPoint.x),
                        "y": Int(targetPoint.y),
                        "caption": caption ?? "",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
        return .ok([
            "clicked": true,
            "x": targetPoint.x,
            "y": targetPoint.y,
            "caption": caption ?? "",
            "backend": "backgroundComputerUse"
        ])
    }

    /// Spoken output was removed, so external "speak" requests show their text by the pointer instead.
    func speakExternalProxyText(_ text: String, interrupt _: Bool) -> OpenClickyExternalControlResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .error(400, "Missing text") }
        beginCursorReplyPresentation()
        updateVoiceResponseCaption("<cursor_reply>" + trimmed + "</cursor_reply>", force: true, updatesDock: false)
        return .accepted(["shown": true, "textLength": trimmed.count])
    }
}
