import AppKit
import AVFoundation
import SwiftUI

// First-launch desktop onboarding view.
//
// Aesthetic direction: macOS-native, mirroring the language of Apple's own
// Setup Assistant / "Welcome to <App>" sheets. Adaptive light/dark via
// system colors and an `NSVisualEffectView` window-background, SF Pro
// typographic hierarchy, a centered hero composition, an inset grouped
// permission list styled like System Settings, and native bordered button
// styles. The whole view tints to the heySona brand pink via the `.tint`
// modifier on the root, so primary buttons and the accent-tinted brand
// mark pick up the brand without us hand-rolling button chrome.
struct OnboardingView: View {
    @ObservedObject var companionManager: CompanionManager

    let onOnboardingCompleted: () -> Void

    @State private var currentOnboardingStep: OnboardingStep = .welcome

    // heySona brand pink, applied via .tint() so SwiftUI's native bordered /
    // bordered-prominent button styles inherit it the way Apple's own apps
    // pick up their app tint.
    private let heySonaBrandTintColor = Color(hex: "#c44d83")

    enum OnboardingStep: Int, CaseIterable {
        case welcome
        case permissions
        case ready
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            OnboardingWindowBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomActionBar
                    .padding(.horizontal, 36)
                    .padding(.bottom, 28)
            }
        }
        .frame(minWidth: 600, minHeight: 680)
        .tint(heySonaBrandTintColor)
    }

    // MARK: - Step content (animated)

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch currentOnboardingStep {
            case .welcome:
                welcomeStepContent
            case .permissions:
                permissionsStepContent
            case .ready:
                readyStepContent
            }
        }
        .id(currentOnboardingStep)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity.combined(with: .offset(x: -24))
            )
        )
    }

    // MARK: - Welcome

    private var welcomeStepContent: some View {
        VStack(spacing: 0) {
            Spacer()

            heySonaBrandMark
                .padding(.bottom, 28)

            Text("Welcome to heySona")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.primary)
                .padding(.bottom, 12)

            Text("Your AI companion that lives in the menu bar. Hold ⌃⌥ anywhere on your Mac to talk — heySona listens, sees your screen, and answers back.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 36)
    }

    // MARK: - Permissions

    private var permissionsStepContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 56)

            VStack(spacing: 10) {
                Text("Set Up Permissions")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)

                Text("heySona needs the following access. Approve each one and the list will update automatically.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 440)
            }

            Spacer().frame(height: 28)

            permissionsList
                .frame(maxWidth: 460)

            Spacer()
        }
        .padding(.horizontal, 36)
    }

    private var permissionsList: some View {
        VStack(spacing: 0) {
            permissionRow(
                title: "Microphone",
                subtitle: "So heySona can hear you when you hold ⌃⌥.",
                isGranted: companionManager.hasMicrophonePermission,
                isDisabled: false,
                onEnableTapped: requestMicrophonePermission
            )
            permissionListDivider

            permissionRow(
                title: "Accessibility",
                subtitle: "Lets heySona point at on-screen elements.",
                isGranted: companionManager.hasAccessibilityPermission,
                isDisabled: false,
                onEnableTapped: { WindowPositionManager.requestAccessibilityPermission() }
            )
            permissionListDivider

            permissionRow(
                title: "Screen Recording",
                subtitle: "Captures a screenshot only when you press the hotkey.",
                isGranted: companionManager.hasScreenRecordingPermission,
                isDisabled: false,
                onEnableTapped: { WindowPositionManager.requestScreenRecordingPermission() }
            )
            permissionListDivider

            permissionRow(
                title: "Screen Content",
                subtitle: "Confirms heySona can capture the active display.",
                isGranted: companionManager.hasScreenContentPermission,
                isDisabled: !companionManager.hasScreenRecordingPermission,
                onEnableTapped: { companionManager.requestScreenContentPermission() }
            )
            permissionListDivider

            permissionRow(
                title: "Keyboard Shortcut",
                subtitle: "Detects ⌃⌥ as your push-to-talk hotkey.",
                isGranted: companionManager.hasInputMonitoringPermission,
                isDisabled: false,
                onEnableTapped: requestInputMonitoringPermission
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    private var permissionListDivider: some View {
        Divider()
            .padding(.leading, 16)
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        isGranted: Bool,
        isDisabled: Bool,
        onEnableTapped: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isDisabled ? .secondary : .primary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isGranted {
                permissionGrantedLabel
            } else {
                permissionEnableButton(isDisabled: isDisabled, onEnableTapped: onEnableTapped)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: isGranted)
    }

    private var permissionGrantedLabel: some View {
        // Tiny system-style "On" label like macOS System Settings shows next
        // to enabled toggles. Native green checkmark + tertiary "Granted".
        HStack(spacing: 5) {
            Text("✓")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)

            Text("Granted")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
    }

    private func permissionEnableButton(
        isDisabled: Bool,
        onEnableTapped: @escaping () -> Void
    ) -> some View {
        // Native bordered button with .small control size — exactly the
        // shape of action buttons inside System Settings panes.
        Button(action: onEnableTapped) {
            Text(isDisabled ? "Locked" : "Enable")
                .frame(minWidth: 56)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .pointerCursor(isEnabled: !isDisabled)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .trailing)))
    }

    // MARK: - Ready

    private var readyStepContent: some View {
        VStack(spacing: 0) {
            Spacer()

            heySonaBrandMark
                .padding(.bottom, 28)

            Text("You're all set.")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.primary)
                .padding(.bottom, 12)

            Text("heySona now lives quietly in the notch above. Hold ⌃⌥ anywhere on your Mac to begin a conversation.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 36)
    }

    // MARK: - Brand mark

    private var heySonaBrandMark: some View {
        // The heySona triangle (same shape as the menu-bar status icon) inside
        // a soft tinted rounded square — mirrors how Apple's own onboarding
        // sheets ("Welcome to Numbers", "Welcome to Music") lead with the
        // app's icon.
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(heySonaBrandTintColor.opacity(0.14))
                .frame(width: 76, height: 76)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(heySonaBrandTintColor.opacity(0.18), lineWidth: 0.5)
                .frame(width: 76, height: 76)

            HeySonaBrandTriangleShape()
                .fill(heySonaBrandTintColor)
                .frame(width: 34, height: 34)
                .shadow(color: heySonaBrandTintColor.opacity(0.25), radius: 8, x: 0, y: 4)
        }
    }

    // MARK: - Bottom action bar

    private var bottomActionBar: some View {
        HStack(alignment: .center) {
            stepProgressDots

            Spacer()

            primaryActionButton
        }
    }

    private var stepProgressDots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                let isCurrentStep = step == currentOnboardingStep
                Circle()
                    .fill(
                        isCurrentStep
                            ? heySonaBrandTintColor
                            : Color.secondary.opacity(0.25)
                    )
                    .frame(width: 6, height: 6)
                    .scaleEffect(isCurrentStep ? 1.0 : 0.85)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: currentOnboardingStep)
    }

    private var primaryActionButton: some View {
        Button(action: handlePrimaryActionTapped) {
            Text(primaryActionTitle)
                .frame(minWidth: 88)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!isPrimaryActionEnabled)
        .pointerCursor(isEnabled: isPrimaryActionEnabled)
    }

    // MARK: - Primary action state

    private var primaryActionTitle: String {
        switch currentOnboardingStep {
        case .welcome:
            return "Continue"
        case .permissions:
            return "Continue"
        case .ready:
            return "Get Started"
        }
    }

    private var isPrimaryActionEnabled: Bool {
        switch currentOnboardingStep {
        case .welcome:
            return true
        case .permissions:
            return allPermissionsGrantedForOnboarding
        case .ready:
            return true
        }
    }

    // The onboarding requires every permission the menu-bar app uses,
    // including input monitoring (which `allPermissionsGranted` doesn't check
    // because it's evaluated separately by the Dynamic Island).
    private var allPermissionsGrantedForOnboarding: Bool {
        companionManager.allPermissionsGranted && companionManager.hasInputMonitoringPermission
    }

    private func handlePrimaryActionTapped() {
        switch currentOnboardingStep {
        case .welcome:
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                currentOnboardingStep = .permissions
            }
        case .permissions:
            guard allPermissionsGrantedForOnboarding else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                currentOnboardingStep = .ready
            }
        case .ready:
            onOnboardingCompleted()
        }
    }

    // MARK: - Permission request helpers

    private func requestMicrophonePermission() {
        let microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneAuthorizationStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let microphoneSettingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) {
            // If the user already declined, the system prompt won't reappear,
            // so route them to the relevant Privacy & Security pane instead.
            NSWorkspace.shared.open(microphoneSettingsURL)
        }
    }

    private func requestInputMonitoringPermission() {
        if #available(macOS 10.15, *) {
            _ = CGRequestListenEventAccess()
        }
        // Restart the listen-only CGEvent tap so it picks up the newly granted
        // permission without requiring the user to relaunch heySona.
        companionManager.globalPushToTalkShortcutMonitor.start()
    }
}

// MARK: - Brand triangle (mirrors the menu-bar status icon)

// Same equilateral triangle as `MenuBarPanelManager.makeHeySonaMenuBarIcon`,
// re-implemented as a SwiftUI `Shape` so it can be tinted, scaled, and
// shadowed inside the onboarding hero rather than only rasterized into an
// `NSImage` for the menu bar.
private struct HeySonaBrandTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var trianglePath = Path()

        let triangleSize = min(rect.width, rect.height)
        let centerX = rect.midX
        let centerY = rect.midY
        let triangleHeight = triangleSize * sqrt(3.0) / 2.0

        let topVertex = CGPoint(x: centerX, y: centerY - triangleHeight / 1.5)
        let bottomLeftVertex = CGPoint(x: centerX - triangleSize / 2, y: centerY + triangleHeight / 3)
        let bottomRightVertex = CGPoint(x: centerX + triangleSize / 2, y: centerY + triangleHeight / 3)

        let rotationAngleRadians = 35.0 * .pi / 180.0
        func rotatePointAroundCenter(_ point: CGPoint) -> CGPoint {
            let deltaX = point.x - centerX
            let deltaY = point.y - centerY
            let cosAngle = CGFloat(cos(rotationAngleRadians))
            let sinAngle = CGFloat(sin(rotationAngleRadians))
            return CGPoint(
                x: centerX + cosAngle * deltaX - sinAngle * deltaY,
                y: centerY + sinAngle * deltaX + cosAngle * deltaY
            )
        }

        trianglePath.move(to: rotatePointAroundCenter(topVertex))
        trianglePath.addLine(to: rotatePointAroundCenter(bottomLeftVertex))
        trianglePath.addLine(to: rotatePointAroundCenter(bottomRightVertex))
        trianglePath.closeSubpath()

        return trianglePath
    }
}

// MARK: - NSVisualEffectView background

// `NSVisualEffectView` with the `.windowBackground` material gives the
// onboarding the same translucent, system-tinted backdrop Apple's own apps
// use (think the System Settings sheets). It adapts to light/dark mode and
// to the user's accessibility "Reduce transparency" setting automatically.
private struct OnboardingWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .windowBackground
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
