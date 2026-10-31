import AVFoundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class AgentIntegrationsManager: ObservableObject {
    struct Platform: Identifiable, Hashable {
        let slug: String
        let name: String
        let logoURL: URL?

        var id: String { slug }

        init(slug: String, name: String, logoURL: URL? = nil, usesDefaultLogo: Bool = true) {
            self.slug = slug
            self.name = name
            self.logoURL = logoURL ?? (usesDefaultLogo ? URL(string: "https://images.weserv.nl/?url=logos.composio.dev/api/\(slug)&output=png") : nil)
        }
    }

    struct IntegrationState: Equatable {
        var isConnected = false
        var statusText = "Not connected"
    }

    static let platforms: [Platform] = [
        Platform(slug: "notion", name: "Notion"),
        Platform(slug: "gmail", name: "Gmail"),
        Platform(slug: "googlecalendar", name: "Google Calendar"),
        Platform(slug: "googledrive", name: "Google Drive"),
        Platform(slug: "googledocs", name: "Google Docs"),
        Platform(slug: "googlesheets", name: "Google Sheets"),
        Platform(slug: "googleslides", name: "Google Slides"),
        Platform(slug: "slack", name: "Slack"),
        Platform(slug: "github", name: "GitHub"),
        Platform(slug: "gitlab", name: "GitLab"),
        Platform(slug: "jira", name: "Jira"),
        Platform(slug: "linear", name: "Linear"),
        Platform(slug: "trello", name: "Trello", usesDefaultLogo: false),
        Platform(slug: "asana", name: "Asana"),
        Platform(slug: "clickup", name: "ClickUp"),
        Platform(slug: "monday", name: "monday.com"),
        Platform(slug: "airtable", name: "Airtable"),
        Platform(slug: "hubspot", name: "HubSpot"),
        Platform(slug: "salesforce", name: "Salesforce"),
        Platform(slug: "pipedrive", name: "Pipedrive"),
        Platform(slug: "zendesk", name: "Zendesk"),
        Platform(slug: "intercom", name: "Intercom"),
        Platform(slug: "discord", name: "Discord"),
        Platform(slug: "outlook", name: "Outlook"),
        Platform(slug: "one_drive", name: "OneDrive"),
        Platform(slug: "dropbox", name: "Dropbox"),
        Platform(slug: "shopify", name: "Shopify"),
        Platform(slug: "stripe", name: "Stripe"),
        Platform(slug: "quickbooks", name: "QuickBooks"),
        Platform(slug: "xero", name: "Xero"),
        Platform(slug: "zoom", name: "Zoom"),
        Platform(slug: "calendly", name: "Calendly"),
        Platform(slug: "confluence", name: "Confluence"),
        Platform(slug: "canva", name: "Canva"),
        Platform(slug: "youtube", name: "YouTube"),
        Platform(slug: "twitter", name: "X / Twitter"),
        Platform(slug: "linkedin", name: "LinkedIn"),
        Platform(slug: "facebook", name: "Facebook"),
        Platform(slug: "spotify", name: "Spotify"),
        Platform(slug: "whatsapp", name: "WhatsApp"),
        Platform(slug: "zoho", name: "Zoho"),
        Platform(slug: "posthog", name: "PostHog")
    ]

    @Published private(set) var isLoading = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isDisconnecting = false
    @Published private(set) var activePlatformSlug: String?
    @Published private(set) var states: [String: IntegrationState] = Dictionary(
        uniqueKeysWithValues: AgentIntegrationsManager.platforms.map { ($0.slug, IntegrationState()) }
    )
    @Published private(set) var errorMessage: String?

    private static var cachedStates: [String: IntegrationState]?
    private static var lastStatusRefresh: Date?
    private static let minimumStatusRefreshInterval: TimeInterval = 60

    var connectedPlatforms: [Platform] {
        Self.platforms.filter { state(for: $0).isConnected }
    }

    var connectedSummary: String {
        let connected = connectedPlatforms
        if connected.isEmpty { return "Connect apps" }
        if connected.count == 1 { return "\(connected[0].name) connected" }
        return "\(connected.count) apps connected"
    }

    private struct ToolkitStatusResponse: Decodable {
        let configured: Bool?
        let connected: Bool
        let status: String?
    }

    private struct ToolkitStatusesRequest: Encodable {
        let toolkits: [String]
    }

    private struct ToolkitStatusesResponse: Decodable {
        let statuses: [String: ToolkitStatusResponse]
    }

    private struct ToolkitConnectResponse: Decodable {
        let redirectUrl: String
    }

    func state(for platform: Platform) -> IntegrationState {
        states[platform.slug] ?? IntegrationState()
    }

    func refreshStatuses(force: Bool = false) {
        Task {
            await loadStatuses(force: force)
        }
    }

    func connect(_ platform: Platform) {
        Task {
            await beginConnection(for: platform)
        }
    }

    func disconnect(_ platform: Platform) {
        Task {
            await disconnectConnection(for: platform)
        }
    }

    private func loadStatuses(force: Bool = false) async {
        guard !isLoading else { return }

        if !force,
           let cachedStates = Self.cachedStates,
           let lastStatusRefresh = Self.lastStatusRefresh,
           Date().timeIntervalSince(lastStatusRefresh) < Self.minimumStatusRefreshInterval {
            states = cachedStates
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var request = try await makeAuthorizedRequest(path: "/integrations/statuses", method: "POST")
            request.httpBody = try JSONEncoder().encode(ToolkitStatusesRequest(toolkits: Self.platforms.map(\.slug)))

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let statusesResponse = try JSONDecoder().decode(ToolkitStatusesResponse.self, from: data)

            for platform in Self.platforms {
                if let status = statusesResponse.statuses[platform.slug] {
                    states[platform.slug] = state(from: status)
                } else {
                    states[platform.slug] = IntegrationState(isConnected: false, statusText: "Not connected")
                }
            }

            Self.cachedStates = states
            Self.lastStatusRefresh = Date()
        } catch {
            for platform in Self.platforms {
                states[platform.slug] = IntegrationState(isConnected: false, statusText: "Unavailable")
            }
            errorMessage = error.localizedDescription
        }
    }

    private func beginConnection(for platform: Platform) async {
        guard !isConnecting else { return }
        isConnecting = true
        activePlatformSlug = platform.slug
        errorMessage = nil
        defer {
            isConnecting = false
            activePlatformSlug = nil
        }

        do {
            let request = try await makeAuthorizedRequest(path: "/integrations/\(platform.slug)/connect", method: "POST")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let connectResponse = try JSONDecoder().decode(ToolkitConnectResponse.self, from: data)

            guard let redirectURL = URL(string: connectResponse.redirectUrl) else {
                throw NSError(domain: "AgentIntegrations", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid \(platform.name) connection URL."
                ])
            }

            NSWorkspace.shared.open(redirectURL)
            states[platform.slug] = IntegrationState(isConnected: false, statusText: "Waiting for \(platform.name)")
            Self.cachedStates = nil
            Self.lastStatusRefresh = nil

            for delay in [2_000_000_000, 4_000_000_000, 8_000_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                await loadStatuses(force: true)
                if state(for: platform).isConnected { break }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func disconnectConnection(for platform: Platform) async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        activePlatformSlug = platform.slug
        errorMessage = nil
        defer {
            isDisconnecting = false
            activePlatformSlug = nil
        }

        do {
            let request = try await makeAuthorizedRequest(path: "/integrations/\(platform.slug)/disconnect", method: "DELETE")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            states[platform.slug] = IntegrationState(isConnected: false, statusText: "Not connected")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func state(from status: ToolkitStatusResponse) -> IntegrationState {
        if status.configured == false {
            return IntegrationState(isConnected: false, statusText: "Server not configured")
        }
        if status.connected {
            return IntegrationState(isConnected: true, statusText: "Connected")
        }
        return IntegrationState(isConnected: false, statusText: displayStatus(status.status))
    }

    private func displayStatus(_ status: String?) -> String {
        guard let status, !status.isEmpty else { return "Not connected" }
        if status == "NOT_CONNECTED" { return "Not connected" }

        return status
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func makeAuthorizedRequest(path: String, method: String) async throws -> URLRequest {
        guard let url = URL(string: "\(AppBundleConfiguration.serverBaseURL)\(path)") else {
            throw NSError(domain: "AgentIntegrations", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid server URL."
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken = await HeySonaAuthManager.shared.sessionToken() {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AgentIntegrations", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid server response."
            ])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "AgentIntegrations", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: body
            ])
        }
    }
}

struct PlatformLogoView: View {
    let platform: AgentIntegrationsManager.Platform
    let isConnected: Bool
    let size: CGFloat

    @StateObject private var imageLoader = PlatformLogoImageLoader.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.white.opacity(isConnected ? 0.1 : 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .stroke(isConnected ? DS.Colors.success.opacity(0.35) : Color.white.opacity(0.055), lineWidth: 0.6)
                )

            if let image = platform.logoURL.flatMap({ imageLoader.image(for: $0) }) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if let logoURL = platform.logoURL {
                imageLoader.load(logoURL)
            }
        }
    }

    private var fallbackLogo: some View {
        Text(String(platform.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
            .foregroundColor(isConnected ? DS.Colors.success : DS.Colors.textTertiary)
    }
}

@MainActor
final class PlatformLogoImageLoader: ObservableObject {
    static let shared = PlatformLogoImageLoader()

    @Published private var images: [URL: NSImage] = [:]
    private var inFlightTasks: [URL: Task<Void, Never>] = [:]

    func image(for url: URL) -> NSImage? {
        images[url]
    }

    func load(_ url: URL) {
        guard images[url] == nil, inFlightTasks[url] == nil else { return }

        inFlightTasks[url] = Task {
            defer { inFlightTasks[url] = nil }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200...299).contains(httpResponse.statusCode),
                    let image = NSImage(data: data)
                else {
                    return
                }

                images[url] = image
            } catch {
                return
            }
        }
    }
}

private enum CompanionPanelTab {
    case home
    case agents
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var agentIntegrationsManager = AgentIntegrationsManager()
    @State private var selectedTab: CompanionPanelTab = .home

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            tabPicker
                .padding(.top, 12)
                .padding(.horizontal, 16)

            if selectedTab == .home {
                homeTabContent
            } else {
                agentsTabContent
            }

            
            
            
            
            
            
            
            

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    

    private var panelHeader: some View {
        HStack {
            Text("heySona")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .HeySonaDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            panelTabButton(title: "Home", iconName: "sparkles", tab: .home)
            panelTabButton(title: "Agents", iconName: "app.connected.to.app.below.fill", tab: .agents)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func panelTabButton(title: String, iconName: String, tab: CompanionPanelTab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            selectedTab = tab
            if tab == .agents {
                agentIntegrationsManager.refreshStatuses(force: true)
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var homeTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }
        }
    }

    private var agentsTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AGENTS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, 16)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(AgentIntegrationsManager.platforms) { platform in
                        integrationRow(platform: platform)
                    }
                }
            }
            .frame(maxHeight: 360)

            if let errorMessage = agentIntegrationsManager.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
    }

    private func integrationRow(platform: AgentIntegrationsManager.Platform) -> some View {
        let state = agentIntegrationsManager.state(for: platform)
        let isBusy = agentIntegrationsManager.activePlatformSlug == platform.slug

        return HStack(spacing: 10) {
            PlatformLogoView(platform: platform, isConnected: state.isConnected, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(platform.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(state.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if state.isConnected {
                Button(action: {
                    agentIntegrationsManager.disconnect(platform)
                }) {
                    Text(isBusy && agentIntegrationsManager.isDisconnecting ? "Removing" : "Disconnect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .disabled(agentIntegrationsManager.isDisconnecting || agentIntegrationsManager.isConnecting || agentIntegrationsManager.isLoading)
                .pointerCursor()
            } else {
                Button(action: {
                    agentIntegrationsManager.connect(platform)
                }) {
                    Text(isBusy && agentIntegrationsManager.isConnecting ? "Opening" : "Connect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(agentIntegrationsManager.isConnecting || agentIntegrationsManager.isDisconnecting || agentIntegrationsManager.isLoading)
                .pointerCursor()
            }
        }
        .padding(.vertical, 8)
    }

    

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet heySona.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using heySona.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        
                        
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        
                        
                        
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    
                    
                    
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    
                    
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    

    private var showHeySonaCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show heySona")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isHeySonaCursorEnabled },
                set: { companionManager.setHeySonaCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/farzatv") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? DM me")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — I read every message.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit heySona")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

        }
    }

    

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.accentText
        case .readingScreen, .processing, .agentWorking, .responding:
            return DS.Colors.accentText
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .readingScreen:
            return "Reading screen"
        case .processing:
            return "Processing"
        case .agentWorking:
            return "Agent working"
        case .responding:
            return "Responding"
        }
    }

}
