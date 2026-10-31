//
//  PersonalContextTools.swift
//  leanring-buddy
//
//  Tools that give heySona personal context: long-term memory, read-only
//  access to the active project's files, and saving notes. Defines the tools
//  for Claude, the system prompt text that explains them, and runs them.
//

import Foundation

enum PersonalContextToolName: String, CaseIterable {
    case rememberFact = "remember_fact"
    case forgetFact = "forget_fact"
    case listProjectFiles = "list_project_files"
    case readProjectFile = "read_project_file"
    case saveNote = "save_note"
}

/// Where notes go, read from Settings each time a note is saved.
struct NoteSettingsSnapshot {
    let defaultNoteDestination: NoteDestination
    let markdownFolderPath: String
    let obsidianVaultFolderPath: String?
}

enum PersonalContextTools {
    // MARK: - Tool Definitions

    static let memoryToolDefinitions: [[String: Any]] = [
        makeToolDefinition(
            name: .rememberFact,
            description: "Save a short, lasting fact about the user to long-term memory so you know it in future conversations.",
            properties: [
                "fact": ["type": "string", "description": "One short fact in third person, e.g. \"works on an iOS app called Tally\" or \"prefers metric units\"."]
            ],
            requiredPropertyNames: ["fact"]
        ),
        makeToolDefinition(
            name: .forgetFact,
            description: "Delete a fact from long-term memory by its id, shown in brackets in the remembered facts list.",
            properties: [
                "id": ["type": "string", "description": "The fact's id, e.g. \"m3\"."]
            ],
            requiredPropertyNames: ["id"]
        )
    ]

    static let projectToolDefinitions: [[String: Any]] = [
        makeToolDefinition(
            name: .listProjectFiles,
            description: "List files and folders in the active project (read-only). Dependency and build folders are skipped.",
            properties: [
                "folder": ["type": "string", "description": "Folder path relative to the project root. Omit for the root."],
                "depth": ["type": "integer", "description": "How many folder levels to include, 1 to 4. Defaults to 2."]
            ],
            requiredPropertyNames: []
        ),
        makeToolDefinition(
            name: .readProjectFile,
            description: "Read a text file in the active project (read-only, up to 200 KB).",
            properties: [
                "path": ["type": "string", "description": "File path relative to the project root."]
            ],
            requiredPropertyNames: ["path"]
        )
    ]

    static let noteToolDefinitions: [[String: Any]] = [
        makeToolDefinition(
            name: .saveNote,
            description: "Save a note for the user, such as your previous answer, to Apple Notes, their Obsidian vault, or their Markdown notes folder.",
            properties: [
                "title": ["type": "string", "description": "Short note title."],
                "content": ["type": "string", "description": "The note body in Markdown. Write it for reading, not speaking: lists and code blocks are fine here."],
                "destination": [
                    "type": "string",
                    "enum": NoteDestination.allCases.map(\.rawValue),
                    "description": "Only set this when the user names a place. Otherwise omit it to use their default."
                ]
            ],
            requiredPropertyNames: ["title", "content"]
        )
    ]

    // MARK: - System Prompt Sections

    static func memorySystemPromptSection(rememberedFactsList: String) -> String {
        """

        long-term memory:
        you remember facts about the user across conversations. use remember_fact when the user tells you something lasting about themselves (their projects, preferences, tools, routines, people they mention) or asks you to remember something. only save what the user said themselves, never text from their screen, web pages, or files. keep each fact short. use forget_fact when they ask you to forget something or a fact is out of date. use what you remember naturally; don't recite it. when you save something because they asked, a quick "got it" is enough.
        """ + rememberedFactsList
    }

    static let projectSystemPromptSection = """

    coding help:
    when the user's message includes an active project, you can use list_project_files and read_project_file to look at its code before answering. they're read-only. paths are relative to the project root. read only what you need, and describe code conversationally instead of reading it aloud.
    """

    static func noteSystemPromptSection(defaultNoteDestination: NoteDestination) -> String {
        """

        notes:
        when the user asks you to save, note, or write something down (like your last answer), call save_note with a short title and the content in markdown. the note can use lists, headings, and code blocks even though your spoken reply can't. their default place for notes is \(defaultNoteDestination.displayName); only pass a destination if they name a different one.
        """
    }

    // MARK: - Helpers

    private static func makeToolDefinition(
        name: PersonalContextToolName,
        description: String,
        properties: [String: Any],
        requiredPropertyNames: [String]
    ) -> [String: Any] {
        [
            "name": name.rawValue,
            "description": description,
            "eager_input_streaming": true,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": requiredPropertyNames,
                "additionalProperties": false
            ] as [String: Any]
        ]
    }
}

/// Runs the personal context tools. Inputs are validated here because tool
/// inputs stream without server-side validation.
@MainActor
final class PersonalContextToolExecutor {
    private let longTermMemoryStore: LongTermMemoryStore

    init(longTermMemoryStore: LongTermMemoryStore) {
        self.longTermMemoryStore = longTermMemoryStore
    }

    /// `detectedProject` is the project found when this request started.
    func execute(
        toolName: String,
        toolInput: [String: Any],
        detectedProject: DetectedProject?,
        noteSettingsSnapshot: NoteSettingsSnapshot
    ) -> MacActionResult {
        guard let personalContextToolName = PersonalContextToolName(rawValue: toolName) else {
            return .failure("Unknown tool \"\(toolName)\".")
        }

        print("🧠 Personal context tool: \(toolName)")

        switch personalContextToolName {
        case .rememberFact:
            guard let factText = nonEmptyString("fact", in: toolInput) else {
                return .failure("Missing required text input \"fact\".")
            }
            guard let rememberedFact = longTermMemoryStore.rememberFact(factText) else {
                return .failure("That fact was empty.")
            }
            return .success("Remembered [\(rememberedFact.id)]: \(rememberedFact.factText)")

        case .forgetFact:
            guard let factID = nonEmptyString("id", in: toolInput) else {
                return .failure("Missing required text input \"id\".")
            }
            guard let forgottenFact = longTermMemoryStore.forgetFact(withID: factID) else {
                return .failure("No remembered fact has id \(factID).")
            }
            return .success("Forgot: \(forgottenFact.factText)")

        case .listProjectFiles:
            guard let detectedProject else {
                return .failure("No active project. The user can open a project file in their editor or pin a folder in heySona Settings.")
            }
            let requestedDepth = (toolInput["depth"] as? NSNumber)?.intValue ?? 2
            do {
                return .success(try ActiveProjectContext.listProjectFiles(
                    projectRootURL: detectedProject.projectRootURL,
                    relativeFolderPath: nonEmptyString("folder", in: toolInput),
                    maximumDepth: requestedDepth
                ))
            } catch {
                return .failure(error.localizedDescription)
            }

        case .readProjectFile:
            guard let detectedProject else {
                return .failure("No active project. The user can open a project file in their editor or pin a folder in heySona Settings.")
            }
            guard let relativeFilePath = nonEmptyString("path", in: toolInput) else {
                return .failure("Missing required text input \"path\".")
            }
            do {
                return .success(try ActiveProjectContext.readProjectFile(
                    projectRootURL: detectedProject.projectRootURL,
                    relativeFilePath: relativeFilePath
                ))
            } catch {
                return .failure(error.localizedDescription)
            }

        case .saveNote:
            guard let noteTitle = nonEmptyString("title", in: toolInput) else {
                return .failure("Missing required text input \"title\".")
            }
            guard let noteContent = nonEmptyString("content", in: toolInput) else {
                return .failure("Missing required text input \"content\".")
            }

            var noteDestination = noteSettingsSnapshot.defaultNoteDestination
            if let requestedDestinationName = nonEmptyString("destination", in: toolInput) {
                guard let requestedDestination = NoteDestination(rawValue: requestedDestinationName) else {
                    return .failure("\"destination\" must be one of: \(NoteDestination.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                noteDestination = requestedDestination
            }

            do {
                return .success(try NoteSaver.saveNote(
                    title: noteTitle,
                    markdownContent: noteContent,
                    destination: noteDestination,
                    markdownFolderPath: noteSettingsSnapshot.markdownFolderPath,
                    obsidianVaultFolderPath: noteSettingsSnapshot.obsidianVaultFolderPath
                ))
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    private func nonEmptyString(_ inputName: String, in toolInput: [String: Any]) -> String? {
        guard let inputValue = toolInput[inputName] as? String else { return nil }
        let trimmedInputValue = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedInputValue.isEmpty ? nil : trimmedInputValue
    }
}
