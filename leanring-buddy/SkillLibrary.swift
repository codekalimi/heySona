//
//  SkillLibrary.swift
//  leanring-buddy
//
//  Skills: small Markdown files of know-how that are added to a request only
//  when they're relevant, instead of putting every instruction in every
//  prompt. Three kinds:
//  - topic: how to explain and draw a subject (neural networks, Big O, …),
//    matched by keywords in the question or the visual-explanation brief,
//  - app: landmarks and shortcuts for an app, matched by the front app's
//    bundle ID,
//  - procedure: steps saved after heySona guided the user through a task
//    (save_procedure), matched by app and keywords.
//
//  Bundled skills live in Skills.bundle (a .bundle folder so Xcode copies
//  the files as-is). The user's own skills live in
//  ~/Library/Application Support/heySona/skills/ (procedures in its
//  procedures/ subfolder) and replace a bundled skill with the same name.
//
//  File format:
//      ---
//      name: Neural networks
//      kind: topic
//      description: One line shown in the skill catalog.
//      keywords: neural network, layer, neuron, weight
//      apps: com.blackmagic-design.DaVinciResolve
//      use_for: voice, explainer
//      ---
//      Markdown body…
//

import AppKit
import Combine
import Foundation

enum SkillKind: String {
    case topic
    case app
    case procedure
}

struct Skill: Identifiable, Hashable {
    let name: String
    let kind: SkillKind
    let description: String
    let keywords: [String]
    let appBundleIdentifiers: [String]
    let isUsableForVoiceReplies: Bool
    let isUsableForVisualExplanations: Bool
    let body: String
    let fileURL: URL
    let isBundled: Bool

    /// Names are unique case-insensitively; a user skill replaces a bundled one.
    var id: String { name.lowercased() }
}

@MainActor
final class SkillLibrary: ObservableObject {
    @Published private(set) var skills: [Skill] = []
    @Published private(set) var disabledSkillIDs: Set<String>
    /// For Settings: which skills the latest request used.
    @Published var lastUsedSkillNames: [String] = []

    /// About 1,500 words; longer bodies are cut so one file can't flood a prompt.
    static let maximumSkillBodyCharacterCount = 12_000
    private static let disabledSkillIDsDefaultsKey = "disabledSkillIDs"

    private let bundledSkillsFolderURL: URL?
    let userSkillsFolderURL: URL

    nonisolated static var defaultUserSkillsFolderURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heySona/skills", isDirectory: true)
    }

    var userProceduresFolderURL: URL {
        userSkillsFolderURL.appendingPathComponent("procedures", isDirectory: true)
    }

    /// The folders can be replaced in tests.
    init(
        bundledSkillsFolderURL: URL? = Bundle.main.url(forResource: "Skills", withExtension: "bundle"),
        userSkillsFolderURL: URL = SkillLibrary.defaultUserSkillsFolderURL
    ) {
        self.bundledSkillsFolderURL = bundledSkillsFolderURL
        self.userSkillsFolderURL = userSkillsFolderURL
        self.disabledSkillIDs = Set(UserDefaults.standard.stringArray(forKey: Self.disabledSkillIDsDefaultsKey) ?? [])
        reload()
    }

    // MARK: - Loading

    func reload() {
        var skillsByID: [String: Skill] = [:]
        for bundledSkill in Self.loadSkills(inFolder: bundledSkillsFolderURL, isBundled: true) {
            skillsByID[bundledSkill.id] = bundledSkill
        }
        // User skills come second so they replace bundled ones with the same name.
        for userSkill in Self.loadSkills(inFolder: userSkillsFolderURL, isBundled: false) {
            skillsByID[userSkill.id] = userSkill
        }
        skills = skillsByID.values.sorted { firstSkill, secondSkill in
            if firstSkill.kind != secondSkill.kind { return firstSkill.kind.rawValue < secondSkill.kind.rawValue }
            return firstSkill.name.localizedCaseInsensitiveCompare(secondSkill.name) == .orderedAscending
        }
        print("🧩 Skills loaded: \(skills.count)")
    }

    private static func loadSkills(inFolder folderURL: URL?, isBundled: Bool) -> [Skill] {
        guard let folderURL,
              let folderEnumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var loadedSkills: [Skill] = []
        for case let fileURL as URL in folderEnumerator where fileURL.pathExtension.lowercased() == "md" {
            guard let fileText = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if let parsedSkill = parseSkill(fileText: fileText, fileURL: fileURL, isBundled: isBundled) {
                loadedSkills.append(parsedSkill)
            } else {
                print("⚠️ Skills: skipped \(fileURL.lastPathComponent) (needs front matter with a name)")
            }
        }
        return loadedSkills
    }

    /// Parses the front matter block and body. Returns nil without a name.
    static func parseSkill(fileText: String, fileURL: URL, isBundled: Bool) -> Skill? {
        let fileLines = fileText.components(separatedBy: .newlines)
        guard fileLines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingLineIndex = fileLines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }

        var frontMatterValues: [String: String] = [:]
        for frontMatterLine in fileLines[1..<closingLineIndex] {
            guard let colonIndex = frontMatterLine.firstIndex(of: ":") else { continue }
            let key = frontMatterLine[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = frontMatterLine[frontMatterLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            frontMatterValues[key] = value
        }

        guard let skillName = frontMatterValues["name"], !skillName.isEmpty else { return nil }
        func listValue(_ key: String) -> [String] {
            (frontMatterValues[key] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let useForValues = Set(listValue("use_for").map { $0.lowercased() })
        var skillBody = fileLines[(closingLineIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if skillBody.count > maximumSkillBodyCharacterCount {
            print("⚠️ Skills: \(skillName) is long, using its first \(maximumSkillBodyCharacterCount) characters")
            skillBody = String(skillBody.prefix(maximumSkillBodyCharacterCount))
        }

        return Skill(
            name: skillName,
            kind: SkillKind(rawValue: (frontMatterValues["kind"] ?? "topic").lowercased()) ?? .topic,
            description: frontMatterValues["description"] ?? "",
            keywords: listValue("keywords"),
            appBundleIdentifiers: listValue("apps"),
            // With no use_for line, a skill is used everywhere.
            isUsableForVoiceReplies: useForValues.isEmpty || useForValues.contains("voice"),
            isUsableForVisualExplanations: useForValues.isEmpty || useForValues.contains("explainer"),
            body: skillBody,
            fileURL: fileURL,
            isBundled: isBundled
        )
    }

    // MARK: - Enabling

    var enabledSkills: [Skill] {
        skills.filter { !disabledSkillIDs.contains($0.id) }
    }

    func isSkillEnabled(_ skill: Skill) -> Bool {
        !disabledSkillIDs.contains(skill.id)
    }

    func setSkillEnabled(_ skill: Skill, isEnabled: Bool) {
        if isEnabled {
            disabledSkillIDs.remove(skill.id)
        } else {
            disabledSkillIDs.insert(skill.id)
        }
        UserDefaults.standard.set(Array(disabledSkillIDs), forKey: Self.disabledSkillIDsDefaultsKey)
    }

    func enabledSkill(named skillName: String) -> Skill? {
        let requestedSkillID = skillName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return enabledSkills.first { $0.id == requestedSkillID }
    }

    // MARK: - Choosing Skills For A Request

    /// App skills for the front app, saved procedures for that app that
    /// match the question, and the two best-matching topic skills.
    func skillsForVoiceRequest(transcript: String, frontmostBundleIdentifier: String?) -> [Skill] {
        let voiceSkills = enabledSkills.filter(\.isUsableForVoiceReplies)
        var chosenSkills: [Skill] = []

        if let frontmostBundleIdentifier {
            let frontAppSkills = voiceSkills.filter { $0.appBundleIdentifiers.contains(frontmostBundleIdentifier) }
            chosenSkills += frontAppSkills.filter { $0.kind == .app }
            chosenSkills += Self.bestKeywordMatches(
                among: frontAppSkills.filter { $0.kind == .procedure },
                for: transcript,
                maximumCount: 1
            )
        }
        chosenSkills += Self.bestKeywordMatches(
            among: voiceSkills.filter { $0.kind == .topic },
            for: transcript,
            maximumCount: 2
        )
        return chosenSkills
    }

    /// The two topic skills that best match a visual explanation's brief.
    func skillsForVisualExplanation(briefAndQuestion: String) -> [Skill] {
        Self.bestKeywordMatches(
            among: enabledSkills.filter { $0.kind == .topic && $0.isUsableForVisualExplanations },
            for: briefAndQuestion,
            maximumCount: 2
        )
    }

    /// Scores skills by how many of their keywords appear in `text` (word
    /// forms: "weights" matches "weight"; multi-word keywords as phrases).
    static func bestKeywordMatches(among candidateSkills: [Skill], for text: String, maximumCount: Int) -> [Skill] {
        let lowercasedText = " " + text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: " ") + " "
        let textTerms = Set(SearchTextNormalizer.searchTerms(in: text))

        let scoredSkills = candidateSkills.map { candidateSkill -> (skill: Skill, score: Int) in
            let matchedKeywordCount = candidateSkill.keywords.filter { keyword in
                let keywordWords = keyword.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                guard !keywordWords.isEmpty else { return false }
                if keywordWords.count > 1 {
                    return lowercasedText.contains(" " + keywordWords.joined(separator: " ") + " ")
                }
                let keywordTerms = SearchTextNormalizer.searchTerms(in: keyword)
                return keywordTerms.contains { textTerms.contains($0) }
                    || lowercasedText.contains(" " + keywordWords[0] + " ")
            }.count
            return (candidateSkill, matchedKeywordCount)
        }
        return scoredSkills
            .filter { $0.score >= 1 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.skill.name < $1.skill.name }
            .prefix(maximumCount)
            .map(\.skill)
    }

    // MARK: - Saved Procedures

    struct ProcedureError: Error {
        let message: String
    }

    static let maximumProcedureCharacterCount = 6_000

    /// Saves a new procedure file and returns its name.
    func saveProcedure(
        title procedureTitle: String,
        appBundleIdentifier: String,
        keywordsText: String,
        stepsText: String
    ) -> Result<String, ProcedureError> {
        guard (3...80).contains(procedureTitle.count) else {
            return .failure(ProcedureError(message: "The title must be 3 to 80 characters."))
        }
        guard appBundleIdentifier.range(of: #"^[A-Za-z0-9.\-]+$"#, options: .regularExpression) != nil else {
            return .failure(ProcedureError(message: "app_bundle_id doesn't look like a bundle ID."))
        }
        guard skills.first(where: { $0.id == procedureTitle.lowercased() }) == nil else {
            return .failure(ProcedureError(message: "A skill named \"\(procedureTitle)\" already exists. Use update_procedure, or pick another title."))
        }
        let validatedSteps: String
        switch Self.validatedProcedureSteps(stepsText) {
        case .success(let steps): validatedSteps = steps
        case .failure(let procedureError): return .failure(procedureError)
        }

        let fileSlug = procedureTitle.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        guard !fileSlug.isEmpty else {
            return .failure(ProcedureError(message: "The title needs some letters or numbers."))
        }
        let procedureFileURL = userProceduresFolderURL.appendingPathComponent("\(fileSlug).md")
        guard !FileManager.default.fileExists(atPath: procedureFileURL.path) else {
            return .failure(ProcedureError(message: "A procedure file with a similar title exists. Pick another title."))
        }

        let cleanKeywords = keywordsText
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(20)
            .joined(separator: ", ")
        let procedureFileText = """
        ---
        name: \(procedureTitle.replacingOccurrences(of: "\n", with: " "))
        kind: procedure
        description: Saved steps for "\(procedureTitle)".
        keywords: \(cleanKeywords)
        apps: \(appBundleIdentifier)
        use_for: voice
        ---
        \(validatedSteps)
        """
        do {
            try FileManager.default.createDirectory(at: userProceduresFolderURL, withIntermediateDirectories: true)
            try procedureFileText.write(to: procedureFileURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(ProcedureError(message: "Couldn't save the file: \(error.localizedDescription)"))
        }
        reload()
        print("🧩 Saved procedure \"\(procedureTitle)\"")
        return .success(procedureTitle)
    }

    /// Replaces the steps of a saved procedure, keeping its front matter.
    func updateProcedure(named procedureName: String, stepsText: String) -> Result<String, ProcedureError> {
        guard let savedProcedure = skills.first(where: { $0.id == procedureName.lowercased() && $0.kind == .procedure && !$0.isBundled }) else {
            return .failure(ProcedureError(message: "No saved procedure is named \"\(procedureName)\"."))
        }
        let validatedSteps: String
        switch Self.validatedProcedureSteps(stepsText) {
        case .success(let steps): validatedSteps = steps
        case .failure(let procedureError): return .failure(procedureError)
        }
        guard let existingFileText = try? String(contentsOf: savedProcedure.fileURL, encoding: .utf8) else {
            return .failure(ProcedureError(message: "Couldn't read the saved procedure."))
        }
        let existingLines = existingFileText.components(separatedBy: .newlines)
        guard let closingLineIndex = existingLines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return .failure(ProcedureError(message: "The saved procedure has no front matter."))
        }
        let updatedFileText = existingLines[...closingLineIndex].joined(separator: "\n") + "\n" + validatedSteps + "\n"
        do {
            try updatedFileText.write(to: savedProcedure.fileURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(ProcedureError(message: "Couldn't save the file: \(error.localizedDescription)"))
        }
        reload()
        return .success(savedProcedure.name)
    }

    func deleteProcedure(_ procedure: Skill) {
        guard procedure.kind == .procedure, !procedure.isBundled else { return }
        try? FileManager.default.removeItem(at: procedure.fileURL)
        reload()
    }

    /// Keeps only numbered step lines ("1. …"), since procedures are injected
    /// into later requests and must not carry anything else.
    private static func validatedProcedureSteps(_ stepsText: String) -> Result<String, ProcedureError> {
        let numberedStepLines = stepsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^\d{1,2}[.)] \S"#, options: .regularExpression) != nil }
        guard (2...20).contains(numberedStepLines.count) else {
            return .failure(ProcedureError(message: "Steps must be a numbered list of 2 to 20 steps (\"1. …\")."))
        }
        let joinedSteps = numberedStepLines.joined(separator: "\n")
        guard joinedSteps.count <= maximumProcedureCharacterCount else {
            return .failure(ProcedureError(message: "The steps are too long; keep each one short."))
        }
        return .success(joinedSteps)
    }

    // MARK: - Folder

    /// Creates the user's skills folder (with a short guide) and shows it in Finder.
    func openUserSkillsFolder() {
        try? FileManager.default.createDirectory(at: userProceduresFolderURL, withIntermediateDirectories: true)
        let guideFileURL = userSkillsFolderURL.appendingPathComponent("README.txt")
        if !FileManager.default.fileExists(atPath: guideFileURL.path) {
            let guideText = """
            Add your own heySona skills here as .md files. Each starts with:

            ---
            name: My skill
            kind: topic            (topic, app, or procedure)
            description: One line about what it's for.
            keywords: words, that, should, trigger, it
            apps: com.example.bundle-id   (app and procedure skills)
            use_for: voice, explainer
            ---

            Then write the know-how in Markdown below it. A file with the same name
            as a built-in skill replaces it. Press Reload in Settings after editing.
            """
            try? guideText.write(to: guideFileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(userSkillsFolderURL)
    }
}
