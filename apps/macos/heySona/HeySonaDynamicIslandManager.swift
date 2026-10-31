import AppKit
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

// MARK: - Window

private final class HeySonaDynamicIslandWindow: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false
        isExcludedFromWindowsMenu = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Notch Shape

private struct HeySonaNotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 20

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return p
    }
}


@MainActor
final class HeySonaDynamicIslandManager {
    private var window: NSPanel?
    private let companionManager: CompanionManager
    private var cancellable: AnyCancellable?

    // The window is sized to the largest possible notch (expanded state).
    // The inner SwiftUI content animates between the collapsed and expanded
    // widths; the outer window stays this fixed size so we don't have to
    // resize the NSPanel on hover.
    private static let containerSize = CGSize(width: 550, height: 360)

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager

        // Match the Electron notch: if voice activity starts while the island
        // is hidden, bring it back so Listening / Thinking is visible.
        cancellable = companionManager.$voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceState in
                guard voiceState != .idle else { return }
                self?.show(expanded: false)
            }
    }

    func toggle() {
        if let window, window.isVisible { hide() } else { show(expanded: false) }
    }

    /// Shows the island. It stays visible like the Electron notch indicator.
    func show(expanded: Bool = false) {
        if window == nil { createWindow() }
        window?.setFrame(Self.frame(for: Self.containerSize), display: true, animate: false)
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    private func createWindow() {
        let view = HeySonaIslandRoot(companionManager: companionManager)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: Self.containerSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = HeySonaDynamicIslandWindow(
            contentRect: Self.frame(for: Self.containerSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        window = panel
    }

    private static func frame(for size: CGSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }
}

// MARK: - Root View

private enum HeySonaSettingsRoute: Equatable {
    case main
    case agents
    case shortcut
    case microphone
}

private struct HeySonaIslandRoot: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var authManager = HeySonaAuthManager.shared
    @StateObject private var agentIntegrationsManager = AgentIntegrationsManager()
    @State private var isOpen = false
    @State private var isShowingSettings = false
    @State private var selectedShortcut = BuddyPushToTalkShortcut.currentShortcutOption
    @State private var microphoneDevices: [AudioInputDevice] = AudioInputDevice.availableInputDevices()
    @State private var selectedMicrophoneID = AudioInputDevice.defaultInputDeviceID()
    @State private var settingsRoute: HeySonaSettingsRoute = .main
    @State private var hoverCloseTask: Task<Void, Never>?
    @State private var gradientPhase: CGFloat = 0
    @Namespace private var cursorSelectionNamespace

    // Keep the resting island small enough to sit behind the MacBook notch.
    // The clear hover target remains wider/taller so moving over the physical
    // notch expands the island into the full controls.
    private static let collapsedNotchWidth: CGFloat = 170
    private static let activeNotchWidth: CGFloat = 440
    private static let expandedNotchWidth: CGFloat = 470
    private static let agentsNotchWidth: CGFloat = 550
    private static let collapsedNotchHeight: CGFloat = 24
    private static let activeNotchHeight: CGFloat = 34
    private static let containerHeight: CGFloat = 310
    private static let agentsContainerHeight: CGFloat = 360
    private static let hoverActivationWidth: CGFloat = 220
    private static let hoverActivationHeight: CGFloat = 32

    private var isActive: Bool {
        companionManager.voiceState != .idle
    }

    private var currentNotchWidth: CGFloat {
        if isOpen && isShowingSettings && settingsRoute == .agents { return Self.agentsNotchWidth }
        if isOpen { return Self.expandedNotchWidth }
        return isActive ? Self.activeNotchWidth : Self.collapsedNotchWidth
    }

    private var currentContainerHeight: CGFloat {
        isOpen && isShowingSettings && settingsRoute == .agents ? Self.agentsContainerHeight : Self.containerHeight
    }

    private var currentNotchBottomRadius: CGFloat {
        if isOpen { return 22 }
        return isActive ? 14 : 10
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.clear
                    .frame(width: Self.hoverActivationWidth, height: Self.hoverActivationHeight)
                    .contentShape(Rectangle())

                VStack(spacing: 0) {
                    if isOpen {
                        if isShowingSettings {
                            settingsBody
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        } else {
                            expandedBody
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    } else {
                        collapsedBar
                            .transition(.opacity)
                    }
                }
                .frame(width: currentNotchWidth)
                .background(.black)
                .clipShape(HeySonaNotchShape(topRadius: isOpen ? 8 : 6, bottomRadius: currentNotchBottomRadius))
                .overlay {
                    if isActive && !isOpen {
                        HStack {
                            Spacer()
                            RoundedRectangle(cornerRadius: currentNotchBottomRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            stateColor.opacity(0),
                                            stateColor.opacity(0.35),
                                            stateColor.opacity(0),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 1.2)
                                .padding(.vertical, 6)
                                .offset(x: -1)
                        }
                        .transition(.opacity)
                    }
                }
                .onAppear {
                    withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                        gradientPhase = 360
                    }
                }
            }
            .onHover { hovering in
                hoverCloseTask?.cancel()
                if hovering {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                        isOpen = true
                    }
                } else {
                    hoverCloseTask = Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                            isOpen = false
                            isShowingSettings = false
                        }
                    }
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.8), value: isOpen)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isActive)

            Spacer(minLength: 0)
        }
        .frame(width: Self.agentsNotchWidth, height: currentContainerHeight, alignment: .top)
        .allowsHitTesting(true)
    }

    // MARK: - Collapsed (notch bar showing state)

    private var collapsedBar: some View {
        HStack(spacing: 0) {
            if isActive {
                Text(stateLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .transition(.opacity)

                Spacer(minLength: 16)

                activeStateBars
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, isActive ? 16 : 0)
        .frame(maxWidth: .infinity)
        .frame(height: isActive ? Self.activeNotchHeight : Self.collapsedNotchHeight)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: companionManager.voiceState)
    }

    private var activeStateBars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(stateColor.opacity(0.7))
                        .frame(width: 1.5, height: animatedBarHeight(at: index, date: timeline.date))
                }
            }
            .animation(.linear(duration: 0.1), value: companionManager.currentAudioPowerLevel)
        }
    }

    private func animatedBarHeight(at index: Int, date: Date) -> CGFloat {
        let time = CGFloat(date.timeIntervalSinceReferenceDate)

        switch companionManager.voiceState {
        case .listening:
            let profile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]
            let phase = time * 3.0 + CGFloat(index) * 0.45
            let normalizedAudioPowerLevel = max(companionManager.currentAudioPowerLevel - 0.008, 0)
            let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.5, 1), 0.8)
            let reactiveHeight = easedAudioPowerLevel * 8 * profile[index]
            let idlePulse = (sin(phase) + 1) / 2 * 1.2
            return 3 + reactiveHeight + idlePulse
        case .readingScreen:
            let phase = time * 3.2 + CGFloat(index) * 0.55
            let wave = (sin(phase) + 1) / 2
            return 3 + wave * 7
        case .processing:
            let phase = time * 2.4 + CGFloat(index) * 1.0
            let wave = (sin(phase) + 1) / 2
            return 3 + wave * 6
        case .agentWorking:
            let phase = time * 2.8 + CGFloat(index) * 0.7
            let wave = (sin(phase) + 1) / 2
            return 3 + wave * 7
        case .responding:
            let phase = time * 2.4 + CGFloat(index) * 0.9
            let wave = (sin(phase) + 1) / 2
            return 3 + wave * 4
        case .idle:
            return 3
        }
    }

    // MARK: - Expanded

    private var expandedBody: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                stateIcon
                Spacer()
                Button(action: { isShowingSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isShowingSettings ? DS.Colors.pink300 : .white.opacity(0.55))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(isShowingSettings ? 0.14 : 0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")

            }
            .padding(.horizontal, 18)
            .frame(height: 32)

            // Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if !authManager.isSignedIn {
                        signInView
                    } else if !companionManager.allPermissionsGranted || !companionManager.hasInputMonitoringPermission {
                        signedInView
                        permissionsView
                    } else if !companionManager.hasCompletedOnboarding {
                        signedInView
                        onboardingView
                    } else {
                        signedInView
                        readyView
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - State

    @ViewBuilder
    private var stateIcon: some View {
        switch companionManager.voiceState {
        case .idle:
            Image(systemName: "circle")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        case .listening:
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: "#4ADE80"))
                .symbolEffect(.variableColor.iterative, isActive: true)
        case .readingScreen:
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#38BDF8"))
                .symbolEffect(.pulse, isActive: true)
        case .processing:
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "#A78BFA"))
                .symbolEffect(.pulse, isActive: true)
        case .agentWorking:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#F472B6"))
                .symbolEffect(.pulse, isActive: true)
        case .responding:
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: "#60A5FA"))
                .symbolEffect(.variableColor.iterative, isActive: true)
        }
    }

    private var stateLabel: String {
        switch companionManager.voiceState {
        case .idle: "Idle"
        case .listening: "Listening"
        case .readingScreen: "Reading screen"
        case .processing: "Thinking"
        case .agentWorking: "Agents on it"
        case .responding: "Speaking"
        }
    }

    private var stateColor: Color {
        switch companionManager.voiceState {
        case .idle: .white.opacity(0.3)
        case .listening: Color(hex: "#4ADE80")
        case .readingScreen: Color(hex: "#38BDF8")
        case .processing: Color(hex: "#A78BFA")
        case .agentWorking: Color(hex: "#F472B6")
        case .responding: Color(hex: "#60A5FA")
        }
    }

    private var stateGradientColors: [Color] {
        switch companionManager.voiceState {
        case .idle: [.white.opacity(0.1), .white.opacity(0.2)]
        case .listening: [Color(hex: "#22C55E"), Color(hex: "#4ADE80")]
        case .readingScreen: [Color(hex: "#0284C7"), Color(hex: "#38BDF8")]
        case .processing: [Color(hex: "#7C3AED"), Color(hex: "#A78BFA")]
        case .agentWorking: [Color(hex: "#DB2777"), Color(hex: "#F472B6")]
        case .responding: [Color(hex: "#3B82F6"), Color(hex: "#60A5FA")]
        }
    }

    // MARK: - Permissions

    private var permissionsView: some View {
        VStack(spacing: 0) {
            perm("mic.fill", "Microphone", companionManager.hasMicrophonePermission) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            perm("hand.raised.fill", "Accessibility", companionManager.hasAccessibilityPermission) {
                WindowPositionManager.requestAccessibilityPermission()
            }
            perm("record.circle", "Screen Recording", companionManager.hasScreenRecordingPermission) {
                WindowPositionManager.requestScreenRecordingPermission()
            }
            perm("rectangle.dashed", "Screen Content", companionManager.hasScreenContentPermission, disabled: !companionManager.hasScreenRecordingPermission) {
                companionManager.requestScreenContentPermission()
            }
            perm("command", "Keyboard Shortcut", companionManager.hasInputMonitoringPermission) {
                if #available(macOS 10.15, *) { _ = CGRequestListenEventAccess() }
                companionManager.globalPushToTalkShortcutMonitor.start()
            }
        }
    }

    private func perm(_ sfIcon: String, _ title: String, _ granted: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : sfIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted ? .green : DS.Colors.pink300.opacity(0.7))
                .frame(width: 16)

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(disabled ? 0.25 : 0.8))

            Spacer()

            if !granted {
                Button(action: action) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Onboarding

    private var signInView: some View {
        VStack(spacing: 8) {
            Button(action: { authManager.signInWithGoogle() }) {
                HStack(spacing: 8) {
                    if authManager.isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Text(authManager.isSigningIn ? "Signing in..." : "Sign in with Google")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule(style: .continuous).fill(DS.Colors.pink400.opacity(0.22)))
            }
            .buttonStyle(.plain)
            .disabled(authManager.isSigningIn)

            if let errorMessage = authManager.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var signedInView: some View {
        EmptyView()
    }

    private var onboardingView: some View {
        Button("Start Onboarding") { companionManager.triggerOnboarding() }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule(style: .continuous).fill(DS.Colors.pink400.opacity(0.2)))
            .buttonStyle(.plain)
    }

    // MARK: - Ready

    private var settingsBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: {
                    if settingsRoute == .main {
                        isShowingSettings = false
                    } else {
                        settingsRoute = .main
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)

                Text(settingsTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Image(systemName: settingsRoute == .main ? "gearshape.fill" : "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.pink300.opacity(0.9))
            }
            .padding(.horizontal, settingsRoute == .agents ? 22 : 18)
            .frame(height: settingsRoute == .agents ? 40 : 32)

            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch settingsRoute {
                    case .main:
                        settingsMainView
                    case .agents:
                        agentsSettingsView
                    case .shortcut:
                        shortcutSettingsView
                    case .microphone:
                        microphoneSettingsView
                    }
                }
                .padding(.horizontal, settingsRoute == .agents ? 20 : 14)
                .padding(.top, settingsRoute == .agents ? 10 : 8)
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            microphoneDevices = AudioInputDevice.availableInputDevices()
            selectedMicrophoneID = AudioInputDevice.defaultInputDeviceID()
            selectedShortcut = BuddyPushToTalkShortcut.currentShortcutOption
        }
    }

    private var settingsTitle: String {
        switch settingsRoute {
        case .main: "Settings"
        case .agents: "Integrations"
        case .shortcut: "Voice shortcut"
        case .microphone: "Default microphone"
        }
    }

    private var selectedMicrophoneName: String {
        microphoneDevices.first(where: { $0.id == selectedMicrophoneID })?.name ?? "System default"
    }

    private var settingsMainView: some View {
        VStack(spacing: 10) {
            Button(action: { settingsRoute = .shortcut }) {
                settingsNavigationRow("command", "Voice shortcut", selectedShortcut.displayText)
            }
            .buttonStyle(.plain)

            Button(action: {
                microphoneDevices = AudioInputDevice.availableInputDevices()
                selectedMicrophoneID = AudioInputDevice.defaultInputDeviceID()
                settingsRoute = .microphone
            }) {
                settingsNavigationRow("mic.fill", "Default microphone", selectedMicrophoneName)
            }
            .buttonStyle(.plain)

            Button(action: {
                agentIntegrationsManager.refreshStatuses()
                settingsRoute = .agents
            }) {
                settingsNavigationRow(
                    "app.connected.to.app.below.fill",
                    "Integrations",
                    agentIntegrationsManager.connectedSummary
                )
            }
            .buttonStyle(.plain)

            Button(action: { authManager.signOut() }) {
                settingsActionRow("rectangle.portrait.and.arrow.right", "Log out")
            }
            .buttonStyle(.plain)

            Button(action: { NSApp.terminate(nil) }) {
                settingsActionRow("power", "Quit heySona", destructive: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var agentsSettingsView: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(AgentIntegrationsManager.platforms) { platform in
                        agentRow(platform: platform)
                    }
                }
            }
            .frame(maxHeight: 274)

            if let errorMessage = agentIntegrationsManager.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.82))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear {
            agentIntegrationsManager.refreshStatuses()
        }
    }

    private func agentRow(platform: AgentIntegrationsManager.Platform) -> some View {
        let state = agentIntegrationsManager.state(for: platform)
        let isBusy = agentIntegrationsManager.activePlatformSlug == platform.slug

        return HStack(spacing: 12) {
            PlatformLogoView(platform: platform, isConnected: state.isConnected, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(platform.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                Text(state.statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.36))
                    .lineLimit(1)
            }

            Spacer()

            if state.isConnected {
                Button(action: {
                    agentIntegrationsManager.disconnect(platform)
                }) {
                    Text(isBusy && agentIntegrationsManager.isDisconnecting ? "Removing" : "Disconnect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.86))
                        .frame(minWidth: 86)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(Color.red.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(agentIntegrationsManager.isDisconnecting || agentIntegrationsManager.isConnecting || agentIntegrationsManager.isLoading)
                .opacity((agentIntegrationsManager.isDisconnecting || agentIntegrationsManager.isConnecting || agentIntegrationsManager.isLoading) ? 0.65 : 1)
            } else {
                Button(action: {
                    agentIntegrationsManager.connect(platform)
                }) {
                    Text(isBusy && agentIntegrationsManager.isConnecting ? "Opening" : "Connect")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(minWidth: 86)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .disabled(agentIntegrationsManager.isConnecting || agentIntegrationsManager.isDisconnecting || agentIntegrationsManager.isLoading)
                .opacity((agentIntegrationsManager.isConnecting || agentIntegrationsManager.isDisconnecting || agentIntegrationsManager.isLoading) ? 0.65 : 1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 9)
        .overlay(
            Rectangle()
                .frame(height: 0.6)
                .foregroundStyle(.white.opacity(0.06)),
            alignment: .bottom
        )
    }

    private var shortcutSettingsView: some View {
        VStack(spacing: 8) {
            ForEach(BuddyPushToTalkShortcut.ShortcutOption.allCases) { option in
                Button(action: {
                    selectedShortcut = option
                    BuddyPushToTalkShortcut.currentShortcutOption = option
                }) {
                    selectionRow(title: option.displayText, isSelected: selectedShortcut == option)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var microphoneSettingsView: some View {
        VStack(spacing: 8) {
            ForEach(microphoneDevices) { device in
                Button(action: {
                    selectedMicrophoneID = device.id
                    AudioInputDevice.setDefaultInputDevice(id: device.id)
                    microphoneDevices = AudioInputDevice.availableInputDevices()
                }) {
                    selectionRow(title: device.name, isSelected: selectedMicrophoneID == device.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func settingsNavigationRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.pink300.opacity(0.75))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Text(value)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.32))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.055)))
    }

    private func selectionRow(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? DS.Colors.pink300 : .white.opacity(0.22))
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(isSelected ? 0.09 : 0.045)))
    }

    private func settingsSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.pink300.opacity(0.75))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
            Spacer()
            content()
                .labelsHidden()
                .tint(DS.Colors.pink300)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.055)))
    }

    private func settingsActionRow(_ icon: String, _ title: String, destructive: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(destructive ? Color.red.opacity(0.82) : .white.opacity(0.75))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.045)))
    }

    private var readyView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.pink300.opacity(0.6))
                Text("Hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) to talk")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            HStack {
                Text("heySona cursor")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { companionManager.isHeySonaCursorEnabled },
                    set: { companionManager.setHeySonaCursorEnabled($0) }
                ))
                .toggleStyle(.switch)
                .tint(companionManager.selectedCursorColor.accentColor)
                .scaleEffect(0.75)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Cursor color")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 0) {
                    ForEach(HeySonaCursorColor.allCases) { color in
                        cursorColorSegment(color)
                    }
                }
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

        }
    }

    private func cursorColorSegment(_ color: HeySonaCursorColor) -> some View {
        let isSelected = companionManager.selectedCursorColor == color

        return Button(action: { companionManager.setSelectedCursorColor(color) }) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(color.accentColor.opacity(0.16))
                        .matchedGeometryEffect(id: "selectedCursorColor", in: cursorSelectionNamespace)
                }

                MinimalPinkCursorPointer()
                    .fill(color.primaryColor)
                    .frame(width: 18, height: 22)
                    .shadow(color: color.primaryColor.opacity(isSelected ? 0.55 : 0.25), radius: isSelected ? 7 : 3, x: 0, y: 0)
                    .overlay(
                        MinimalPinkCursorPointer()
                            .stroke(.white.opacity(isSelected ? 0.55 : 0.18), lineWidth: isSelected ? 1.1 : 0.7)
                            .frame(width: 18, height: 22)
                    )
                    .rotationEffect(.degrees(-8))
                    .scaleEffect(isSelected ? 1.08 : 0.92)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                if color != HeySonaCursorColor.allCases.last {
                    Rectangle()
                        .fill(.white.opacity(0.075))
                        .frame(width: 1, height: 22)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Select \(color.displayName) cursor")
        }
        .buttonStyle(.plain)
    }
}

private struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String

    static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    static func setDefaultInputDevice(id: AudioDeviceID) {
        var newID = id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &newID)
    }

    static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }
        return deviceIDs.compactMap { id in
            guard hasInputStreams(deviceID: id) else { return nil }
            return AudioInputDevice(id: id, name: deviceName(deviceID: id))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "Microphone" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        return name as String
    }
}
