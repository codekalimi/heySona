//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts CompanionPanelView
//  via NSHostingView and resizes between quiet controls and a conversation.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let heySonaDismissPanel = Notification.Name("heySonaDismissPanel")
    static let heySonaShowConversationPanel = Notification.Name("heySonaShowConversationPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var openSettingsObserver: NSObjectProtocol?
    private var showConversationObserver: NSObjectProtocol?
    private var panelLayoutCancellables = Set<AnyCancellable>()
    private var applicationActiveBeforePanel: NSRunningApplication?
    private var pendingQuestionSubmissionTask: Task<Void, Never>?
    private let settingsWindowManager: SettingsWindowManager

    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.settingsWindowManager = SettingsWindowManager(companionManager: companionManager)
        super.init()
        createStatusItem()
        observePanelLayout()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .heySonaDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        // The panel posts this from its gear button. The panel closes first so
        // it doesn't float over the Settings window.
        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: .heySonaOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hidePanel()
                self?.settingsWindowManager.showSettingsWindow()
            }
        }

        showConversationObserver = NotificationCenter.default.addObserver(
            forName: .heySonaShowConversationPanel, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showPanel(takingKeyboardFocus: false)
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showConversationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingQuestionSubmissionTask?.cancel()
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeHeySonaMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the heySona mark as a menu bar icon: the pointer cursor with
    /// two sound waves, matching the app icon (see
    /// scripts/generate-brand-assets.swift). Drawn in black and marked as a
    /// template image so macOS tints it for light and dark menu bars.
    private func makeHeySonaMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        // The mark is laid out pointing left (in the app icon's units,
        // centered on the group's middle), then scaled, tilted 40° so the
        // pointer faces up-left, and centered in the icon.
        let markScale: CGFloat = 0.0235
        let markTransform = NSAffineTransform()
        markTransform.translateX(by: iconSize * 0.5, yBy: iconSize * 0.5)
        markTransform.rotate(byDegrees: -40)
        markTransform.scale(by: markScale)
        markTransform.concat()

        let pointerPath = NSBezierPath()
        pointerPath.move(to: CGPoint(x: -355, y: 0))
        pointerPath.line(to: CGPoint(x: -60, y: 140))
        pointerPath.line(to: CGPoint(x: -60, y: -140))
        pointerPath.close()
        pointerPath.lineJoinStyle = .round
        // A thin stroke with round joins softens the corners like the icon's.
        pointerPath.lineWidth = 40

        NSColor.black.setFill()
        NSColor.black.setStroke()
        pointerPath.fill()
        pointerPath.stroke()

        let soundWaveArcCenter = CGPoint(x: -155, y: 0)
        let soundWaveHalfAngleInDegrees: CGFloat = 36
        for soundWaveRadius: CGFloat in [255, 385] {
            let soundWavePath = NSBezierPath()
            soundWavePath.appendArc(
                withCenter: soundWaveArcCenter,
                radius: soundWaveRadius,
                startAngle: -soundWaveHalfAngleInDegrees,
                endAngle: soundWaveHalfAngleInDegrees
            )
            soundWavePath.lineWidth = 72
            soundWavePath.lineCapStyle = .round
            soundWavePath.stroke()
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

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel(takingKeyboardFocus: Bool = true) {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        if takingKeyboardFocus {
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            if frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                applicationActiveBeforePanel = frontmostApplication
            }
            panel?.makeKeyAndOrderFront(nil)
        }
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager) { [weak self] question in
            self?.submitPanelQuestion(question)
        }
        let panelSize = companionManager.panelConversation.panelSize(isReady: isCompanionReady)

        let hostingView = NSHostingView(rootView: companionPanelView)
        // SwiftUI changes its preferred size as the panel expands; this manager
        // owns the window frame so it stays anchored to the menu bar item.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = true
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private var isCompanionReady: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    private func observePanelLayout() {
        companionManager.panelConversation.$isExpanded
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedulePanelLayoutUpdate() }
            .store(in: &panelLayoutCancellables)

        Publishers.CombineLatest4(
            companionManager.$hasAccessibilityPermission,
            companionManager.$hasScreenRecordingPermission,
            companionManager.$hasMicrophonePermission,
            companionManager.$hasScreenContentPermission
        )
        .map { accessibility, screenRecording, microphone, screenContent in
            accessibility && screenRecording && microphone && screenContent
        }
        .combineLatest(companionManager.$hasCompletedOnboarding)
        .map { allPermissionsGranted, hasCompletedOnboarding in allPermissionsGranted && hasCompletedOnboarding }
        .removeDuplicates()
        .sink { [weak self] _ in self?.schedulePanelLayoutUpdate() }
        .store(in: &panelLayoutCancellables)
    }

    private func schedulePanelLayoutUpdate() {
        // Published values are delivered before assignment, so measure on the
        // next run-loop turn after both SwiftUI and the model see the new state.
        DispatchQueue.main.async { [weak self] in
            self?.positionPanelBelowStatusItem(animated: true)
        }
    }

    private func submitPanelQuestion(_ question: String) {
        guard isCompanionReady, !companionManager.showOnboardingVideo,
              !companionManager.buddyDictationManager.isDictationInProgress else { return }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            applicationActiveBeforePanel = frontmostApplication
        }
        hidePanel()
        if let applicationActiveBeforePanel, !applicationActiveBeforePanel.isTerminated {
            NSApp.yieldActivation(to: applicationActiveBeforePanel)
            TypeToAskPanelManager.bringApplicationToFront(applicationActiveBeforePanel)
        }
        pendingQuestionSubmissionTask?.cancel()
        pendingQuestionSubmissionTask = Task { [weak self] in
            // Match type-to-ask's focus handoff: Claude should see the user's
            // app, rather than heySona, when it builds the screenshot context.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.companionManager.submitTypedQuestion(question, presentInMenuBar: true)
        }
    }

    private func positionPanelBelowStatusItem(animated: Bool = false) {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let statusItemFrame = buttonWindow.frame
        let visibleFrame = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        companionManager.panelConversation.maximumPanelHeight = visibleFrame.height
        let panelSize = companionManager.panelConversation.panelSize(isReady: isCompanionReady)
        let panelOriginX = min(max(statusItemFrame.midX - panelSize.width / 2, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
        let panelOriginY = max(visibleFrame.minY, min(statusItemFrame.minY - 6, visibleFrame.maxY) - panelSize.height)

        panel.setFrame(
            NSRect(origin: CGPoint(x: panelOriginX, y: panelOriginY), size: panelSize),
            display: true,
            animate: animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
