//
//  SettingsWindowManager.swift
//  leanring-buddy
//
//  Owns the Settings window. It is a regular titled window (not part of the
//  menu bar panel) so text fields get normal keyboard focus and the window
//  can stay open while the user copies keys from a browser.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let heySonaOpenSettings = Notification.Name("heySonaOpenSettings")
}

@MainActor
final class SettingsWindowManager {
    private var settingsWindow: NSWindow?
    private let companionManager: CompanionManager

    private let settingsWindowWidth: CGFloat = 460
    private let settingsWindowHeight: CGFloat = 620

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            createSettingsWindow()
        }

        // The app has no Dock icon, so it must activate itself or the window
        // would open behind the app the user is currently in.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func createSettingsWindow() {
        let settingsView = SettingsView(companionManager: companionManager)

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(x: 0, y: 0, width: settingsWindowWidth, height: settingsWindowHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: settingsWindowWidth, height: settingsWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "heySona Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.background)
        window.contentView = hostingView
        // Keep the window object alive after closing so reopening is instant
        // and the SwiftUI state (e.g. the loaded voice list) is preserved.
        window.isReleasedWhenClosed = false
        window.center()

        settingsWindow = window
    }
}
