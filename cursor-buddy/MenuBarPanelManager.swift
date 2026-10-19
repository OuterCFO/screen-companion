//
//  MenuBarPanelManager.swift
//  cursor-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside unless pinned.
//

import AppKit
import SwiftUI
import OCCore
import OCUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
    static let clickyPanelContentSizeDidChange = Notification.Name("clickyPanelContentSizeDidChange")
    static let clickyMainPanelResizeStateDidChange = Notification.Name("clickyMainPanelResizeStateDidChange")
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?
    private var contentSizeObserver: NSObjectProtocol?
    private var contentResizeWorkItem: DispatchWorkItem?
    private var isPanelPinned = false
    private var themeObserver: NSObjectProtocol?
    private var tasksObserver: NSObjectProtocol?
    private var glassBackdrop: OpenClickyLiquidGlassBackdropView?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 356
    private let panelHeight: CGFloat = 318
    private let panelMinimumSize = NSSize(width: 356, height: 300)
    private let transientPanelScreenEdgePadding: CGFloat = 12
    private let transientPanelMaximumContentHeight: CGFloat = 720

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
            }
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showPanel()
            }
        }

        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: .clickyPanelContentSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resizeVisiblePanelToCurrentContent()
            }
        }

        themeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            // M22: the closure already runs on the main queue (.main above), but
            // Swift 6 still sees it as nonisolated unless we assert main-actor
            // execution explicitly.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshThemeAppearance()
                self.refreshGlassBackdropAccent()
                self.refreshStatusIcon()
            }
        }

        tasksObserver = NotificationCenter.default.addObserver(
            forName: .openClickyMenuBarTasksDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusIcon() }
        }
    }

    deinit {
        if let observer = tasksObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = contentSizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Low: remove the menu-bar slot on dealloc for symmetry with the
        // observer cleanup above. Negligible today (app-lifetime owner) but
        // prevents a leaked slot if the manager is ever recreated.
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        refreshStatusIcon()
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The only menu bar icon: the pointer in the user's cursor color, with a badge
    /// for running agent tasks (count) or an unseen result (dot).
    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let tasks = companionManager.agentMenuBarStatusManager
        button.image = makeClickyMenuBarIcon(runningCount: tasks.runningCount, hasUnseenResult: tasks.hasUnseenResult)
        button.image?.isTemplate = false
        var tooltip = "OpenClicky"
        if tasks.runningCount > 0 { tooltip += " · \(tasks.runningCount) working" }
        if tasks.hasUnseenResult { tooltip += " · new result (right-click)" }
        button.toolTip = tooltip
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon(runningCount: Int, hasUnseenResult: Bool) -> NSImage {
        let iconSize: CGFloat = 18
        let accent = ClickyAccentTheme.current.nsColor
        let image = NSImage(size: NSSize(width: runningCount > 0 ? iconSize + 8 : iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        accent.setFill()
        path.fill()

        if runningCount > 0 {
            let label = NSAttributedString(string: runningCount > 9 ? "9+" : "\(runningCount)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: accent
            ])
            label.draw(at: NSPoint(x: iconSize - 1, y: iconSize - label.size().height - 1))
        } else if hasUnseenResult {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: iconSize - 6, y: iconSize - 6, width: 5.5, height: 5.5)).fill()
        }

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemContextMenu(from: sender)
            return
        }

        togglePanelVisibility()
    }

    private func togglePanelVisibility() {
        if let panel, panel.isVisible {
            if isPanelPinned {
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            } else {
                hidePanel()
            }
        } else {
            showMainInterfacePanel()
        }
    }

    private func showStatusItemContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let quickItem = NSMenuItem(
            title: "Quick Ask OpenClicky",
            action: #selector(quickAskOpenClickyFromStatusMenu),
            keyEquivalent: ""
        )
        quickItem.target = self
        menu.addItem(quickItem)

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettingsFromStatusMenu),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        companionManager.agentMenuBarStatusManager.addTaskItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(agentHistoryMenuItem())

        menu.popUp(positioning: quickItem, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func agentHistoryMenuItem() -> NSMenuItem {
        let historyItem = NSMenuItem(title: "Task History", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Task History")
        let sessions = companionManager.codexAgentSessions.reversed()

        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No tasks yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: historyTitle(for: session),
                    action: #selector(openHistorySessionFromStatusMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                submenu.addItem(item)
            }
        }

        historyItem.submenu = submenu
        return historyItem
    }

    private func historyTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Untitled task" : title
        return "\(statusLabel(for: session.status)) · \(fallbackTitle)"
    }

    private func statusLabel(for status: CodexAgentSessionStatus) -> String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Working"
        case .ready: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    @objc private func quickAskOpenClickyFromStatusMenu() {
        if OpenClickyPresentationPolicy.menuBarOnly {
            companionManager.showTutorInput(startDictation: false)
            return
        }
        companionManager.showQuickTextInputFromMenuBar()
    }

    @objc private func openSettingsFromStatusMenu() {
        companionManager.showSettingsWindow()
    }

    @objc private func openHistorySessionFromStatusMenu(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID else { return }
        companionManager.selectCodexAgentSession(sessionID)
        companionManager.showCodexHUD()
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        showMainInterfacePanel()
    }

    private func showMainInterfacePanel() {
        companionManager.showTutorInput(startDictation: false)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func refreshGlassBackdropAccent() {
        glassBackdrop?.configure(
            cornerRadius: 28,
            roundsTopCorners: true,
            accentColor: CompactInputWindowManager.nsAccentColor(for: nil),
            strength: .expanded
        )
    }

    private func refreshThemeAppearance() {
        let theme = ClickyTheme.current
        let appearanceName: NSAppearance.Name?
        switch theme {
        case .system:
            appearanceName = nil
        case .light:
            appearanceName = .aqua
        case .dark:
            appearanceName = .darkAqua
        }
        
        if let appearanceName = appearanceName {
            panel?.appearance = NSAppearance(named: appearanceName)
        } else {
            panel?.appearance = nil
        }
    }

    private func positionPanelBelowStatusItem(allowFittingSize: Bool = true) {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? statusItemFrame
        let maximumPanelWidth = max(
            panelMinimumSize.width,
            visibleFrame.width - (transientPanelScreenEdgePadding * 2)
        )
        let availablePanelHeight = max(
            panelMinimumSize.height,
            statusItemFrame.minY - visibleFrame.minY - gapBelowMenuBar - transientPanelScreenEdgePadding
        )
        let maximumPanelHeight = min(availablePanelHeight, transientPanelMaximumContentHeight)

        let actualPanelHeight = preferredPanelHeight(
            maximumPanelHeight: maximumPanelHeight,
            allowFittingSize: allowFittingSize
        )

        // Horizontally center the panel beneath the status item icon
        let currentPanelWidth = max(panel.frame.width, panelWidth)
        let actualPanelWidth = min(currentPanelWidth, maximumPanelWidth)
        let centeredPanelOriginX = statusItemFrame.midX - (actualPanelWidth / 2)
        let panelOriginX = min(
            max(centeredPanelOriginX, visibleFrame.minX + transientPanelScreenEdgePadding),
            visibleFrame.maxX - actualPanelWidth - transientPanelScreenEdgePadding
        )
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: actualPanelWidth, height: actualPanelHeight),
            display: true
        )
    }

    private func resizeVisiblePanelToCurrentContent() {
        resizeVisiblePanelToCurrentContent(after: 0.03)
    }

    private func resizeVisiblePanelToCurrentContent(after delay: TimeInterval) {
        guard let panel, panel.isVisible else { return }

        contentResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if self.isPanelPinned {
                self.resizePinnedPanelToCurrentContent()
            } else {
                self.positionPanelBelowStatusItem()
            }
        }
        contentResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func preferredPanelHeight(maximumPanelHeight: CGFloat, allowFittingSize: Bool = true) -> CGFloat {
        if allowFittingSize,
           let panel,
           let contentView = panel.contentView {
            contentView.needsLayout = true
            contentView.invalidateIntrinsicContentSize()
            let fittingHeight = ceil(contentView.fittingSize.height)
            if fittingHeight.isFinite, fittingHeight > 0 {
                return min(max(panelMinimumSize.height, fittingHeight), maximumPanelHeight)
            }
        }

        return min(max(panelMinimumSize.height, panelHeight), maximumPanelHeight)
    }

    private func resizePinnedPanelToCurrentContent() {
        guard let panel else { return }
        guard let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

        let maximumPanelWidth = max(panelMinimumSize.width, visibleFrame.width - (transientPanelScreenEdgePadding * 2))
        let maximumPanelHeight = min(
            max(panelMinimumSize.height, visibleFrame.height - (transientPanelScreenEdgePadding * 2)),
            transientPanelMaximumContentHeight
        )
        let constrainedWidth = min(panel.frame.width, maximumPanelWidth)
        let constrainedHeight = preferredPanelHeight(maximumPanelHeight: maximumPanelHeight)

        guard constrainedWidth != panel.frame.width || constrainedHeight != panel.frame.height else { return }

        let topY = panel.frame.maxY
        let constrainedOriginX = min(
            max(panel.frame.origin.x, visibleFrame.minX + transientPanelScreenEdgePadding),
            visibleFrame.maxX - constrainedWidth - transientPanelScreenEdgePadding
        )
        let constrainedOriginY = min(
            max(topY - constrainedHeight, visibleFrame.minY + transientPanelScreenEdgePadding),
            visibleFrame.maxY - constrainedHeight - transientPanelScreenEdgePadding
        )

        panel.setFrame(
            NSRect(x: constrainedOriginX, y: constrainedOriginY, width: constrainedWidth, height: constrainedHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

}

// MARK: - Menu Bar Tasks

extension Notification.Name {
    static let openClickyMenuBarTasksDidChange = Notification.Name("openClickyMenuBarTasksDidChange")
}

/// Tracks screen conversations and agent tasks for the single menu bar icon:
/// its badge (running count, unseen result) and the Tasks section of its menu.
@MainActor
final class AgentMenuBarStatusManager: NSObject {
    private(set) var items: [ClickyAgentDockItem] = []
    private var seenFinishedIDs: Set<UUID> = []
    private var hasSynced = false
    private var syncTask: Task<Void, Never>?
    private weak var companionManager: CompanionManager?

    var runningCount: Int { items.filter { $0.status == .starting || $0.status == .running }.count }
    /// An agent finished since the user last looked at it.
    var hasUnseenResult: Bool { items.contains { isFinishedAgent($0) && !seenFinishedIDs.contains($0.id) } }

    func scheduleSync(companionManager: CompanionManager) {
        syncTask?.cancel()
        syncTask = Task { [weak companionManager, weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self, let companionManager else { return }
            self.sync(companionManager: companionManager)
        }
    }

    func sync(companionManager: CompanionManager) {
        self.companionManager = companionManager
        items = Self.menuBarItems(from: companionManager)
        // Results that were already finished at launch are not news.
        if !hasSynced { seenFinishedIDs.formUnion(items.filter(isFinishedAgent).map(\.id)); hasSynced = true }
        seenFinishedIDs.formIntersection(items.map(\.id))
        NotificationCenter.default.post(name: .openClickyMenuBarTasksDidChange, object: self)
    }

    /// Adds the Tasks section (most recent first) to the menu bar icon's menu.
    func addTaskItems(to menu: NSMenu) {
        let header = NSMenuItem(title: items.isEmpty ? "No open tasks" : "Tasks", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in items.reversed() {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let row = NSMenuItem(title: "\(statusLabel(for: item)) · \(title.isEmpty ? "Untitled task" : title)",
                                 action: #selector(openTaskFromMenu(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = item.id
            row.image = NSImage(systemSymbolName: symbolName(for: item), accessibilityDescription: nil)
            if item.status == .starting || item.status == .running {
                let submenu = NSMenu()
                let open = NSMenuItem(title: "Open", action: #selector(openTaskFromMenu(_:)), keyEquivalent: "")
                let stop = NSMenuItem(title: "Stop", action: #selector(stopTaskFromMenu(_:)), keyEquivalent: "")
                for entry in [open, stop] { entry.target = self; entry.representedObject = item.id; submenu.addItem(entry) }
                row.submenu = submenu
            }
            menu.addItem(row)
        }
        if items.contains(where: isFinishedAgent) {
            let clear = NSMenuItem(title: "Clear Finished Agent Tasks", action: #selector(clearFinishedFromMenu), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    private func isFinishedAgent(_ item: ClickyAgentDockItem) -> Bool {
        item.sessionID != nil && (item.status == .done || item.status == .failed)
    }

    private func statusLabel(for item: ClickyAgentDockItem) -> String {
        guard item.sessionID != nil else { return "Chat" }
        switch item.status {
        case .starting: return "Starting"
        case .running: return "Working"
        case .done: return seenFinishedIDs.contains(item.id) ? "Done" : "New result"
        case .failed: return "Stopped"
        }
    }

    private func symbolName(for item: ClickyAgentDockItem) -> String {
        guard item.sessionID != nil else { return "bubble.left" }
        switch item.status {
        case .starting, .running: return "circle.dotted"
        case .done: return seenFinishedIDs.contains(item.id) ? "checkmark.circle" : "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        }
    }

    @objc private func openTaskFromMenu(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID, let companionManager else { return }
        seenFinishedIDs.insert(itemID)
        NotificationCenter.default.post(name: .openClickyMenuBarTasksDidChange, object: self)
        if companionManager.showCompactConversationForAgentDockItem(itemID) { return }
        if companionManager.agentDockItems.contains(where: { $0.id == itemID }) {
            companionManager.openAgentDockItem(itemID)
        } else {
            companionManager.showAgentTask(items.first(where: { $0.id == itemID })?.sessionID)
        }
    }

    @objc private func stopTaskFromMenu(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID, let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == itemID }) {
            companionManager.stopAgentDockItem(itemID)
        } else if let sessionID = items.first(where: { $0.id == itemID })?.sessionID {
            companionManager.stopCodexAgentSession(sessionID, reason: "agent_menu_bar_stop")
        }
    }

    @objc private func clearFinishedFromMenu() {
        guard let companionManager else { return }
        for item in items where isFinishedAgent(item) { companionManager.dismissAgentDockItem(item.id) }
        scheduleSync(companionManager: companionManager)
    }

    private static func menuBarItems(from companionManager: CompanionManager) -> [ClickyAgentDockItem] {
        var dockItemsBySessionID: [UUID: ClickyAgentDockItem] = [:]
        for item in companionManager.agentDockItems {
            if let sessionID = item.sessionID { dockItemsBySessionID[sessionID] = item }
        }
        let sessionItems = companionManager.codexAgentSessions
            .filter { $0.hasVisibleActivity && !companionManager.archivedSessionIDs.contains($0.id) }
            .map { session -> ClickyAgentDockItem in
                dockItemsBySessionID[session.id] ?? ClickyAgentDockItem(
                    id: session.id,
                    sessionID: session.id,
                    title: session.title,
                    userInstruction: session.title,
                    accentTheme: session.accentTheme,
                    status: dockStatus(for: session.status),
                    progressStageLabel: session.progressStage.label,
                    progressStepText: session.latestActivityDisplaySummary ?? session.latestActivitySummary,
                    activityStatusLines: session.activityStatusLines,
                    caption: session.latestActivityDisplaySummary ?? session.latestActivitySummary,
                    suggestedNextActions: session.latestResponseCard?.suggestedNextActions ?? [],
                    createdAt: session.createdAt
                )
            }
        let unsessionedItems = companionManager.agentDockItems.filter { $0.sessionID == nil }
        return Array((sessionItems + unsessionedItems).sorted { $0.createdAt < $1.createdAt }.suffix(10))
    }

    private static func dockStatus(for status: CodexAgentSessionStatus) -> ClickyAgentDockStatus {
        switch status {
        case .starting: return .starting
        case .running: return .running
        case .ready: return .done
        case .stopped, .failed: return .failed
        }
    }
}
