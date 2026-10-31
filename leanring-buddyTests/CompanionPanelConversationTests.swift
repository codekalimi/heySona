import Foundation
import Testing
@testable import heySona

@MainActor
struct CompanionPanelConversationTests {
    @Test func lateCallbacksCannotReplaceANewerQuestion() throws {
        let conversation = CompanionPanelConversation()
        let previousExchangeID = conversation.beginQuestion("First question")
        let currentExchangeID = conversation.beginQuestion("Second question")
        conversation.receive("The old reply", for: previousExchangeID)
        conversation.finish("The old final reply", for: previousExchangeID)
        conversation.fail("The old failure", for: previousExchangeID)

        let exchange = try #require(conversation.latestExchange)
        #expect(exchange.id == currentExchangeID)
        #expect(exchange.answer.isEmpty)
        #expect(exchange.status == .preparing)
        #expect(exchange.errorMessage == nil)
    }

    @Test func interruptionPreservesPartialReplyAndRejectsMoreChunks() throws {
        let conversation = CompanionPanelConversation()
        let exchangeID = conversation.beginQuestion("Explain binary search")
        conversation.receive("It halves the search area.", for: exchangeID)
        conversation.interrupt()
        conversation.receive("A late chunk", for: exchangeID)
        conversation.finish("A late final reply", for: exchangeID)

        let exchange = try #require(conversation.latestExchange)
        #expect(exchange.status == .interrupted)
        #expect(exchange.answer == "It halves the search area.")
    }

    @Test func stoppingSpeechKeepsACompletedAnswerReadable() {
        let conversation = CompanionPanelConversation()
        let exchangeID = conversation.beginQuestion("Question")
        conversation.finish("The complete answer.", for: exchangeID)
        conversation.interrupt()
        #expect(conversation.latestExchange?.status == .complete)
        #expect(conversation.latestExchange?.answer == "The complete answer.")
    }

    @Test(arguments: [
        "[POINT:100,200:button:screen2]", "[CIRCLE:10,20,5:label]",
        "[BOX:10,20,30,40:label]", "[ARROW:10,20,30,40:label]",
        "[UNDERLINE:10,20,30:label]", "[STEP:10,20:button]",
        "[VISUAL:binary search]", "[VISUAL_FOLLOWUP:another example]", "[WAIT_FOR_CLICK]"
    ])
    func hidesEveryControlTagWhilePreservingOrdinaryBrackets(tag: String) {
        let text = "Try the array [1, 2, 3]. \(tag)"
        #expect(CompanionPanelConversation.readableReply(from: text) == "Try the array [1, 2, 3].")
    }

    @Test(arguments: ["[", "[PO", "[POINT:", "[STEP:10,20", "[VISUAL_FOLLOW", "[WAIT_FOR_CLI"])
    func hidesIncompleteControlTags(tag: String) {
        #expect(CompanionPanelConversation.readableReply(from: "Look here. \(tag)") == "Look here.")
    }

    @Test func preservesOrdinaryUnclosedBrackets() {
        #expect(CompanionPanelConversation.readableReply(from: "array [1, 2") == "array [1, 2")
    }

    @Test func failedReplyKeepsPartialAnswerAndVisibleRecoveryMessage() {
        let conversation = CompanionPanelConversation()
        let exchangeID = conversation.beginQuestion("Question")
        conversation.receive("Part of the answer.", for: exchangeID)
        conversation.fail("Check your connection.", for: exchangeID)
        #expect(conversation.latestExchange?.answer == "Part of the answer.")
        #expect(conversation.latestExchange?.status == .failed)
        #expect(conversation.latestExchange?.errorMessage == "Check your connection.")
    }

    @Test func emptyResponseOffersRecoveryInsteadOfAnEmptyPanel() {
        let conversation = CompanionPanelConversation()
        let exchangeID = conversation.beginQuestion("Question")
        conversation.finish("[POINT:none]", for: exchangeID)
        #expect(conversation.latestExchange?.status == .failed)
        #expect(conversation.latestExchange?.errorMessage != nil)
    }

    @Test func clearingHistoryAlsoClearsTheVisibleReply() {
        let conversation = CompanionPanelConversation()
        let exchangeID = conversation.beginQuestion("Question")
        conversation.receive("Partial answer", for: exchangeID)
        conversation.clear()
        conversation.finish("Late final answer", for: exchangeID)
        #expect(conversation.latestExchange == nil)
        #expect(!conversation.isExpanded)
    }
}
