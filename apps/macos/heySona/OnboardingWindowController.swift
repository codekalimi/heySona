import AppKit
import SwiftUI

// Owns the regular NSWindow that hosts the first-launch onboarding flow.
//
// heySona normally runs as a menu-bar accessory app (LSUIElement=true), so on
// first launch the controller flips the activation policy to .regular,
// making heySona appear in the Dock and behave like a normal desktop app for
// the duration of the onboarding. After the user finishes the onboarding,
// it flips the policy back to .accessory and tears down the window so the
// existing Dynamic Island / menu-bar experience can take over.
//
// The window intentionally uses standard macOS chrome (traffic lights,
// hidden title, transparent title bar, draggable background) so it feels
// like a native desktop app. Hitting the red traffic light or Cmd+W
// terminates the app — closing without finishing onboarding would leave
// the user with neither a desktop window nor a menu-bar icon.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var onboardingWindow: NSWindow?

    private let companionManager: CompanionManager

    // Invoked exactly once after the user finishes the onboarding flow and
    // the window has been hidden. The app delegate uses this to bring up
    // the menu-bar status item and the Dynamic Island.
    private let onOnboardingCompleted: () -> Void

    init(companionManager: CompanionManager, onOnboardingCompleted: @escaping () -> Void) {
        self.companionManager = companionManager
        self.onOnboardingCompleted = onOnboardingCompleted
        super.init()
    }

    func presentOnboardingWindow() {
        if let existingWindow = onboardingWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingRootView = OnboardingView(
            companionManager: companionManager,
            onOnboardingCompleted: { [weak self] in
                self?.handleOnboardingCompleted()
            }
        )

        let initialContentSize = NSSize(width: 600, height: 680)
        let hostingView = NSHostingView(rootView: onboardingRootView)
        hostingView.frame = NSRect(origin: .zero, size: initialContentSize)

        let newOnboardingWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            // Standard macOS chrome — traffic lights are visible because of
            // .closable. The title text is hidden and the title bar is made
            // transparent below so the chrome blends into the visual-effect
            // material the SwiftUI view paints behind itself.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newOnboardingWindow.title = "heySona"
        newOnboardingWindow.titleVisibility = .hidden
        newOnboardingWindow.titlebarAppearsTransparent = true
        newOnboardingWindow.isMovableByWindowBackground = true
        newOnboardingWindow.contentView = hostingView
        newOnboardingWindow.center()
        newOnboardingWindow.delegate = self
        newOnboardingWindow.isReleasedWhenClosed = false

        // Let the SwiftUI `NSVisualEffectView` background render through —
        // a hard window background colour would defeat the translucency.
        newOnboardingWindow.isOpaque = false
        newOnboardingWindow.backgroundColor = .clear

        // Disable / hide the zoom and miniaturize traffic lights. Onboarding
        // is a fixed-size composition; resizing it would break the layout.
        newOnboardingWindow.standardWindowButton(.zoomButton)?.isEnabled = false
        newOnboardingWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newOnboardingWindow.standardWindowButton(.zoomButton)?.isHidden = true

        // Flip the app to a normal foreground app so the onboarding window
        // gets a Dock icon, app menu, and standard window-management chrome
        // for the duration of the onboarding.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        newOnboardingWindow.makeKeyAndOrderFront(nil)

        onboardingWindow = newOnboardingWindow
    }

    private func handleOnboardingCompleted() {
        companionManager.completeFirstLaunchOnboarding()

        // Switch back to a menu-bar accessory app before creating the cursor
        // overlay. Creating the overlay while the onboarding window is still
        // the active regular app can leave the pointer hidden until the first
        // push-to-talk press recreates the overlay.
        NSApp.setActivationPolicy(.accessory)

        if let openOnboardingWindow = onboardingWindow {
            openOnboardingWindow.delegate = nil
            openOnboardingWindow.orderOut(nil)
        }
        onboardingWindow = nil

        companionManager.showHeySonaCursorAfterFirstLaunchOnboarding()
        onOnboardingCompleted()
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the onboarding window before completion leaves the app in
        // a half-configured state with no menu-bar entry point, so we treat
        // a deliberate close as "quit". The user can relaunch from the Dock
        // / Spotlight to retry the onboarding.
        Task { @MainActor in
            NSApp.terminate(nil)
        }
        return false
    }
}
