//
//  ExplanationLibraryStore.swift
//  leanring-buddy
//
//  Saves finished visual explanations on this Mac so they can be replayed
//  later without asking Claude again. Each explanation is one JSON file in
//  ~/Library/Application Support/heySona/explanations/ holding the scene's
//  JSON Lines (setup, steps, quiz) exactly as they were played.
//

import Foundation

struct SavedExplanation: Codable, Identifiable {
    let id: String
    var title: String
    let question: String
    let createdAtDate: Date
    /// Setup line first, then steps (and an optional quiz line).
    var sceneLines: [String]

    var stepCount: Int {
        sceneLines.dropFirst().filter { !$0.contains("\"quiz\"") }.count
    }
}

@MainActor
enum ExplanationLibraryStore {
    private static var libraryFolderURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heySona/explanations", isDirectory: true)
    }

    /// Saves (or overwrites, when `existingExplanationID` is given) and
    /// returns the explanation's id.
    @discardableResult
    static func save(
        sceneLines: [String],
        title: String,
        question: String,
        existingExplanationID: String? = nil
    ) -> String? {
        let explanationID = existingExplanationID ?? UUID().uuidString
        let existingCreatedAtDate = existingExplanationID.flatMap { load(explanationID: $0)?.createdAtDate }
        let savedExplanation = SavedExplanation(
            id: explanationID,
            title: title,
            question: question,
            createdAtDate: existingCreatedAtDate ?? Date(),
            sceneLines: sceneLines
        )

        do {
            try FileManager.default.createDirectory(at: libraryFolderURL, withIntermediateDirectories: true)
            let jsonEncoder = JSONEncoder()
            jsonEncoder.dateEncodingStrategy = .iso8601
            let explanationData = try jsonEncoder.encode(savedExplanation)
            try explanationData.write(to: fileURL(forExplanationID: explanationID), options: [.atomic])
            print("📚 Saved explanation \"\(title)\" (\(savedExplanation.stepCount) steps)")
            return explanationID
        } catch {
            print("⚠️ Explanation library: couldn't save: \(error)")
            return nil
        }
    }

    /// Newest first.
    static func allExplanations() -> [SavedExplanation] {
        let explanationFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: libraryFolderURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return explanationFileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { decodeExplanation(at: $0) }
            .sorted { $0.createdAtDate > $1.createdAtDate }
    }

    static func load(explanationID: String) -> SavedExplanation? {
        decodeExplanation(at: fileURL(forExplanationID: explanationID))
    }

    static func delete(explanationID: String) {
        try? FileManager.default.removeItem(at: fileURL(forExplanationID: explanationID))
    }

    /// Entries for the library list in the explainer window.
    static func libraryEntriesJSON() -> String {
        let entryDateFormatter = DateFormatter()
        entryDateFormatter.dateStyle = .medium
        entryDateFormatter.timeStyle = .short

        let libraryEntries: [[String: String]] = allExplanations().map { savedExplanation in
            [
                "id": savedExplanation.id,
                "title": savedExplanation.title,
                "detail": "\(savedExplanation.stepCount) steps · \(entryDateFormatter.string(from: savedExplanation.createdAtDate))"
            ]
        }
        guard let entriesData = try? JSONSerialization.data(withJSONObject: libraryEntries),
              let entriesJSON = String(data: entriesData, encoding: .utf8) else {
            return "[]"
        }
        return entriesJSON
    }

    // MARK: - Files

    private static func fileURL(forExplanationID explanationID: String) -> URL {
        // IDs are UUIDs we generated; keep only safe characters regardless.
        let safeExplanationID = explanationID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return libraryFolderURL.appendingPathComponent("\(safeExplanationID).json")
    }

    private static func decodeExplanation(at explanationFileURL: URL) -> SavedExplanation? {
        guard let explanationData = try? Data(contentsOf: explanationFileURL) else { return nil }
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        return try? jsonDecoder.decode(SavedExplanation.self, from: explanationData)
    }
}
