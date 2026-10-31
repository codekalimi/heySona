//
//  NoteSaver.swift
//  leanring-buddy
//
//  Saves a note (usually one of heySona's answers) to Apple Notes, an
//  Obsidian vault, or a plain Markdown folder. Obsidian notes are Markdown
//  files written into the vault folder, which Obsidian picks up on its own.
//

import AppKit
import Foundation

enum NoteDestination: String, CaseIterable, Identifiable {
    case appleNotes = "apple_notes"
    case obsidian = "obsidian"
    case markdownFolder = "markdown"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleNotes: return "Apple Notes"
        case .obsidian: return "Obsidian vault"
        case .markdownFolder: return "Markdown folder"
        }
    }
}

struct NoteSaveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum NoteSaver {
    /// Used when no Markdown folder has been chosen in Settings.
    static var defaultMarkdownFolderPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/heySona Notes", isDirectory: true)
            .path
    }

    /// Saves the note and returns a short confirmation for Claude to relay.
    static func saveNote(
        title: String,
        markdownContent: String,
        destination: NoteDestination,
        markdownFolderPath: String,
        obsidianVaultFolderPath: String?
    ) throws -> String {
        switch destination {
        case .appleNotes:
            try saveToAppleNotes(title: title, markdownContent: markdownContent)
            return "Saved \"\(title)\" to Apple Notes."

        case .obsidian:
            guard let obsidianVaultFolderPath, !obsidianVaultFolderPath.isEmpty else {
                throw NoteSaveError(message: "No Obsidian vault folder is set. The user can choose one in heySona Settings > Notes.")
            }
            let savedFileURL = try saveMarkdownFile(title: title, markdownContent: markdownContent, folderPath: obsidianVaultFolderPath)
            return "Saved \"\(savedFileURL.lastPathComponent)\" to the Obsidian vault."

        case .markdownFolder:
            let savedFileURL = try saveMarkdownFile(title: title, markdownContent: markdownContent, folderPath: markdownFolderPath)
            return "Saved \(ActiveProjectContext.abbreviateHomeFolder(in: savedFileURL.path))."
        }
    }

    // MARK: - Markdown Files

    private static func saveMarkdownFile(title: String, markdownContent: String, folderPath: String) throws -> URL {
        let folderURL = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // Never overwrite an existing note: add " 2", " 3", ... to the name.
        let baseFileName = safeFileName(from: title)
        var noteFileURL = folderURL.appendingPathComponent(baseFileName + ".md")
        var duplicateNumber = 2
        while FileManager.default.fileExists(atPath: noteFileURL.path) {
            noteFileURL = folderURL.appendingPathComponent("\(baseFileName) \(duplicateNumber).md")
            duplicateNumber += 1
        }

        let noteFileText = "# \(title)\n\n\(markdownContent)\n"
        try noteFileText.write(to: noteFileURL, atomically: true, encoding: .utf8)
        return noteFileURL
    }

    /// Removes characters that aren't allowed or are awkward in file names.
    private static func safeFileName(from title: String) -> String {
        let disallowedCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleanedTitle = title
            .components(separatedBy: disallowedCharacters)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let shortenedTitle = String(cleanedTitle.prefix(80))
        return shortenedTitle.isEmpty ? "heySona note" : shortenedTitle
    }

    // MARK: - Apple Notes

    /// Creates the note through AppleScript. The first time, macOS asks the
    /// user to allow heySona to control Notes (Automation permission).
    private static func saveToAppleNotes(title: String, markdownContent: String) throws {
        // Notes stores bodies as HTML; its first line becomes the note title.
        let noteBodyHTML = "<h1>\(escapeHTML(title))</h1>" + markdownContent
            .components(separatedBy: "\n")
            .map { noteLine in "<div>\(noteLine.isEmpty ? "<br>" : escapeHTML(noteLine))</div>" }
            .joined()

        let appleScriptSource = """
        tell application "Notes"
            make new note with properties {body:"\(escapeForAppleScriptString(noteBodyHTML))"}
        end tell
        """

        guard let notesAppleScript = NSAppleScript(source: appleScriptSource) else {
            throw NoteSaveError(message: "Couldn't prepare the Apple Notes script.")
        }

        var appleScriptErrorInfo: NSDictionary?
        notesAppleScript.executeAndReturnError(&appleScriptErrorInfo)

        if let appleScriptErrorInfo {
            let appleScriptErrorNumber = appleScriptErrorInfo[NSAppleScript.errorNumber] as? Int
            // -1743: the user hasn't allowed heySona to control Notes.
            if appleScriptErrorNumber == -1743 {
                throw NoteSaveError(message: "heySona isn't allowed to control Notes. The user can allow it in System Settings > Privacy & Security > Automation.")
            }
            let appleScriptErrorMessage = appleScriptErrorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            throw NoteSaveError(message: "Apple Notes said: \(appleScriptErrorMessage)")
        }
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes backslashes and quotes so text can sit inside an AppleScript
    /// string literal without ending it early.
    private static func escapeForAppleScriptString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
