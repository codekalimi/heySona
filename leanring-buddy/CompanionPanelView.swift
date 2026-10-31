import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var panelConversation: CompanionPanelConversation
    let onSubmitQuestion: (String) -> Void

    @State private var draftQuestion = ""
    @State private var copiedExchangeID: UUID?
    @FocusState private var isQuestionFieldFocused: Bool

    init(companionManager: CompanionManager, onSubmitQuestion: @escaping (String) -> Void) {
        self.companionManager = companionManager
        self.panelConversation = companionManager.panelConversation
        self.onSubmitQuestion = onSubmitQuestion
    }

    private var isReady: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    private var isExpanded: Bool { isReady && panelConversation.isExpanded }

    private var canStopReply: Bool {
        companionManager.voiceState != .listening && (
            panelConversation.latestExchange?.isReceivingReply == true
                || companionManager.voiceState == .processing
                || companionManager.voiceState == .responding
                || companionManager.isWaitingForGuidedModeClick
        )
    }

    var body: some View {
        let panelSize = panelConversation.panelSize(isReady: isReady)
        VStack(spacing: 0) {
            header
            if !isReady {
                setupContent
            } else if isExpanded {
                conversationContent
                questionComposer
            } else {
                quietContent
            }
            footer
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .foregroundStyle(DS.CompanionPanel.text)
        .background(DS.CompanionPanel.background)
        .clipShape(RoundedRectangle(cornerRadius: DS.CompanionPanel.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.CompanionPanel.cornerRadius, style: .continuous)
                .strokeBorder(DS.CompanionPanel.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .tint(DS.CompanionPanel.accent)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { isQuestionFieldFocused = false }
        }
        .onChange(of: panelConversation.latestExchange?.answer) { _, _ in
            copiedExchangeID = nil
        }
        .onExitCommand {
            if canStopReply {
                companionManager.stopCurrentResponse()
            } else {
                NotificationCenter.default.post(name: .heySonaDismissPanel, object: nil)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.CompanionPanel.accent)
                .frame(width: 32, height: 32)
                .background(DS.CompanionPanel.accentSurface, in: RoundedRectangle(cornerRadius: 10))
            Text("heySona").font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 4)
            if isExpanded || !canStopReply {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.CompanionPanel.secondaryText)
                    .lineLimit(1)
            }

            if canStopReply {
                CompanionPanelIconButton("Stop reply", systemImage: "stop.fill") {
                    companionManager.stopCurrentResponse()
                }
            }
            if isExpanded {
                CompanionPanelIconButton("Collapse conversation", systemImage: "chevron.up") {
                    panelConversation.isExpanded = false
                }
            }
            CompanionPanelIconButton("Settings", systemImage: "slider.horizontal.3") {
                NotificationCenter.default.post(name: .heySonaOpenSettings, object: nil)
            }
            Menu {
                if companionManager.hasCompletedOnboarding {
                    Button("Watch onboarding again") { companionManager.replayOnboarding() }
                    Divider()
                }
                Button("Quit heySona") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .help("More options")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var quietContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            Group {
                if companionManager.voiceState == .processing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: companionManager.voiceState == .listening ? "mic.fill" : "waveform")
                        .font(.system(size: 25, weight: .medium))
                }
            }
            .foregroundStyle(DS.CompanionPanel.accent)
            .frame(width: 58, height: 58)
            .background(DS.CompanionPanel.accentSurface, in: RoundedRectangle(cornerRadius: 20))

            Text(companionManager.voiceState == .listening ? "I'm listening." : "A little help, right here.")
                .font(.system(size: 23, weight: .semibold))
                .tracking(-0.5)
                .padding(.top, 16)
            Text("Ask about your screen. Learn something new.")
                .font(.system(size: 13))
                .foregroundStyle(DS.CompanionPanel.secondaryText)
                .padding(.top, 7)
            HStack(spacing: 6) {
                shortcutKey("⌃ Control")
                shortcutKey("⌥ Option")
            }
            .padding(.top, 16)
            Text("Hold to talk · release to send")
                .font(.system(size: 12))
                .foregroundStyle(DS.CompanionPanel.secondaryText)
                .padding(.top, 8)
            Spacer(minLength: 16)

            Button(action: expandForTyping) {
                Label("Type a question", systemImage: "keyboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(CompanionPanelActionStyle(isPrimary: true))
            .pointerCursor()
            .disabled(companionManager.showOnboardingVideo)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private var conversationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let exchange = panelConversation.latestExchange {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR QUESTION")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(1)
                            .foregroundStyle(DS.CompanionPanel.secondaryText)
                        Text(exchange.question)
                            .font(.system(size: 16, weight: .medium))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(DS.CompanionPanel.surface, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        if !exchange.answer.isEmpty {
                            Text(exchange.answer)
                                .font(.system(size: 15))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if exchange.isReceivingReply {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(exchange.answer.isEmpty ? "Thinking about your question…" : "Writing…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.CompanionPanel.secondaryText)
                            }
                            .accessibilityElement(children: .combine)
                        } else if let errorMessage = exchange.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.CompanionPanel.secondaryText)
                        } else if exchange.status == .interrupted {
                            Text(exchange.answer.isEmpty ? "Reply stopped. Ask again whenever you're ready." : "Reply stopped")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.CompanionPanel.secondaryText)
                        }
                        if !exchange.answer.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(exchange.answer, forType: .string)
                                copiedExchangeID = exchange.id
                            } label: {
                                Label(copiedExchangeID == exchange.id ? "Copied" : "Copy reply", systemImage: copiedExchangeID == exchange.id ? "checkmark" : "doc.on.doc")
                            }
                            .font(.system(size: 12))
                            .buttonStyle(CompanionPanelActionStyle())
                            .pointerCursor()
                        }
                    }
                    .padding(.horizontal, 4)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What's on your mind?").font(.system(size: 23, weight: .semibold))
                        Text("Ask about your screen, explore an idea, or pick up where you left off.")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.CompanionPanel.secondaryText)
                            .lineSpacing(4)
                    }
                    .padding(.vertical, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
    }

    private var questionComposer: some View {
        HStack(spacing: 10) {
            TextField(panelConversation.latestExchange == nil ? "Ask heySona…" : "Ask a follow-up…", text: $draftQuestion)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isQuestionFieldFocused)
                .onSubmit(submitDraftQuestion)
                .accessibilityLabel("Question for heySona")
            Button(action: submitDraftQuestion) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(DS.CompanionPanel.accentSurface, in: RoundedRectangle(cornerRadius: 9))
            }
            .foregroundStyle(DS.CompanionPanel.accent)
            .buttonStyle(.plain)
            .modifier(CompanionPanelButtonHover())
            .pointerCursor()
            .help("Send question")
            .accessibilityLabel("Send question")
            .disabled(draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || companionManager.buddyDictationManager.isDictationInProgress)
        }
        .padding(10)
        .background(DS.CompanionPanel.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isQuestionFieldFocused ? DS.CompanionPanel.accent.opacity(0.65) : DS.CompanionPanel.border, lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isReady {
                Button {
                    NotificationCenter.default.post(name: .heySonaDismissPanel, object: nil)
                    companionManager.showVisualExplanationLibrary()
                } label: {
                    Label("Library", systemImage: "book")
                }
                .buttonStyle(CompanionPanelActionStyle())
                .pointerCursor()
                if !isExpanded && panelConversation.latestExchange != nil {
                    Button("Last reply") { panelConversation.isExpanded = true }
                        .buttonStyle(CompanionPanelActionStyle())
                        .pointerCursor()
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(ClaudeModelCatalog.allModelOptions) { modelOption in
                        Button { companionManager.setSelectedModel(modelOption.modelID) } label: {
                            if companionManager.selectedModel == modelOption.modelID {
                                Label(modelOption.pickerLabel, systemImage: "checkmark")
                            } else {
                                Text(modelOption.pickerLabel)
                            }
                        }
                    }
                } label: {
                    Text(ClaudeModelCatalog.modelOption(forModelID: companionManager.selectedModel)?.pickerLabel ?? "Model")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
                .help("Choose Claude model")
            } else {
                Text("Your companion, one shortcut away.").font(.system(size: 12))
                Spacer()
            }
        }
        .foregroundStyle(DS.CompanionPanel.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(DS.CompanionPanel.border).frame(height: 1) }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(companionManager.hasCompletedOnboarding ? "Let's reconnect." : "Hi, I'm Sona.")
                    .font(.system(size: 25, weight: .semibold))
                Text("I can help with your screen, explain ideas, and point you in the right direction.")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.CompanionPanel.secondaryText)
                    .lineSpacing(4)
                if !companionManager.allPermissionsGranted {
                    Text("Allow access below to get started. Screenshots are taken when you ask, including during guided follow-ups.")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.CompanionPanel.secondaryText)
                    permissionsSection
                } else {
                    Text("You're all set. Meet your companion.").font(.system(size: 14))
                    Button("Meet heySona") { companionManager.triggerOnboarding() }
                        .buttonStyle(CompanionPanelActionStyle(isPrimary: true))
                        .pointerCursor()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .frame(maxHeight: .infinity)
    }

    private var permissionsSection: some View {
        VStack(spacing: 16) {
            permissionRow("Microphone", systemImage: "mic", isGranted: companionManager.hasMicrophonePermission) {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            permissionRow("Accessibility", systemImage: "hand.raised", isGranted: companionManager.hasAccessibilityPermission) {
                WindowPositionManager.requestAccessibilityPermission()
            }
            if !companionManager.hasAccessibilityPermission {
                Button("Find app in Finder") {
                    WindowPositionManager.revealAppInFinder()
                    WindowPositionManager.openAccessibilitySettings()
                }
                .font(.system(size: 12))
                .buttonStyle(CompanionPanelActionStyle())
                .pointerCursor()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            permissionRow("Screen Recording", systemImage: "rectangle.dashed", isGranted: companionManager.hasScreenRecordingPermission) {
                WindowPositionManager.requestScreenRecordingPermission()
            }
            if !companionManager.hasScreenRecordingPermission {
                Text("After granting Screen Recording, quit and reopen heySona.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.CompanionPanel.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if companionManager.hasScreenRecordingPermission {
                permissionRow("Screen Content", systemImage: "eye", isGranted: companionManager.hasScreenContentPermission) {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
    }

    private func permissionRow(_ title: String, systemImage: String, isGranted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: systemImage).font(.system(size: 14, weight: .medium))
            Spacer()
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.CompanionPanel.accent)
                    .accessibilityLabel("Granted")
            } else {
                Button("Allow", action: action)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(CompanionPanelActionStyle())
                    .pointerCursor()
            }
        }
    }

    private func shortcutKey(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DS.CompanionPanel.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DS.CompanionPanel.border, lineWidth: 1) }
    }

    private func expandForTyping() {
        panelConversation.isExpanded = true
        isQuestionFieldFocused = true
    }

    private func submitDraftQuestion() {
        let trimmedQuestion = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !companionManager.buddyDictationManager.isDictationInProgress else { return }
        draftQuestion = ""
        isQuestionFieldFocused = false
        onSubmitQuestion(trimmedQuestion)
    }

    private var statusText: String {
        guard isReady else { return "Setup" }
        if companionManager.isWaitingForGuidedModeClick { return "Your turn" }
        switch companionManager.voiceState {
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        case .idle: return panelConversation.latestExchange?.isReceivingReply == true ? "Thinking" : "Ready"
        }
    }
}

private struct CompanionPanelIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(isHovered ? DS.CompanionPanel.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .foregroundStyle(DS.CompanionPanel.secondaryText)
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct CompanionPanelActionStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, isPrimary ? 12 : 7)
            .foregroundStyle(isPrimary ? DS.CompanionPanel.background : DS.CompanionPanel.secondaryText)
            .background {
                RoundedRectangle(cornerRadius: isPrimary ? 12 : 8)
                    .fill(isPrimary ? DS.CompanionPanel.text : DS.CompanionPanel.hover)
            }
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .modifier(CompanionPanelButtonHover())
    }
}

private struct CompanionPanelButtonHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content.brightness(isHovered ? 0.04 : 0).onHover { isHovered = $0 }
    }
}
