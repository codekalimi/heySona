import AppKit
import ClerkKit
import Combine
import Foundation

@MainActor
final class HeySonaAuthManager: ObservableObject {
    static let shared = HeySonaAuthManager()

    @Published private(set) var isConfigured = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var errorMessage: String?

    private var authEventsTask: Task<Void, Never>?

    private init() {}

    func configureIfNeeded() {
        guard !isConfigured else { return }

        guard let publishableKey = AppBundleConfiguration.clerkPublishableKey else {
            errorMessage = "Missing Clerk publishable key."
            isConfigured = false
            return
        }

        let clerk = Clerk.configure(
            publishableKey: publishableKey,
            options: .init(
                redirectConfig: .init(
                    redirectUrl: AppBundleConfiguration.clerkRedirectURL,
                    callbackUrlScheme: AppBundleConfiguration.clerkCallbackScheme
                ),
                loggerHandler: { logEntry in
                    print("[Clerk] \(logEntry.message)")
                }
            )
        )

        isConfigured = true
        isSignedIn = clerk.session != nil
        observeAuthEvents()
    }

    func signInWithGoogle() {
        configureIfNeeded()
        guard isConfigured else { return }

        isSigningIn = true
        errorMessage = nil

        Task { @MainActor in
            do {
                _ = try await Clerk.shared.auth.signInWithOAuth(provider: .google)
                isSignedIn = Clerk.shared.session != nil
                if isSignedIn {
                    NSApp.activate(ignoringOtherApps: true)
                }
            } catch {
                errorMessage = error.localizedDescription
                print("heySona auth: Google sign-in failed: \(error)")
            }

            isSigningIn = false
        }
    }

    func signOut() {
        configureIfNeeded()
        guard isConfigured else { return }

        Task { @MainActor in
            do {
                try await Clerk.shared.auth.signOut()
                isSignedIn = false
            } catch {
                errorMessage = error.localizedDescription
                print("heySona auth: sign-out failed: \(error)")
            }
        }
    }

    func sessionToken() async -> String? {
        configureIfNeeded()
        guard isConfigured else { return nil }

        do {
            return try await Clerk.shared.auth.getToken()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSignedIn = false
            }
            print("heySona auth: failed to get session token: \(error)")
            return nil
        }
    }

    private func observeAuthEvents() {
        authEventsTask?.cancel()
        authEventsTask = Task { @MainActor in
            for await event in Clerk.shared.auth.events {
                switch event {
                case .signInCompleted, .signUpCompleted:
                    isSignedIn = Clerk.shared.session != nil
                    isSigningIn = false
                    errorMessage = nil
                    if isSignedIn {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                case .signedOut, .accountDeleted:
                    isSignedIn = false
                    isSigningIn = false
                case .sessionChanged(_, let newSession):
                    isSignedIn = newSession != nil
                case .tokenRefreshed:
                    isSignedIn = Clerk.shared.session != nil
                }
            }
        }
    }
}
