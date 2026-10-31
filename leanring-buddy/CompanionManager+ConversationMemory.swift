//
//  CompanionManager+ConversationMemory.swift
//  leanring-buddy
//
//  Conversation history across launches (see ConversationArchive.swift):
//  saving each exchange, grouping exchanges into sessions (a 30-minute gap
//  starts a new one), writing a journal summary of each finished session
//  with the cheapest model, and restoring recent context at launch.
//  The state lives in CompanionManager.swift.
//

import Foundation

extension CompanionManager {
    /// A gap this long between exchanges ends a session.
    static let conversationSessionIdleGapInSeconds: TimeInterval = 30 * 60
    /// Exchanges younger than this are restored into the conversation at launch.
    static let restoredConversationMaximumAgeInSeconds: TimeInterval = 2 * 60 * 60
    static let maximumConversationHistoryExchangeCount = 10

    /// At launch: bring back the last exchanges if they're recent, continue
    /// their session if it hasn't gone idle, and summarize sessions that
    /// ended while the app was closed.
    func restoreConversationContextFromArchive() {
        guard isConversationHistoryEnabled else { return }

        let recentArchivedExchanges = conversationArchiveStore.recentExchanges(
            maximumAgeInSeconds: Self.restoredConversationMaximumAgeInSeconds,
            maximumCount: Self.maximumConversationHistoryExchangeCount
        )
        conversationHistory = recentArchivedExchanges.map { archivedExchange in
            (userTranscript: archivedExchange.userText, assistantResponse: archivedExchange.assistantText)
        }

        if let mostRecentExchange = conversationArchiveStore.mostRecentExchange,
           Date().timeIntervalSince(mostRecentExchange.date) < Self.conversationSessionIdleGapInSeconds {
            currentConversationSessionID = mostRecentExchange.sessionID
            lastConversationExchangeDate = mostRecentExchange.date
            scheduleConversationSessionSummary()
        }
        if !conversationHistory.isEmpty {
            print("🗂️ Restored \(conversationHistory.count) recent exchange(s) from the conversation archive")
        }

        Task { await summarizeFinishedConversationSessions() }
    }

    /// Saves one exchange. A long gap since the last one starts a new session.
    func recordExchangeInConversationArchive(userTranscript: String, assistantResponse: String) {
        guard isConversationHistoryEnabled else { return }
        // Guided-mode continuations are heySona's own prompts, not the user's words.
        guard !userTranscript.hasPrefix("(guided mode)") else { return }

        let exchangeDate = Date()
        if let lastConversationExchangeDate,
           exchangeDate.timeIntervalSince(lastConversationExchangeDate) >= Self.conversationSessionIdleGapInSeconds {
            currentConversationSessionID = UUID().uuidString
        }
        lastConversationExchangeDate = exchangeDate

        conversationArchiveStore.appendExchange(ArchivedConversationExchange(
            id: UUID().uuidString,
            sessionID: currentConversationSessionID,
            date: exchangeDate,
            userText: userTranscript,
            assistantText: assistantResponse
        ))
        scheduleConversationSessionSummary()
    }

    /// The session is summarized once it has been idle for the full gap.
    private func scheduleConversationSessionSummary() {
        conversationSessionSummaryTask?.cancel()
        conversationSessionSummaryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.conversationSessionIdleGapInSeconds + 5) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.summarizeFinishedConversationSessions()
        }
    }

    /// Writes a journal entry for every finished session that has none yet.
    func summarizeFinishedConversationSessions() async {
        guard isConversationHistoryEnabled, !isSummarizingConversationSessions else { return }
        isSummarizingConversationSessions = true
        defer { isSummarizingConversationSessions = false }

        let finishedSessionIDs = conversationArchiveStore.unsummarizedSessionIDs(
            endedBefore: Date().addingTimeInterval(-Self.conversationSessionIdleGapInSeconds)
        )
        for finishedSessionID in finishedSessionIDs {
            let sessionExchanges = conversationArchiveStore.exchanges(inSessionWithID: finishedSessionID)
            guard let firstExchange = sessionExchanges.first, let lastExchange = sessionExchanges.last else { continue }
            do {
                let summaryResponse = try await conversationSummaryClaudeAPI.analyzeImage(
                    images: [],
                    systemPrompt: ConversationArchiveTools.sessionSummarySystemPrompt,
                    userPrompt: ConversationArchiveTools.sessionSummaryUserPrompt(for: sessionExchanges)
                )
                let summaryText = summaryResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summaryText.isEmpty else { continue }
                conversationArchiveStore.saveSummary(ConversationSessionSummary(
                    sessionID: finishedSessionID,
                    startDate: firstExchange.date,
                    endDate: lastExchange.date,
                    exchangeCount: sessionExchanges.count,
                    summaryText: summaryText
                ))
                print("🗂️ Summarized a session of \(sessionExchanges.count) exchange(s): \(summaryText)")
            } catch {
                // Try again next time (launch or the next idle session).
                print("⚠️ Couldn't summarize a conversation session: \(error.localizedDescription)")
                return
            }
        }
    }

    func setConversationHistoryEnabled(_ isEnabled: Bool) {
        isConversationHistoryEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isConversationHistoryEnabled")
        if !isEnabled {
            conversationSessionSummaryTask?.cancel()
        }
    }

    /// Deletes the archive and forgets the current conversation too.
    func clearConversationHistory() {
        conversationSessionSummaryTask?.cancel()
        conversationArchiveStore.clearAll()
        conversationHistory = []
        panelConversation.clear()
        currentConversationSessionID = UUID().uuidString
        lastConversationExchangeDate = nil
    }
}
