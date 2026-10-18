import AppKit
import CoreGraphics
import Foundation

extension CompanionManager {
    /// Writes text for the field the user was in when they pressed Fn + Command, then pastes it there.
    func performWriteRequest(_ request: String) {
        let prompt = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let target = writeTargetApplication
        let model = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        beginCursorReplyPresentation()
        updateVoiceResponseCaption("<cursor_reply>Writing…</cursor_reply>", force: true, updatesDock: false)
        OpenClickyMessageLogStore.shared.append(lane: "voice", direction: "outgoing", event: "write_mode.request", fields: [
            "model": model.id, "targetApp": target?.bundleIdentifier ?? "unknown", "promptLength": prompt.count
        ])

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let captures = (try? await self.captureAllScreensForVoiceResponseIfAvailable()) ?? []
                let images = captures.map { capture in
                    (data: capture.imageData,
                     label: capture.label + " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)")
                }
                let startedAt = Date()
                let raw = try await self.answerProviders.answer(AnswerRequest(
                    model: model, images: images, systemPrompt: WriteModePolicy.systemPrompt,
                    history: [], prompt: prompt, assistantPrefill: nil
                )) { [weak self] partial in
                    let words = WriteModePolicy.wordCount(partial)
                    self?.updateVoiceResponseCaption("<cursor_reply>Writing… \(words) words</cursor_reply>", force: true, updatesDock: false)
                }
                let text = WriteModePolicy.cleanedText(raw)
                guard !text.isEmpty else { throw ClaudeCodeCLIProtocol.error("The model returned no text to insert.") }
                await Self.paste(text, into: target)
                let words = WriteModePolicy.wordCount(text)
                self.updateVoiceResponseCaption("<cursor_reply>" + WriteModePolicy.doneMessage(wordCount: words, appName: target?.localizedName)
                                                + "</cursor_reply>", force: true, updatesDock: false)
                OpenClickyMessageLogStore.shared.append(lane: "voice", direction: "incoming", event: "write_mode.inserted", fields: [
                    "model": model.id, "wordCount": words, "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                ])
            } catch {
                let message = ProviderErrorMessage.userFacing(error.localizedDescription, modelLabel: model.label)
                    ?? "Couldn't write that: \(error.localizedDescription)"
                self.updateVoiceResponseCaption("<cursor_reply>" + message + "</cursor_reply>", force: true, updatesDock: false)
                OpenClickyMessageLogStore.shared.append(lane: "voice", direction: "error", event: "write_mode.failed", fields: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    /// Pastes through the clipboard (reliable for long and non-ASCII text), then restores the user's clipboard.
    private static func paste(_ text: String, into application: NSRunningApplication?) async {
        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        application?.activate()
        try? await Task.sleep(for: .milliseconds(350))
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        // Give the target app time to read the clipboard before restoring the user's contents.
        try? await Task.sleep(for: .milliseconds(800))
        guard !savedItems.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(savedItems.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        })
    }
}
