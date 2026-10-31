//
//  SkillsSettingsSection.swift
//  leanring-buddy
//
//  Settings section for skills (SkillLibrary.swift): built-in and the
//  user's own skills with on/off switches, saved procedures with Show and
//  Delete, the skills folder, and which skills the last reply used.
//

import AppKit
import SwiftUI

struct SkillsSettingsSection: View {
    @ObservedObject var skillLibrary: SkillLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionTitle("SKILLS")

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Short guides heySona adds only when they fit your question or the app in front. Add your own as .md files in the skills folder.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    skillGroup(title: "Topics", kind: .topic)
                    skillGroup(title: "Apps", kind: .app)
                    proceduresGroup

                    if !skillLibrary.lastUsedSkillNames.isEmpty {
                        Text("Used in the last reply: \(skillLibrary.lastUsedSkillNames.joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer()
                        SettingsCapsuleButton(
                            title: "Open Skills Folder",
                            isProminent: false,
                            isEnabled: true,
                            action: { skillLibrary.openUserSkillsFolder() }
                        )
                        SettingsCapsuleButton(
                            title: "Reload",
                            isProminent: false,
                            isEnabled: true,
                            action: { skillLibrary.reload() }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func skillGroup(title: String, kind: SkillKind) -> some View {
        let skillsOfKind = skillLibrary.skills.filter { $0.kind == kind }
        if !skillsOfKind.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                ForEach(skillsOfKind) { skill in
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                        if !skill.isBundled {
                            Text("yours")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Colors.accentText)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { skillLibrary.isSkillEnabled(skill) },
                            set: { skillLibrary.setSkillEnabled(skill, isEnabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(DS.Colors.accent)
                        .pointerCursor()
                    }
                    .help(skill.description)
                }
            }
        }
    }

    private var proceduresGroup: some View {
        let savedProcedures = skillLibrary.skills.filter { $0.kind == .procedure }
        return VStack(alignment: .leading, spacing: 6) {
            Text("YOUR PROCEDURES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            if savedProcedures.isEmpty {
                Text("None yet. After heySona guides you through a task, say yes when it offers to save the steps.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(savedProcedures) { savedProcedure in
                    HStack(spacing: 8) {
                        Text(savedProcedure.name)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        SettingsCapsuleButton(
                            title: "Show",
                            isProminent: false,
                            isEnabled: true,
                            action: { NSWorkspace.shared.open(savedProcedure.fileURL) }
                        )
                        SettingsCapsuleButton(
                            title: "Delete",
                            isProminent: false,
                            isEnabled: true,
                            action: { skillLibrary.deleteProcedure(savedProcedure) }
                        )
                    }
                }
            }
        }
    }
}
