//
//  PersonalContextSettingsSections.swift
//  leanring-buddy
//
//  Settings sections for long-term memory, conversation history, project
//  awareness, and notes.
//  Uses the shared layout helpers from SettingsView.swift.
//

import AppKit
import SwiftUI

// MARK: - Long-Term Memory

struct LongTermMemorySettingsSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var longTermMemoryStore: LongTermMemoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("MEMORY")

            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remember things about me")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Text("heySona saves facts you tell it, like your projects and preferences. Stored only on this Mac.")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { companionManager.isLongTermMemoryEnabled },
                            set: { companionManager.setLongTermMemoryEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(DS.Colors.accent)
                        .pointerCursor()
                    }

                    if longTermMemoryStore.rememberedFacts.isEmpty {
                        Text("Nothing remembered yet. Try saying \"remember that I use Neovim.\"")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            // Newest first, so a fact just saved is easy to check.
                            ForEach(longTermMemoryStore.rememberedFacts.reversed()) { rememberedFact in
                                RememberedFactRow(
                                    rememberedFact: rememberedFact,
                                    onForget: { longTermMemoryStore.forgetFact(withID: rememberedFact.id) }
                                )
                            }
                        }

                        HStack {
                            Text("\(longTermMemoryStore.rememberedFacts.count) of \(LongTermMemoryStore.maximumRememberedFactCount) facts")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textTertiary)
                            Spacer()
                            SettingsCapsuleButton(
                                title: "Forget All",
                                isProminent: false,
                                isEnabled: true,
                                action: confirmAndForgetAllFacts
                            )
                        }
                    }
                }
            }
        }
    }

    private func confirmAndForgetAllFacts() {
        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Forget everything heySona remembers?"
        confirmationAlert.informativeText = "This deletes all \(longTermMemoryStore.rememberedFacts.count) remembered facts. It can't be undone."
        confirmationAlert.alertStyle = .warning
        confirmationAlert.addButton(withTitle: "Forget All")
        confirmationAlert.addButton(withTitle: "Cancel")
        if confirmationAlert.runModal() == .alertFirstButtonReturn {
            longTermMemoryStore.forgetAllFacts()
        }
    }
}

// MARK: - Conversation History

struct ConversationHistorySettingsSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationArchiveStore: ConversationArchiveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("CONVERSATION HISTORY")

            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remember past conversations")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Text("Saves what you say and heySona's replies (never screenshots) on this Mac. Each session gets a short journal entry so heySona knows what you've been learning, and it can search older chats when you mention them.")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { companionManager.isConversationHistoryEnabled },
                            set: { companionManager.setConversationHistoryEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(DS.Colors.accent)
                        .pointerCursor()
                    }

                    if conversationArchiveStore.sessionSummaries.isEmpty {
                        Text(conversationArchiveStore.archivedExchangeCount == 0
                             ? "Nothing saved yet."
                             : "Journal entries appear here 30 minutes after a session ends.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(conversationArchiveStore.sessionSummaries.prefix(5)) { sessionSummary in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ConversationArchiveStore.shortDateDescription(sessionSummary.endDate))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(DS.Colors.textTertiary)
                                    Text(sessionSummary.summaryText)
                                        .font(.system(size: 12))
                                        .foregroundColor(DS.Colors.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    HStack {
                        Text("\(conversationArchiveStore.archivedExchangeCount) exchanges · \(conversationArchiveStore.sessionSummaries.count) sessions")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                        SettingsCapsuleButton(
                            title: "Clear History",
                            isProminent: false,
                            isEnabled: conversationArchiveStore.archivedExchangeCount > 0,
                            action: confirmAndClearHistory
                        )
                    }
                }
            }
        }
    }

    private func confirmAndClearHistory() {
        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Delete all conversation history?"
        confirmationAlert.informativeText = "This deletes \(conversationArchiveStore.archivedExchangeCount) saved exchanges and \(conversationArchiveStore.sessionSummaries.count) journal entries, and starts a fresh conversation. It can't be undone."
        confirmationAlert.alertStyle = .warning
        confirmationAlert.addButton(withTitle: "Delete")
        confirmationAlert.addButton(withTitle: "Cancel")
        if confirmationAlert.runModal() == .alertFirstButtonReturn {
            companionManager.clearConversationHistory()
        }
    }
}

private struct RememberedFactRow: View {
    let rememberedFact: RememberedFact
    let onForget: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(rememberedFact.factText)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button(action: onForget) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isHovered ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(isHovered ? 0.1 : 0.04)))
            }
            .buttonStyle(.plain)
            .onHover { hovering in isHovered = hovering }
            .pointerCursor()
            .help("Forget this")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Project Awareness

struct ProjectAwarenessSettingsSection: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("PROJECT")

            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Know which project I'm in")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Text("Detects the git repo of the file open in your front window (Xcode, editors, Terminal). heySona can list and read its files, never change them.")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { companionManager.isProjectAwarenessEnabled },
                            set: { companionManager.setProjectAwarenessEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(DS.Colors.accent)
                        .pointerCursor()
                    }

                    FolderChoiceRow(
                        label: "Pinned folder",
                        detail: "Used when no project is detected.",
                        chosenFolderPath: companionManager.pinnedProjectFolderPath,
                        emptyFolderText: "None",
                        onChooseFolder: { companionManager.setPinnedProjectFolderPath($0) },
                        onClearFolder: { companionManager.setPinnedProjectFolderPath(nil) }
                    )
                    .opacity(companionManager.isProjectAwarenessEnabled ? 1 : 0.5)
                }
            }
        }
    }
}

// MARK: - Notes

struct NotesSettingsSection: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("NOTES")

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Say \"save that to my notes\" to keep an answer.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)

                        HStack {
                            Text("Save notes to")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { companionManager.defaultNoteDestination },
                                set: { companionManager.setDefaultNoteDestination($0) }
                            )) {
                                ForEach(NoteDestination.allCases) { noteDestination in
                                    Text(noteDestination.displayName).tag(noteDestination)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            .pointerCursor()
                        }
                    }

                    FolderChoiceRow(
                        label: "Obsidian vault",
                        detail: "Notes are added as Markdown files in the vault.",
                        chosenFolderPath: companionManager.obsidianVaultFolderPath,
                        emptyFolderText: "Not set",
                        onChooseFolder: { companionManager.setObsidianVaultFolderPath($0) },
                        onClearFolder: { companionManager.setObsidianVaultFolderPath(nil) }
                    )

                    FolderChoiceRow(
                        label: "Markdown folder",
                        detail: nil,
                        chosenFolderPath: companionManager.markdownNotesFolderPath,
                        emptyFolderText: "Not set",
                        onChooseFolder: { companionManager.setMarkdownNotesFolderPath($0) },
                        onClearFolder: nil
                    )

                    if companionManager.defaultNoteDestination == .appleNotes {
                        Text("The first time, macOS asks to let heySona control Notes.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Folder Choice Row

/// Shows a chosen folder with Choose… and (optionally) Clear buttons.
private struct FolderChoiceRow: View {
    let label: String
    let detail: String?
    let chosenFolderPath: String?
    let emptyFolderText: String
    let onChooseFolder: (String) -> Void
    /// nil when the folder can't be cleared (it always has a default).
    let onClearFolder: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                SettingsCapsuleButton(
                    title: "Choose…",
                    isProminent: false,
                    isEnabled: true,
                    action: showFolderPicker
                )

                if let onClearFolder, chosenFolderPath != nil {
                    SettingsCapsuleButton(
                        title: "Clear",
                        isProminent: false,
                        isEnabled: true,
                        action: onClearFolder
                    )
                }
            }

            Text(chosenFolderPath.map { ActiveProjectContext.abbreviateHomeFolder(in: $0) } ?? emptyFolderText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func showFolderPicker() {
        let folderPicker = NSOpenPanel()
        folderPicker.canChooseDirectories = true
        folderPicker.canChooseFiles = false
        folderPicker.canCreateDirectories = true
        folderPicker.allowsMultipleSelection = false
        folderPicker.prompt = "Choose"
        if let chosenFolderPath {
            folderPicker.directoryURL = URL(fileURLWithPath: chosenFolderPath)
        }
        if folderPicker.runModal() == .OK, let pickedFolderURL = folderPicker.url {
            onChooseFolder(pickedFolderURL.path)
        }
    }
}
