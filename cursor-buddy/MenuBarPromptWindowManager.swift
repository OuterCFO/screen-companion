import AppKit
import SwiftUI

typealias CompactHistoryLoader = @MainActor () async throws -> [CodexTranscriptEntry]

nonisolated struct CompactTaskChoice: Identifiable {
    let id: UUID
    let title: String
    /// Chat, Working, Done, or Stopped.
    var status = "Chat"
    var lastActivity = Date.distantPast
    var menuTitle: String { "\(status) · \(title)" }

    /// The Tasks menu shows this many recent tasks; the rest go under Older.
    static let recentLimit = 8
}

@MainActor
final class MenuBarPromptWindowManager {
    private var panel: NSPanel?
    private var previousApplication: NSRunningApplication?

    func show(entries: [CodexTranscriptEntry] = [], historyVisible: Bool = false, title: String = "OpenClicky",
              taskChoices: [CompactTaskChoice] = [], selectTask: ((UUID) -> Void)? = nil,
              loadHistory: CompactHistoryLoader? = nil, connectTask: (() -> Void)? = nil,
              newTask: (() -> Void)? = nil, removeTask: (() -> Void)? = nil,
              clearOldTasks: (() -> Void)? = nil,
              submit: @escaping (String) -> Void) {
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = application
        }
        if panel == nil {
            let window = CompactPromptPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 76),
                                            styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
            window.level = .statusBar
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = window
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: MenuBarPromptView(
            entries: entries, historyVisible: historyVisible, title: title, taskChoices: taskChoices, selectTask: selectTask, loadHistory: loadHistory, connectTask: connectTask, newTask: newTask, removeTask: removeTask, clearOldTasks: clearOldTasks,
            submit: { [weak self] text in self?.dismiss(); submit(text) },
            cancel: { [weak self] in self?.dismiss() },
            resize: { [weak self] height in self?.resize(to: height) }
        ))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let height: CGFloat = historyVisible ? 336 : 76
            panel.setFrame(NSRect(x: screen.visibleFrame.maxX - 460,
                                  y: screen.visibleFrame.maxY - 20 - height,
                                  width: 440, height: height), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resize(to height: CGFloat) {
        guard let panel else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: 440, height: height), display: true)
    }

    private func dismiss() {
        DictationPasteCapture.shared.stop()
        panel?.orderOut(nil)
        previousApplication?.activate(options: [])
        previousApplication = nil
    }
}

private final class CompactPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct MenuBarPromptView: View {
    let entries: [CodexTranscriptEntry]
    @State var historyVisible: Bool
    let title: String
    let taskChoices: [CompactTaskChoice]
    let selectTask: ((UUID) -> Void)?
    let loadHistory: CompactHistoryLoader?
    let connectTask: (() -> Void)?
    let newTask: (() -> Void)?
    let removeTask: (() -> Void)?
    let clearOldTasks: (() -> Void)?
    let submit: (String) -> Void
    let cancel: () -> Void
    let resize: (CGFloat) -> Void
    @State private var loadedEntries: [CodexTranscriptEntry]?
    @State private var historyError: String?
    @State private var confirmRemoval = false
    @State private var draft = ""
    @State private var editorHeight: CGFloat = 32

    private var displayedEntries: [CodexTranscriptEntry] { loadedEntries ?? entries }
    private var totalHeight: CGFloat { editorHeight + 70 + (historyVisible ? 260 : 0) }

    var body: some View {
        VStack(spacing: 8) {
            if historyVisible {
                HStack {
                    Text(title).lineLimit(1).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Hide history") { historyVisible = false }.buttonStyle(.plain)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let historyError { Text(historyError).foregroundStyle(.secondary) }
                            if displayedEntries.isEmpty { Text("No messages yet.").foregroundStyle(.secondary) }
                            ForEach(displayedEntries) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.role == .user ? "You" : "OpenClicky")
                                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    Text(entry.text).font(.system(size: 12)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(entry.id)
                            }
                        }
                    }.frame(height: 228)
                    .onAppear { if let id = displayedEntries.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            HStack(alignment: .center, spacing: 12) {
                CompactPromptEditor(text: $draft, height: $editorHeight, submit: submit, cancel: cancel)
                    .frame(height: editorHeight)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Ask OpenClicky…").font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.top, 4).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).accessibilityLabel("Close input")
            }
            HStack(spacing: 14) {
                Text(title).lineLimit(1).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let selectTask {
                    Menu("Tasks") {
                        ForEach(taskChoices.prefix(CompactTaskChoice.recentLimit)) { task in
                            Button(task.menuTitle) { selectTask(task.id) }
                        }
                        if taskChoices.count > CompactTaskChoice.recentLimit {
                            Menu("Older (\(taskChoices.count - CompactTaskChoice.recentLimit))") {
                                ForEach(taskChoices.dropFirst(CompactTaskChoice.recentLimit)) { task in
                                    Button(task.menuTitle) { selectTask(task.id) }
                                }
                            }
                        }
                        if let clearOldTasks, taskChoices.count > 1 {
                            Divider()
                            Button("Clear old tasks (keeps current and running)", action: clearOldTasks)
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                if !historyVisible { Button("History") { historyVisible = true } }
                if let connectTask { Button("Connect", action: connectTask) }
                if let newTask { Button("New task", action: newTask) }
                if removeTask != nil { Button("Remove task") { confirmRemoval = true } }
            }.buttonStyle(.plain).font(.system(size: 11))
            .confirmationDialog("Remove this cursor task? Its saved history and any connected Codex session will be kept.", isPresented: $confirmRemoval) {
                Button("Remove task", role: .destructive) { removeTask?() }
                Button("Cancel", role: .cancel) { }
            }

        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(width: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
        .onAppear { resize(totalHeight) }
        .onChange(of: totalHeight) { resize(totalHeight) }
        .task(id: historyVisible) {
            guard historyVisible, let loadHistory else { return }
            do { loadedEntries = try await loadHistory(); historyError = nil }
            catch { if !Task.isCancelled { historyError = "Could not refresh Codex history: " + error.localizedDescription } }
        }
        .onExitCommand(perform: cancel)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submit(text)
    }
}

private struct CompactPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let submit: (String) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = FocusedPromptTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 32))
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 12)
        editor.textColor = .white
        editor.drawsBackground = false
        editor.insertionPointColor = .white
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Ask OpenClicky")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CompactPromptEditor
        init(_ parent: CompactPromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let nextHeight = min(180, max(32, ceil(layout.usedRect(for: container).height) + 8))
            parent.height = nextHeight
            editor.scrollRangeToVisible(editor.selectedRange())
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.cancel(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)),
               !NSEvent.modifierFlags.contains(.shift) {
                let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parent.submit(text) }
                return true
            }
            return false
        }
    }
}

private final class FocusedPromptTextView: NSTextView {
    /// Inserts the dictated text even when the paste is handled after OpenSuperWhisper restored the clipboard.
    override func paste(_ sender: Any?) {
        if let transcription = DictationPasteCapture.shared.takeTranscription() {
            insertText(transcription, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let attachedWindow = window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak attachedWindow] in
            guard let self, let attachedWindow, self.window === attachedWindow,
                  attachedWindow.isVisible else { return }
            attachedWindow.makeKeyAndOrderFront(nil)
            attachedWindow.makeFirstResponder(self)
        }
    }
}
