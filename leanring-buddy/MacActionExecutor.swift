//
//  MacActionExecutor.swift
//  leanring-buddy
//
//  Runs the Mac action tools that Claude calls (see MacActionTools.swift).
//  Every input is validated here before anything happens, because tool inputs
//  stream without server-side validation. Running a Shortcut always asks the
//  user first, since a Shortcut can do almost anything.
//

import AppKit
import EventKit
import Foundation

/// What gets sent back to Claude as the `tool_result` for one tool call.
struct MacActionResult {
    let resultText: String
    let isError: Bool

    static func success(_ resultText: String) -> MacActionResult {
        MacActionResult(resultText: resultText, isError: false)
    }

    static func failure(_ resultText: String) -> MacActionResult {
        MacActionResult(resultText: resultText, isError: true)
    }
}

/// Thrown for a missing or wrongly typed tool input. The message goes back to
/// Claude so it can correct the call.
private struct MacActionInputError: Error {
    let message: String
}

@MainActor
final class MacActionExecutor {
    private let eventStore = EKEventStore()

    /// File types that run code when opened. `open_file` only reveals these.
    private static let fileExtensionsThatRunCodeWhenOpened: Set<String> = [
        "app", "command", "sh", "zsh", "bash", "tool", "pkg", "mpkg",
        "terminal", "workflow", "scpt", "scptd", "applescript", "action", "jar", "dmg"
    ]

    func execute(toolName: String, toolInput: [String: Any]) async -> MacActionResult {
        guard let macActionToolName = MacActionToolName(rawValue: toolName) else {
            return .failure("Unknown tool \"\(toolName)\".")
        }

        print("🛠️ Mac action: \(toolName) \(toolInput)")

        do {
            switch macActionToolName {
            case .openApp:
                return try await openApp(appName: requiredString("app_name", in: toolInput))
            case .openURL:
                return try openURL(urlString: requiredString("url", in: toolInput))
            case .findFiles:
                return try await findFiles(
                    query: requiredString("query", in: toolInput),
                    maximumResultCount: optionalInteger("max_results", in: toolInput) ?? 10
                )
            case .openFile:
                return try openFile(
                    path: requiredString("path", in: toolInput),
                    mode: requiredString("mode", in: toolInput, allowedValues: ["open", "reveal"])
                )
            case .mediaControl:
                return try mediaControl(
                    action: requiredString("action", in: toolInput, allowedValues: ["play_pause", "next_track", "previous_track"])
                )
            case .setVolume:
                return try setVolume(
                    action: requiredString("action", in: toolInput, allowedValues: ["set", "up", "down", "mute", "unmute"]),
                    level: optionalInteger("level", in: toolInput)
                )
            case .createReminder:
                return try await createReminder(
                    title: requiredString("title", in: toolInput),
                    dueDateText: optionalString("due", in: toolInput)
                )
            case .createCalendarEvent:
                return try await createCalendarEvent(
                    title: requiredString("title", in: toolInput),
                    startDateText: requiredString("start", in: toolInput),
                    endDateText: optionalString("end", in: toolInput),
                    notes: optionalString("notes", in: toolInput)
                )
            case .listShortcuts:
                return await listShortcuts()
            case .runShortcut:
                return try await runShortcut(shortcutName: requiredString("name", in: toolInput))
            }
        } catch let inputError as MacActionInputError {
            return .failure(inputError.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Apps And Links

    private func openApp(appName: String) async throws -> MacActionResult {
        guard let appURL = findApplicationURL(matchingName: appName) else {
            return .failure("No app named \"\(appName)\" was found in the Applications folders.")
        }

        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        try await NSWorkspace.shared.openApplication(at: appURL, configuration: openConfiguration)

        let openedAppName = appURL.deletingPathExtension().lastPathComponent
        return .success("Opened \(openedAppName).")
    }

    /// Looks through the standard app folders for "<name>.app", preferring an
    /// exact (case-insensitive) match, then a name that starts with the query,
    /// then one that contains it.
    private func findApplicationURL(matchingName appName: String) -> URL? {
        let normalizedQuery = appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored, .backwards])
            .lowercased()
        guard !normalizedQuery.isEmpty else { return nil }

        let applicationFolderURLs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        var installedAppURLs: [URL] = []
        for applicationFolderURL in applicationFolderURLs {
            let folderContents = (try? FileManager.default.contentsOfDirectory(
                at: applicationFolderURL,
                includingPropertiesForKeys: nil
            )) ?? []
            installedAppURLs += folderContents.filter { $0.pathExtension == "app" }
        }

        func appNameLowercased(_ appURL: URL) -> String {
            appURL.deletingPathExtension().lastPathComponent.lowercased()
        }

        return installedAppURLs.first { appNameLowercased($0) == normalizedQuery }
            ?? installedAppURLs.first { appNameLowercased($0).hasPrefix(normalizedQuery) }
            ?? installedAppURLs.first { appNameLowercased($0).contains(normalizedQuery) }
    }

    private func openURL(urlString: String) throws -> MacActionResult {
        guard let webURL = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let urlScheme = webURL.scheme?.lowercased(),
              urlScheme == "http" || urlScheme == "https",
              webURL.host != nil else {
            return .failure("Only full http or https links can be opened.")
        }

        NSWorkspace.shared.open(webURL)
        return .success("Opened \(webURL.absoluteString) in the default browser.")
    }

    // MARK: - Files

    private func findFiles(query: String, maximumResultCount: Int) async throws -> MacActionResult {
        let clampedResultCount = max(1, min(25, maximumResultCount))
        let homeFolderPath = FileManager.default.homeDirectoryForCurrentUser.path

        let spotlightSearchOutput = try await runCommandLineTool(
            executablePath: "/usr/bin/mdfind",
            arguments: ["-onlyin", homeFolderPath, "-name", query],
            timeoutInSeconds: 10
        )

        let matchingPaths = spotlightSearchOutput.standardOutput
            .split(separator: "\n")
            .map(String.init)
            // Skip app caches and library internals the user almost never means.
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
            .prefix(clampedResultCount)

        guard !matchingPaths.isEmpty else {
            return .success("No files or folders with \"\(query)\" in the name were found.")
        }

        let displayPaths = matchingPaths.map { matchingPath in
            matchingPath.replacingOccurrences(of: homeFolderPath, with: "~", options: .anchored)
        }
        return .success(displayPaths.joined(separator: "\n"))
    }

    private func openFile(path: String, mode: String) throws -> MacActionResult {
        let expandedPath = (path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return .failure("Nothing exists at \(path).")
        }

        if mode == "reveal" {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return .success("Revealed \(fileURL.lastPathComponent) in Finder.")
        }

        // Opening an app, script, or installer would run code chosen by the
        // model, which could have been steered by text on screen. Reveal only.
        let runsCodeWhenOpened = Self.fileExtensionsThatRunCodeWhenOpened.contains(fileURL.pathExtension.lowercased())
            || (!isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: expandedPath))
        if runsCodeWhenOpened {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return .failure("\(fileURL.lastPathComponent) runs code when opened, so it was revealed in Finder instead. The user can open it themselves.")
        }

        NSWorkspace.shared.open(fileURL)
        return .success("Opened \(fileURL.lastPathComponent).")
    }

    // MARK: - Media And Volume

    private func mediaControl(action: String) throws -> MacActionResult {
        // Key codes from IOKit's ev_keymap.h (NX_KEYTYPE_PLAY / NEXT / PREVIOUS).
        let mediaKeyCode: Int
        let actionDescription: String
        switch action {
        case "next_track":
            mediaKeyCode = 17
            actionDescription = "Skipped to the next track."
        case "previous_track":
            mediaKeyCode = 18
            actionDescription = "Went back to the previous track."
        default:
            mediaKeyCode = 16
            actionDescription = "Toggled play/pause."
        }

        postMediaKeyPress(mediaKeyCode: mediaKeyCode)
        return .success(actionDescription)
    }

    /// Sends a media key press the same way the keyboard's media keys do, so
    /// it controls whichever app currently owns "Now Playing". Posting events
    /// uses the Accessibility permission the app already has.
    private func postMediaKeyPress(mediaKeyCode: Int) {
        for isKeyDown in [true, false] {
            // 0xA = key down, 0xB = key up, in both the flags and data1 fields.
            let keyStateCode = isKeyDown ? 0xA : 0xB
            let mediaKeyEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyStateCode << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                // Subtype 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS (media/aux keys).
                subtype: 8,
                data1: (mediaKeyCode << 16) | (keyStateCode << 8),
                data2: -1
            )
            mediaKeyEvent?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func setVolume(action: String, level: Int?) throws -> MacActionResult {
        switch action {
        case "mute":
            try MacSystemVolumeController.setMuted(true)
            return .success("Muted the volume.")
        case "unmute":
            try MacSystemVolumeController.setMuted(false)
        case "up":
            try MacSystemVolumeController.setVolumePercent(MacSystemVolumeController.currentVolumePercent() + 10)
        case "down":
            try MacSystemVolumeController.setVolumePercent(MacSystemVolumeController.currentVolumePercent() - 10)
        default:
            guard let level else {
                throw MacActionInputError(message: "\"level\" (0 to 100) is required when action is \"set\".")
            }
            try MacSystemVolumeController.setVolumePercent(level)
        }

        let resultingVolumePercent = try MacSystemVolumeController.currentVolumePercent()
        return .success("Volume is now \(resultingVolumePercent)%.")
    }

    // MARK: - Reminders And Calendar

    private func createReminder(title: String, dueDateText: String?) async throws -> MacActionResult {
        let hasRemindersAccess = try await eventStore.requestFullAccessToReminders()
        guard hasRemindersAccess else {
            return .failure("heySona doesn't have access to Reminders. The user can allow it in System Settings > Privacy & Security > Reminders.")
        }
        guard let defaultRemindersList = eventStore.defaultCalendarForNewReminders() else {
            return .failure("There's no default Reminders list to add to.")
        }

        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.title = title
        newReminder.calendar = defaultRemindersList

        var confirmationText = "Added reminder \"\(title)\""
        if let dueDateText {
            guard let parsedDueDate = parseLocalDateText(dueDateText) else {
                throw MacActionInputError(message: "Couldn't read the due date \"\(dueDateText)\". Use yyyy-MM-ddTHH:mm or yyyy-MM-dd.")
            }

            var dueDateComponentsToKeep: Set<Calendar.Component> = [.year, .month, .day]
            if parsedDueDate.includesTimeOfDay {
                dueDateComponentsToKeep.formUnion([.hour, .minute])
                // An alarm makes Reminders actually notify at that time.
                newReminder.addAlarm(EKAlarm(absoluteDate: parsedDueDate.date))
            }
            newReminder.dueDateComponents = Calendar.current.dateComponents(dueDateComponentsToKeep, from: parsedDueDate.date)
            confirmationText += ", due \(formatForConfirmation(parsedDueDate))"
        }

        try eventStore.save(newReminder, commit: true)
        return .success(confirmationText + ".")
    }

    private func createCalendarEvent(
        title: String,
        startDateText: String,
        endDateText: String?,
        notes: String?
    ) async throws -> MacActionResult {
        // Write-only access is enough to add events and never exposes the
        // user's existing calendar contents to the app.
        let hasCalendarAccess = try await eventStore.requestWriteOnlyAccessToEvents()
        guard hasCalendarAccess else {
            return .failure("heySona doesn't have access to Calendar. The user can allow it in System Settings > Privacy & Security > Calendars.")
        }

        guard let parsedStartDate = parseLocalDateText(startDateText) else {
            throw MacActionInputError(message: "Couldn't read the start \"\(startDateText)\". Use yyyy-MM-ddTHH:mm or yyyy-MM-dd.")
        }

        let newEvent = EKEvent(eventStore: eventStore)
        newEvent.title = title
        newEvent.notes = notes
        newEvent.calendar = eventStore.defaultCalendarForNewEvents
        newEvent.startDate = parsedStartDate.date

        if !parsedStartDate.includesTimeOfDay {
            newEvent.isAllDay = true
            newEvent.endDate = parsedStartDate.date
        } else if let endDateText {
            guard let parsedEndDate = parseLocalDateText(endDateText), parsedEndDate.date > parsedStartDate.date else {
                throw MacActionInputError(message: "The end \"\(endDateText)\" must be a valid time after the start.")
            }
            newEvent.endDate = parsedEndDate.date
        } else {
            newEvent.endDate = parsedStartDate.date.addingTimeInterval(60 * 60)
        }

        try eventStore.save(newEvent, span: .thisEvent, commit: true)
        return .success("Added \"\(title)\" to the calendar on \(formatForConfirmation(parsedStartDate)).")
    }

    private struct ParsedLocalDate {
        let date: Date
        let includesTimeOfDay: Bool
    }

    /// Accepts "yyyy-MM-ddTHH:mm" (seconds and a time zone are tolerated) as
    /// a time, or "yyyy-MM-dd" as a whole day, both in the user's time zone.
    private func parseLocalDateText(_ dateText: String) -> ParsedLocalDate? {
        let trimmedDateText = dateText.trimmingCharacters(in: .whitespacesAndNewlines)

        let isoFormatterWithTimeZone = ISO8601DateFormatter()
        if let dateWithTimeZone = isoFormatterWithTimeZone.date(from: trimmedDateText) {
            return ParsedLocalDate(date: dateWithTimeZone, includesTimeOfDay: true)
        }

        let localDateFormatter = DateFormatter()
        localDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        localDateFormatter.timeZone = .current

        for timeOfDayFormat in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            localDateFormatter.dateFormat = timeOfDayFormat
            if let parsedDate = localDateFormatter.date(from: trimmedDateText) {
                return ParsedLocalDate(date: parsedDate, includesTimeOfDay: true)
            }
        }

        localDateFormatter.dateFormat = "yyyy-MM-dd"
        if let parsedDay = localDateFormatter.date(from: trimmedDateText) {
            return ParsedLocalDate(date: parsedDay, includesTimeOfDay: false)
        }
        return nil
    }

    private func formatForConfirmation(_ parsedLocalDate: ParsedLocalDate) -> String {
        let confirmationFormatter = DateFormatter()
        confirmationFormatter.dateStyle = .full
        confirmationFormatter.timeStyle = parsedLocalDate.includesTimeOfDay ? .short : .none
        return confirmationFormatter.string(from: parsedLocalDate.date)
    }

    // MARK: - Shortcuts

    private func listShortcuts() async -> MacActionResult {
        do {
            let shortcutsListOutput = try await runCommandLineTool(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["list"],
                timeoutInSeconds: 15
            )
            let shortcutNames = shortcutsListOutput.standardOutput
                .split(separator: "\n")
                .map(String.init)
                .prefix(150)
            guard !shortcutNames.isEmpty else {
                return .success("The user has no Shortcuts.")
            }
            return .success(shortcutNames.joined(separator: "\n"))
        } catch {
            return .failure("Couldn't list Shortcuts: \(error.localizedDescription)")
        }
    }

    private func runShortcut(shortcutName: String) async -> MacActionResult {
        guard askUserToApproveShortcutRun(shortcutName: shortcutName) else {
            return .failure("The user declined running the \"\(shortcutName)\" Shortcut. Don't try again unless they ask.")
        }

        do {
            let shortcutRunOutput = try await runCommandLineTool(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["run", shortcutName],
                timeoutInSeconds: 120
            )
            guard shortcutRunOutput.exitStatus == 0 else {
                let failureDetail = shortcutRunOutput.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure("The \"\(shortcutName)\" Shortcut failed: \(failureDetail.isEmpty ? "exit status \(shortcutRunOutput.exitStatus)" : failureDetail)")
            }
            return .success("Ran the \"\(shortcutName)\" Shortcut.")
        } catch {
            return .failure("Couldn't run the \"\(shortcutName)\" Shortcut: \(error.localizedDescription)")
        }
    }

    private func askUserToApproveShortcutRun(shortcutName: String) -> Bool {
        // The app has no Dock icon, so it must activate itself or the alert
        // would open behind the app the user is in.
        NSApp.activate(ignoringOtherApps: true)

        let approvalAlert = NSAlert()
        approvalAlert.messageText = "Run the \"\(shortcutName)\" Shortcut?"
        approvalAlert.informativeText = "heySona wants to run this Shortcut for you."
        approvalAlert.addButton(withTitle: "Run")
        approvalAlert.addButton(withTitle: "Don't Run")
        return approvalAlert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Command Line Helper

    private struct CommandLineToolOutput {
        let exitStatus: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Runs a command-line tool off the main thread and returns its output.
    /// The process is terminated if it runs longer than `timeoutInSeconds`.
    private func runCommandLineTool(
        executablePath: String,
        arguments: [String],
        timeoutInSeconds: TimeInterval
    ) async throws -> CommandLineToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutInSeconds, execute: timeoutWorkItem)

        // Read both pipes on background threads while the process runs. Reading
        // only after it exits would deadlock once its output fills the pipe
        // buffer (about 64 KB), because the process blocks until it's drained.
        async let standardOutputData = Self.readAllData(from: standardOutputPipe)
        async let standardErrorData = Self.readAllData(from: standardErrorPipe)
        let (finishedStandardOutputData, finishedStandardErrorData) = await (standardOutputData, standardErrorData)

        process.waitUntilExit()
        timeoutWorkItem.cancel()

        return CommandLineToolOutput(
            exitStatus: process.terminationStatus,
            standardOutput: String(data: finishedStandardOutputData, encoding: .utf8) ?? "",
            standardError: String(data: finishedStandardErrorData, encoding: .utf8) ?? ""
        )
    }

    /// Blocks a background thread until the pipe closes (the process exited).
    private nonisolated static func readAllData(from pipe: Pipe) async -> Data {
        await Task.detached {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }.value
    }

    // MARK: - Input Validation

    private func requiredString(
        _ inputName: String,
        in toolInput: [String: Any],
        allowedValues: Set<String>? = nil
    ) throws -> String {
        guard let inputValue = toolInput[inputName] as? String,
              !inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacActionInputError(message: "Missing required text input \"\(inputName)\".")
        }
        if let allowedValues, !allowedValues.contains(inputValue) {
            throw MacActionInputError(message: "\"\(inputName)\" must be one of: \(allowedValues.sorted().joined(separator: ", ")).")
        }
        return inputValue
    }

    private func optionalString(_ inputName: String, in toolInput: [String: Any]) -> String? {
        guard let inputValue = toolInput[inputName] as? String else { return nil }
        let trimmedInputValue = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedInputValue.isEmpty ? nil : trimmedInputValue
    }

    private func optionalInteger(_ inputName: String, in toolInput: [String: Any]) throws -> Int? {
        guard let inputValue = toolInput[inputName] else { return nil }
        // JSONSerialization decodes numbers as NSNumber; reject booleans and
        // strings so a malformed input is reported instead of guessed at.
        guard let numberValue = inputValue as? NSNumber,
              CFGetTypeID(numberValue) != CFBooleanGetTypeID() else {
            throw MacActionInputError(message: "\"\(inputName)\" must be a whole number.")
        }
        return numberValue.intValue
    }
}
