import AppKit
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct HeySonaApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

extension HeySonaApp {
    static func openAppAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }
}



@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("heySona: Starting...")
        print("heySona: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        HeySonaAuthManager.shared.configureIfNeeded()

        HeySonaAnalytics.configure()
        HeySonaAnalytics.trackAppOpened()

        // The companion manager owns permission polling, dictation, and the
        // overlay regardless of whether onboarding has been completed, so we
        // start it eagerly. Its `start()` is a no-op for the cursor overlay
        // until `hasCompletedOnboarding` is true, so it's safe to call here.
        companionManager.start()

        // First launch: the menu-bar status item and Dynamic Island are
        // deferred until the user finishes the desktop onboarding window.
        // Any subsequent launch goes straight to the existing menu-bar
        // experience.
        if companionManager.hasCompletedOnboarding {
            startMenuBarExperience()
        } else {
            presentFirstLaunchOnboardingWindow()
        }

        registerAsLoginItemIfNeeded()
        
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    // MARK: - Onboarding

    
    
    
    private func presentFirstLaunchOnboardingWindow() {
        HeySonaAnalytics.trackOnboardingStarted()

        let onboardingController = OnboardingWindowController(
            companionManager: companionManager,
            onOnboardingCompleted: { [weak self] in
                self?.handleOnboardingDidComplete()
            }
        )
        onboardingWindowController = onboardingController
        onboardingController.presentOnboardingWindow()
    }

    private func handleOnboardingDidComplete() {
        // Drop the strong reference now that the window is gone. The
        // controller already cleared its NSWindow.
        onboardingWindowController = nil

        // Now that we're back in accessory mode, bring up the regular
        // menu-bar status item and the Dynamic Island.
        startMenuBarExperience()
    }

    
    
    
    private func startMenuBarExperience() {
        if menuBarPanelManager != nil { return }
        let newMenuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        menuBarPanelManager = newMenuBarPanelManager

        // Keep the notch island visible like the Electron app so the
        // Listening / Thinking / Speaking state is always surfaced.
        newMenuBarPanelManager.showPanelOnLaunch()
    }

    
    
    
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("heySona: Registered as login item")
            } catch {
                print("heySona: Failed to register as login item: \(error)")
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == AppBundleConfiguration.clerkCallbackScheme }) else { return }
        HeySonaAuthManager.shared.configureIfNeeded()
        if HeySonaAuthManager.shared.isSignedIn {
            HeySonaApp.openAppAndActivate()
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("heySona: Sparkle updater failed to start: \(error)")
        }
    }
}
