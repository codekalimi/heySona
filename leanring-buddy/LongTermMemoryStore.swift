//
//  LongTermMemoryStore.swift
//  leanring-buddy
//
//  Facts heySona remembers about the user across launches (their projects,
//  preferences, tools). Stored as a JSON file in Application Support on this
//  Mac only. Every memory is listed in Settings, where it can be deleted.
//

import Combine
import Foundation

struct RememberedFact: Codable, Identifiable, Equatable {
    /// Short stable ID (e.g. "m12") that Claude uses to forget a fact.
    let id: String
    let factText: String
    let rememberedAtDate: Date
}

@MainActor
final class LongTermMemoryStore: ObservableObject {
    /// Newest last, the order they're shown to Claude.
    @Published private(set) var rememberedFacts: [RememberedFact] = []

    /// Keeps the system prompt from growing without limit. When full, the
    /// oldest fact is dropped to make room.
    static let maximumRememberedFactCount = 150
    static let maximumFactCharacterCount = 300

    private let memoryFileURL: URL
    private var nextFactNumber = 1

    init() {
        let applicationSupportFolderURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heySona", isDirectory: true)
        try? FileManager.default.createDirectory(at: applicationSupportFolderURL, withIntermediateDirectories: true)
        memoryFileURL = applicationSupportFolderURL.appendingPathComponent("long-term-memory.json")

        loadRememberedFactsFromDisk()
    }

    /// Saves a fact and returns it. Returns the existing fact instead when the
    /// same text is already remembered.
    @discardableResult
    func rememberFact(_ factText: String) -> RememberedFact? {
        let trimmedFactText = String(
            factText.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumFactCharacterCount)
        )
        guard !trimmedFactText.isEmpty else { return nil }

        if let alreadyRememberedFact = rememberedFacts.first(where: {
            $0.factText.caseInsensitiveCompare(trimmedFactText) == .orderedSame
        }) {
            return alreadyRememberedFact
        }

        let newFact = RememberedFact(
            id: "m\(nextFactNumber)",
            factText: trimmedFactText,
            rememberedAtDate: Date()
        )
        nextFactNumber += 1

        rememberedFacts.append(newFact)
        if rememberedFacts.count > Self.maximumRememberedFactCount {
            rememberedFacts.removeFirst(rememberedFacts.count - Self.maximumRememberedFactCount)
        }
        saveRememberedFactsToDisk()
        return newFact
    }

    /// Removes a fact by ID. Returns the removed fact, or nil if none matched.
    @discardableResult
    func forgetFact(withID factID: String) -> RememberedFact? {
        guard let factIndex = rememberedFacts.firstIndex(where: { $0.id == factID }) else {
            return nil
        }
        let forgottenFact = rememberedFacts.remove(at: factIndex)
        saveRememberedFactsToDisk()
        return forgottenFact
    }

    func forgetAllFacts() {
        rememberedFacts.removeAll()
        saveRememberedFactsToDisk()
    }

    /// The block appended to Claude's system prompt, or "" when empty.
    func systemPromptListOfRememberedFacts() -> String {
        guard !rememberedFacts.isEmpty else { return "" }
        let factLines = rememberedFacts.map { rememberedFact in
            "- [\(rememberedFact.id)] \(rememberedFact.factText)"
        }
        return "\nthings you remember about the user (id in brackets):\n" + factLines.joined(separator: "\n")
    }

    // MARK: - Disk

    private func loadRememberedFactsFromDisk() {
        guard let memoryFileData = try? Data(contentsOf: memoryFileURL) else { return }

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        guard let loadedFacts = try? jsonDecoder.decode([RememberedFact].self, from: memoryFileData) else {
            print("⚠️ Memory: couldn't read \(memoryFileURL.path); starting empty")
            return
        }

        rememberedFacts = loadedFacts
        // Continue numbering after the highest saved ID so IDs never repeat.
        let highestSavedFactNumber = loadedFacts
            .compactMap { Int($0.id.dropFirst()) }
            .max() ?? 0
        nextFactNumber = highestSavedFactNumber + 1
    }

    private func saveRememberedFactsToDisk() {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let memoryFileData = try jsonEncoder.encode(rememberedFacts)
            try memoryFileData.write(to: memoryFileURL, options: [.atomic])
        } catch {
            print("⚠️ Memory: couldn't save memories: \(error)")
        }
    }
}
