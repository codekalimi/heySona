//
//  ExplanationLibraryStore.swift
//  leanring-buddy
//
//  Saves finished visual explanations on this Mac so they can be replayed
//  later without asking Claude again. Each explanation is one JSON file in
//  ~/Library/Application Support/heySona/explanations/ holding the scene's
//  JSON Lines (setup, steps, quiz) exactly as they were played, plus the
//  concepts it covers, which link explanations into a concept map.
//

import Foundation

/// What an explanation is about, written by Claude in the scene's
/// {"concepts": {...}} line. Used for the concept map and to connect new
/// explanations to topics already learned.
struct ExplanationConcepts: Codable, Equatable {
    /// The topic itself, e.g. "Hash map".
    var mainConcept: String
    /// Ideas it connects to, e.g. "Array", "Hash function".
    var relatedConcepts: [String]
    /// Ideas worth knowing first.
    var prerequisiteConcepts: [String]

    enum CodingKeys: String, CodingKey {
        case mainConcept = "main"
        case relatedConcepts = "related"
        case prerequisiteConcepts = "prerequisites"
    }

    /// Lenient: missing lists become empty, so a partly written line still counts.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mainConcept = try container.decode(String.self, forKey: .mainConcept)
        relatedConcepts = (try? container.decode([String].self, forKey: .relatedConcepts)) ?? []
        prerequisiteConcepts = (try? container.decode([String].self, forKey: .prerequisiteConcepts)) ?? []
    }

    init(mainConcept: String, relatedConcepts: [String], prerequisiteConcepts: [String]) {
        self.mainConcept = mainConcept
        self.relatedConcepts = relatedConcepts
        self.prerequisiteConcepts = prerequisiteConcepts
    }
}

struct SavedExplanation: Codable, Identifiable {
    let id: String
    var title: String
    let question: String
    let createdAtDate: Date
    /// Setup line first, then steps (and an optional quiz line).
    var sceneLines: [String]
    /// Missing in explanations saved before concepts existed.
    var concepts: ExplanationConcepts?

    /// The name shown on the concept map.
    var conceptName: String {
        concepts?.mainConcept ?? title
    }

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
        concepts: ExplanationConcepts?,
        existingExplanationID: String? = nil
    ) -> String? {
        let explanationID = existingExplanationID ?? UUID().uuidString
        let existingExplanation = existingExplanationID.flatMap { load(explanationID: $0) }
        let savedExplanation = SavedExplanation(
            id: explanationID,
            title: title,
            question: question,
            createdAtDate: existingExplanation?.createdAtDate ?? Date(),
            sceneLines: sceneLines,
            concepts: mergedConcepts(existingConcepts: existingExplanation?.concepts, newConcepts: concepts)
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

    // MARK: - Connecting Ideas

    /// A follow-up keeps the topic's main concept and adds any new related ideas.
    private static func mergedConcepts(
        existingConcepts: ExplanationConcepts?,
        newConcepts: ExplanationConcepts?
    ) -> ExplanationConcepts? {
        guard let existingConcepts else { return newConcepts }
        guard let newConcepts else { return existingConcepts }
        func uniqueConceptNames(_ conceptNames: [String]) -> [String] {
            var seenNormalizedNames = Set<String>()
            return conceptNames.filter { seenNormalizedNames.insert(normalizedConceptName($0)).inserted }
        }
        return ExplanationConcepts(
            mainConcept: existingConcepts.mainConcept,
            relatedConcepts: uniqueConceptNames(existingConcepts.relatedConcepts + newConcepts.relatedConcepts),
            prerequisiteConcepts: uniqueConceptNames(existingConcepts.prerequisiteConcepts + newConcepts.prerequisiteConcepts)
        )
    }

    /// "Hash Maps " and "hash map" are the same idea on the map.
    static func normalizedConceptName(_ conceptName: String) -> String {
        var normalizedName = conceptName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if normalizedName.count > 3, normalizedName.hasSuffix("s"), !normalizedName.hasSuffix("ss") {
            normalizedName.removeLast()
        }
        return normalizedName
    }

    /// The topics already explained, newest first, for Claude to build on
    /// ("remember how arrays…"). Nil when nothing is saved yet.
    static func learnedTopicsDescription(maximumTopicCount: Int = 40) -> String? {
        var seenNormalizedNames = Set<String>()
        let learnedTopicNames = allExplanations()
            .map(\.conceptName)
            .filter { seenNormalizedNames.insert(normalizedConceptName($0)).inserted }
            .prefix(maximumTopicCount)
        guard !learnedTopicNames.isEmpty else { return nil }
        return learnedTopicNames.joined(separator: "; ")
    }

    /// The concept map for the explainer window: one node per saved topic
    /// (click to replay), one per related idea, and links between them. A
    /// related idea that is itself a saved topic links the two topics.
    static func conceptGraphJSON() -> String {
        let savedExplanations = allExplanations()
        var graphNodes: [[String: Any]] = []
        var graphLinks: [[String: String]] = []
        var nodeIDByNormalizedName: [String: String] = [:]
        var linkedNodePairs = Set<String>()

        for savedExplanation in savedExplanations {
            let normalizedName = normalizedConceptName(savedExplanation.conceptName)
            guard nodeIDByNormalizedName[normalizedName] == nil else { continue }
            let topicNodeID = "topic-\(savedExplanation.id)"
            nodeIDByNormalizedName[normalizedName] = topicNodeID
            graphNodes.append([
                "id": topicNodeID,
                "label": savedExplanation.conceptName,
                "kind": "topic",
                "explanationId": savedExplanation.id
            ])
        }

        for savedExplanation in savedExplanations {
            guard let concepts = savedExplanation.concepts,
                  let topicNodeID = nodeIDByNormalizedName[normalizedConceptName(savedExplanation.conceptName)] else { continue }
            for connectedConceptName in concepts.relatedConcepts + concepts.prerequisiteConcepts {
                let normalizedName = normalizedConceptName(connectedConceptName)
                guard !normalizedName.isEmpty else { continue }
                let connectedNodeID: String
                if let existingNodeID = nodeIDByNormalizedName[normalizedName] {
                    connectedNodeID = existingNodeID
                } else {
                    connectedNodeID = "idea-\(graphNodes.count)"
                    nodeIDByNormalizedName[normalizedName] = connectedNodeID
                    graphNodes.append(["id": connectedNodeID, "label": connectedConceptName, "kind": "related"])
                }
                guard connectedNodeID != topicNodeID else { continue }
                let nodePairKey = [topicNodeID, connectedNodeID].sorted().joined(separator: "|")
                if linkedNodePairs.insert(nodePairKey).inserted {
                    graphLinks.append(["from": topicNodeID, "to": connectedNodeID])
                }
            }
        }

        let conceptGraph: [String: Any] = ["nodes": graphNodes, "links": graphLinks]
        guard let graphData = try? JSONSerialization.data(withJSONObject: conceptGraph),
              let graphJSON = String(data: graphData, encoding: .utf8) else {
            return "{\"nodes\":[],\"links\":[]}"
        }
        return graphJSON
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
