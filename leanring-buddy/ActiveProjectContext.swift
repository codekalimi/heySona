//
//  ActiveProjectContext.swift
//  leanring-buddy
//
//  Figures out which project folder the user is working in, so Claude can
//  help with code. It reads the front window's open document (Xcode, text
//  editors, and Terminal's current folder all expose one through
//  Accessibility) and walks up to the nearest git repository. A folder pinned
//  in Settings is used when nothing is detected. Claude can then list and
//  read files inside that folder, read-only.
//

import AppKit
import ApplicationServices
import Foundation

struct DetectedProject {
    let projectRootURL: URL
    /// The file open in the front window, when one was detected.
    let frontmostDocumentURL: URL?
    /// "detected" from the front window or "pinned" in Settings.
    let detectionSource: String
}

struct ProjectFileAccessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum ActiveProjectContext {
    /// Folders skipped when listing files: dependencies, build output, VCS internals.
    private static let ignoredFolderNames: Set<String> = [
        ".git", "node_modules", "build", "DerivedData", ".build", "Pods",
        ".next", "dist", ".venv", "venv", "__pycache__", ".idea", ".swiftpm"
    ]

    private static let maximumListedEntryCount = 300
    private static let maximumReadFileByteCount = 200_000

    // MARK: - Detection

    /// Returns the project to use for this request, or nil if there is none.
    /// `pinnedProjectFolderPath` comes from Settings.
    static func detectProject(
        isFrontWindowDetectionEnabled: Bool,
        pinnedProjectFolderPath: String?
    ) -> DetectedProject? {
        if isFrontWindowDetectionEnabled,
           let frontmostDocumentURL = documentURLOfFrontmostWindow() {
            let documentFolderURL = frontmostDocumentURL.hasDirectoryPath
                ? frontmostDocumentURL
                : frontmostDocumentURL.deletingLastPathComponent()
            if let gitRepositoryRootURL = nearestGitRepositoryRoot(startingAt: documentFolderURL) {
                return DetectedProject(
                    projectRootURL: gitRepositoryRootURL,
                    frontmostDocumentURL: frontmostDocumentURL.hasDirectoryPath ? nil : frontmostDocumentURL,
                    detectionSource: "detected"
                )
            }
        }

        if let pinnedProjectFolderPath {
            let pinnedProjectFolderURL = URL(fileURLWithPath: pinnedProjectFolderPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: pinnedProjectFolderURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return DetectedProject(
                    projectRootURL: pinnedProjectFolderURL,
                    frontmostDocumentURL: nil,
                    detectionSource: "pinned"
                )
            }
        }

        return nil
    }

    /// Reads the AXDocument attribute of the frontmost app's focused window.
    /// Uses the Accessibility permission the app already has for push-to-talk.
    private static func documentURLOfFrontmostWindow() -> URL? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let frontmostApplicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)

        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            frontmostApplicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success, let focusedWindowValue else {
            return nil
        }
        // CFTypeRef from AXFocusedWindow is always an AXUIElement.
        let focusedWindowElement = focusedWindowValue as! AXUIElement

        var documentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedWindowElement,
            kAXDocumentAttribute as CFString,
            &documentValue
        ) == .success, let documentURLString = documentValue as? String else {
            return nil
        }

        guard let documentURL = URL(string: documentURLString), documentURL.isFileURL else {
            return nil
        }
        return documentURL
    }

    private static func nearestGitRepositoryRoot(startingAt folderURL: URL) -> URL? {
        var candidateFolderURL = folderURL.standardizedFileURL
        let homeFolderPath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        while candidateFolderURL.path != "/" {
            let gitMarkerPath = candidateFolderURL.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitMarkerPath) {
                return candidateFolderURL
            }
            // Never treat the whole home folder as a "project".
            if candidateFolderURL.path == homeFolderPath { return nil }
            candidateFolderURL.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Context For Claude

    /// A few lines describing the project, added to the user's message.
    static func contextDescription(for detectedProject: DetectedProject) -> String {
        let projectRootURL = detectedProject.projectRootURL
        var contextLines = [
            "active project: \(projectRootURL.lastPathComponent) at \(abbreviateHomeFolder(in: projectRootURL.path)) (\(detectedProject.detectionSource))"
        ]

        if let currentGitBranchName = currentGitBranchName(projectRootURL: projectRootURL) {
            contextLines.append("git branch: \(currentGitBranchName)")
        }

        if let frontmostDocumentURL = detectedProject.frontmostDocumentURL {
            contextLines.append("file open in the front window: \(relativePath(of: frontmostDocumentURL, inside: projectRootURL))")
        }

        return contextLines.joined(separator: "\n")
    }

    /// Reads `.git/HEAD` directly instead of running git, so no process is spawned.
    private static func currentGitBranchName(projectRootURL: URL) -> String? {
        let gitHeadFileURL = projectRootURL.appendingPathComponent(".git/HEAD")
        guard let gitHeadContents = try? String(contentsOf: gitHeadFileURL, encoding: .utf8) else {
            return nil
        }
        let trimmedGitHeadContents = gitHeadContents.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchReferencePrefix = "ref: refs/heads/"
        if trimmedGitHeadContents.hasPrefix(branchReferencePrefix) {
            return String(trimmedGitHeadContents.dropFirst(branchReferencePrefix.count))
        }
        return "detached at \(trimmedGitHeadContents.prefix(8))"
    }

    // MARK: - Read-Only File Access

    /// Lists files and folders under `relativeFolderPath` (default: project
    /// root), up to `maximumDepth` levels deep, skipping dependency and build folders.
    static func listProjectFiles(
        projectRootURL: URL,
        relativeFolderPath: String?,
        maximumDepth: Int
    ) throws -> String {
        let listingRootURL = try resolvePathInsideProject(relativeFolderPath ?? "", projectRootURL: projectRootURL)
        let clampedMaximumDepth = max(1, min(4, maximumDepth))

        var listedEntryLines: [String] = []
        var wasListingTruncated = false

        func listFolder(_ folderURL: URL, currentDepth: Int) {
            guard listedEntryLines.count < maximumListedEntryCount else {
                wasListingTruncated = true
                return
            }
            let folderEntryURLs = ((try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for folderEntryURL in folderEntryURLs {
                guard listedEntryLines.count < maximumListedEntryCount else {
                    wasListingTruncated = true
                    return
                }
                let isFolder = (try? folderEntryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let entryRelativePath = relativePath(of: folderEntryURL, inside: projectRootURL)

                if isFolder {
                    guard !ignoredFolderNames.contains(folderEntryURL.lastPathComponent) else { continue }
                    listedEntryLines.append(entryRelativePath + "/")
                    if currentDepth < clampedMaximumDepth {
                        listFolder(folderEntryURL, currentDepth: currentDepth + 1)
                    }
                } else {
                    listedEntryLines.append(entryRelativePath)
                }
            }
        }

        listFolder(listingRootURL, currentDepth: 1)

        guard !listedEntryLines.isEmpty else { return "(empty folder)" }
        var listingText = listedEntryLines.joined(separator: "\n")
        if wasListingTruncated {
            listingText += "\n(list cut off at \(maximumListedEntryCount) entries; list a subfolder to see more)"
        }
        return listingText
    }

    static func readProjectFile(projectRootURL: URL, relativeFilePath: String) throws -> String {
        let fileURL = try resolvePathInsideProject(relativeFilePath, projectRootURL: projectRootURL)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw ProjectFileAccessError(message: "No file at \(relativeFilePath) in the project.")
        }
        guard !isDirectory.boolValue else {
            throw ProjectFileAccessError(message: "\(relativeFilePath) is a folder; use list_project_files.")
        }

        let fileData = try Data(contentsOf: fileURL)
        guard fileData.count <= maximumReadFileByteCount else {
            throw ProjectFileAccessError(message: "\(relativeFilePath) is \(fileData.count / 1024) KB, too large to read (limit \(maximumReadFileByteCount / 1000) KB).")
        }
        guard let fileText = String(data: fileData, encoding: .utf8) else {
            throw ProjectFileAccessError(message: "\(relativeFilePath) isn't a text file.")
        }
        return fileText
    }

    /// Resolves a project-relative path and refuses anything that ends up
    /// outside the project folder (via "..", absolute paths, or symlinks).
    private static func resolvePathInsideProject(_ relativePath: String, projectRootURL: URL) throws -> URL {
        let resolvedProjectRootPath = projectRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let trimmedRelativePath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidateURL = trimmedRelativePath.isEmpty || trimmedRelativePath == "."
            ? projectRootURL
            : projectRootURL.appendingPathComponent(trimmedRelativePath)
        let resolvedCandidatePath = candidateURL.resolvingSymlinksInPath().standardizedFileURL.path

        let isInsideProject = resolvedCandidatePath == resolvedProjectRootPath
            || resolvedCandidatePath.hasPrefix(resolvedProjectRootPath + "/")
        guard isInsideProject else {
            throw ProjectFileAccessError(message: "\(relativePath) is outside the project folder.")
        }
        return URL(fileURLWithPath: resolvedCandidatePath)
    }

    // MARK: - Path Helpers

    private static func relativePath(of fileURL: URL, inside projectRootURL: URL) -> String {
        let projectRootPath = projectRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        // Resolve links in the parent folders only, so a linked file keeps its
        // own name (CLAUDE.md, not the AGENTS.md it points to).
        let resolvedParentFolderPath = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = resolvedParentFolderPath + "/" + fileURL.lastPathComponent
        if filePath.hasPrefix(projectRootPath + "/") {
            return String(filePath.dropFirst(projectRootPath.count + 1))
        }
        return abbreviateHomeFolder(in: filePath)
    }

    static func abbreviateHomeFolder(in path: String) -> String {
        let homeFolderPath = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: homeFolderPath, with: "~", options: .anchored)
    }
}
