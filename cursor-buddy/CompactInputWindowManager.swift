import AppKit

/// Presents the compact panel: the prompt input, task history, and task controls.
@MainActor
final class CompactInputWindowManager {
    private let promptWindow = MenuBarPromptWindowManager()

    func showConversationInput(entries: [CodexTranscriptEntry], historyVisible: Bool = false, title: String = "OpenClicky",
                               taskChoices: [CompactTaskChoice] = [], selectTask: ((UUID) -> Void)? = nil,
                               loadHistory: CompactHistoryLoader? = nil, connectTask: (() -> Void)? = nil,
                               newTask: (() -> Void)? = nil, removeTask: (() -> Void)? = nil,
                               submit: @escaping (String) -> Void) {
        promptWindow.show(entries: entries, historyVisible: historyVisible, title: title, taskChoices: taskChoices,
                          selectTask: selectTask, loadHistory: loadHistory, connectTask: connectTask,
                          newTask: newTask, removeTask: removeTask, submit: submit)
    }

    func showTextInput(accentTheme _: ClickyAccentTheme? = nil, submitText: @escaping (String) -> Void) {
        promptWindow.show(submit: submitText)
    }

    static func nsAccentColor(for theme: ClickyAccentTheme?) -> NSColor {
        switch theme ?? ClickyAccentTheme.current {
        case .blue: return NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
        case .cyan: return NSColor(calibratedRed: 0.13, green: 0.83, blue: 0.93, alpha: 1.0)
        case .mint: return NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)
        case .lime: return NSColor(calibratedRed: 0.64, green: 0.90, blue: 0.21, alpha: 1.0)
        case .amber: return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1.0)
        case .orange: return NSColor(calibratedRed: 1.00, green: 0.54, blue: 0.24, alpha: 1.0)
        case .rose: return NSColor(calibratedRed: 1.00, green: 0.31, blue: 0.37, alpha: 1.0)
        case .violet: return NSColor(calibratedRed: 0.61, green: 0.43, blue: 1.00, alpha: 1.0)
        case .white: return NSColor(calibratedWhite: 0.97, alpha: 1.0)
        }
    }
}
