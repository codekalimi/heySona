//
//  SettingsView.swift
//  leanring-buddy
//
//  SwiftUI content of the Settings window: API keys, ElevenLabs voice,
//  Claude model, and whether replies are spoken aloud.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                apiKeysSection
                voiceSection
                visualsSection
                macActionsSection
                LongTermMemorySettingsSection(
                    companionManager: companionManager,
                    longTermMemoryStore: companionManager.longTermMemoryStore
                )
                ProjectAwarenessSettingsSection(companionManager: companionManager)
                NotesSettingsSection(companionManager: companionManager)
                modelSection
            }
            .padding(24)
        }
        .frame(width: 460, height: 620)
        .background(DS.Colors.background)
    }

    // MARK: - API Keys

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("API KEYS")

            Text("Saved in your macOS Keychain and sent only to each service.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            ForEach(StoredAPIKeyKind.allCases, id: \.self) { apiKeyKind in
                APIKeySettingsRow(apiKeyKind: apiKeyKind)
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("VOICE")

            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speak replies aloud")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text("When off, replies appear as text next to the cursor.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { companionManager.isSpokenReplyEnabled },
                        set: { companionManager.setSpokenReplyEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
                    .pointerCursor()
                }
            }

            ElevenLabsVoicePickerCard(companionManager: companionManager)
                .opacity(companionManager.isSpokenReplyEnabled ? 1 : 0.5)
        }
    }

    // MARK: - Visuals

    private var visualsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("VISUALS")

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsToggleRow(
                        title: "Draw on screen",
                        detail: "Circles, highlights, arrows, and underlines show you what heySona is talking about. They fade after the reply.",
                        isOn: Binding(
                            get: { companionManager.isScreenDrawingEnabled },
                            set: { companionManager.setScreenDrawingEnabled($0) }
                        )
                    )

                    settingsToggleRow(
                        title: "Show captions",
                        detail: "Shows the spoken reply as text next to your cursor while heySona talks.",
                        isOn: Binding(
                            get: { companionManager.isLiveCaptionsEnabled },
                            set: { companionManager.setLiveCaptionsEnabled($0) }
                        )
                    )
                    .opacity(companionManager.isSpokenReplyEnabled ? 1 : 0.5)
                }
            }
        }
    }

    private func settingsToggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .pointerCursor()
        }
    }

    // MARK: - Mac Actions

    private var macActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("MAC ACTIONS")

            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Let heySona do things on your Mac")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text("Open apps, links, and files, find files, control media and volume, add reminders and calendar events, and run Shortcuts (you approve each Shortcut).")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { companionManager.isMacActionsEnabled },
                        set: { companionManager.setMacActionsEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
                    .pointerCursor()
                }
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("CLAUDE MODEL")

            settingsCard {
                HStack(spacing: 8) {
                    ForEach(ClaudeModelCatalog.allModelOptions) { modelOption in
                        modelOptionButton(
                            label: modelOption.pickerLabel,
                            detail: modelOption.pickerDetail,
                            modelID: modelOption.modelID
                        )
                    }
                }
            }
        }
    }

    private func modelOptionButton(label: String, detail: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Shared Layout Helpers

func settingsSectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundColor(DS.Colors.textTertiary)
}

func settingsCard<CardContent: View>(@ViewBuilder content: () -> CardContent) -> some View {
    content()
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
}

/// Small capsule button used for Save / Remove / Preview actions.
struct SettingsCapsuleButton: View {
    let title: String
    let isProminent: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isProminent ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isProminent
                                   ? (isHovered ? DS.Colors.accentHover : DS.Colors.accent)
                                   : Color.white.opacity(isHovered ? 0.1 : 0.0))
                )
                .overlay(
                    Capsule().stroke(isProminent ? Color.clear : DS.Colors.borderSubtle, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering in isHovered = hovering && isEnabled }
        .pointerCursor(isEnabled: isEnabled)
    }
}

// MARK: - API Key Row

private struct APIKeySettingsRow: View {
    let apiKeyKind: StoredAPIKeyKind

    @State private var newAPIKeyInput: String = ""
    /// Last four characters of the saved key, or nil when nothing is saved.
    /// Only the suffix is kept in memory so the full key is never displayed.
    @State private var savedAPIKeySuffix: String?
    @State private var didJustSave = false

    var body: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(apiKeyKind.serviceDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    savedStatusLabel
                }

                HStack(spacing: 8) {
                    SecureField(savedAPIKeySuffix == nil ? "Paste API key" : "Paste a new key to replace it", text: $newAPIKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                        .onSubmit(saveNewAPIKey)

                    SettingsCapsuleButton(
                        title: "Save",
                        isProminent: true,
                        isEnabled: !trimmedNewAPIKeyInput.isEmpty,
                        action: saveNewAPIKey
                    )

                    if savedAPIKeySuffix != nil {
                        SettingsCapsuleButton(
                            title: "Remove",
                            isProminent: false,
                            isEnabled: true,
                            action: removeSavedAPIKey
                        )
                    }
                }

                Text(footnoteText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refreshSavedAPIKeySuffix)
    }

    @ViewBuilder
    private var savedStatusLabel: some View {
        if let savedAPIKeySuffix {
            HStack(spacing: 4) {
                Circle()
                    .fill(DS.Colors.success)
                    .frame(width: 6, height: 6)
                Text(didJustSave ? "Saved" : "Saved · ends in \(savedAPIKeySuffix)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            }
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(apiKeyKind.isRequired ? DS.Colors.warning : DS.Colors.textTertiary)
                    .frame(width: 6, height: 6)
                Text(apiKeyKind.isRequired ? "Not set" : "Not set (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(apiKeyKind.isRequired ? DS.Colors.warningText : DS.Colors.textTertiary)
            }
        }
    }

    private var footnoteText: String {
        var footnote = "Get one at \(apiKeyKind.whereToGetKeyURL)."
        // The speech-to-text provider is picked once at launch, so a change
        // to the AssemblyAI key only takes effect the next time the app starts.
        if apiKeyKind == .assemblyAI {
            footnote += " Changes apply after you quit and reopen heySona. Without a key, Apple Speech is used."
        }
        return footnote
    }

    private var trimmedNewAPIKeyInput: String {
        newAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSavedAPIKeySuffix() {
        if let savedAPIKey = APIKeyKeychainStore.readAPIKey(for: apiKeyKind) {
            savedAPIKeySuffix = String(savedAPIKey.suffix(4))
        } else {
            savedAPIKeySuffix = nil
        }
    }

    private func saveNewAPIKey() {
        guard !trimmedNewAPIKeyInput.isEmpty else { return }
        let didSave = APIKeyKeychainStore.saveAPIKey(trimmedNewAPIKeyInput, for: apiKeyKind)
        guard didSave else { return }

        newAPIKeyInput = ""
        refreshSavedAPIKeySuffix()

        // Briefly show "Saved" so the user gets clear confirmation.
        didJustSave = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didJustSave = false
        }
    }

    private func removeSavedAPIKey() {
        APIKeyKeychainStore.deleteAPIKey(for: apiKeyKind)
        refreshSavedAPIKeySuffix()
    }
}

// MARK: - Voice Picker

private struct ElevenLabsVoicePickerCard: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var availableVoices: [ElevenLabsVoice] = []
    @State private var isLoadingVoices = false
    @State private var voiceLoadingErrorMessage: String?
    @State private var isPreviewingVoice = false
    @State private var manualVoiceIdInput: String = ""

    var body: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ElevenLabs voice")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    SettingsCapsuleButton(
                        title: isLoadingVoices ? "Loading…" : "Reload",
                        isProminent: false,
                        isEnabled: !isLoadingVoices,
                        action: { Task { await loadAvailableVoices() } }
                    )
                }

                if !availableVoices.isEmpty {
                    Picker("", selection: Binding(
                        get: { companionManager.selectedElevenLabsVoiceId },
                        set: { companionManager.setSelectedElevenLabsVoiceId($0) }
                    )) {
                        // Keep the current voice selectable even if it isn't in
                        // the account's list (e.g. the built-in default voice).
                        if !availableVoices.contains(where: { $0.voiceId == companionManager.selectedElevenLabsVoiceId }) {
                            Text("Current voice (\(companionManager.selectedElevenLabsVoiceId))")
                                .tag(companionManager.selectedElevenLabsVoiceId)
                        }
                        ForEach(availableVoices) { voice in
                            Text(voice.name).tag(voice.voiceId)
                        }
                    }
                    .labelsHidden()
                    .pointerCursor()
                } else {
                    // Fallback when the voice list can't be loaded: paste an ID.
                    HStack(spacing: 8) {
                        TextField(companionManager.selectedElevenLabsVoiceId, text: $manualVoiceIdInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )

                        SettingsCapsuleButton(
                            title: "Use ID",
                            isProminent: true,
                            isEnabled: !manualVoiceIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            action: {
                                companionManager.setSelectedElevenLabsVoiceId(manualVoiceIdInput)
                                manualVoiceIdInput = ""
                            }
                        )
                    }
                }

                if let voiceLoadingErrorMessage {
                    Text(voiceLoadingErrorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Voice ID: \(companionManager.selectedElevenLabsVoiceId)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .textSelection(.enabled)

                    Spacer()

                    SettingsCapsuleButton(
                        title: isPreviewingVoice ? "Playing…" : "Preview",
                        isProminent: false,
                        isEnabled: !isPreviewingVoice,
                        action: { Task { await previewSelectedVoice() } }
                    )
                }
            }
        }
        .task {
            if availableVoices.isEmpty {
                await loadAvailableVoices()
            }
        }
    }

    private func loadAvailableVoices() async {
        isLoadingVoices = true
        voiceLoadingErrorMessage = nil
        defer { isLoadingVoices = false }

        do {
            availableVoices = try await companionManager.fetchAvailableElevenLabsVoices()
        } catch {
            voiceLoadingErrorMessage = error.localizedDescription
        }
    }

    private func previewSelectedVoice() async {
        isPreviewingVoice = true
        voiceLoadingErrorMessage = nil
        defer { isPreviewingVoice = false }

        do {
            try await companionManager.previewSelectedVoice()
            // speakText returns once playback starts; keep the button in its
            // "Playing…" state for roughly the length of the sample sentence.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        } catch {
            voiceLoadingErrorMessage = error.localizedDescription
        }
    }
}
