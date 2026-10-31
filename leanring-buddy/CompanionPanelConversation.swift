import Combine
import Foundation

/// In-memory presentation of the latest exchange, independent of saved history.
@MainActor
final class CompanionPanelConversation: ObservableObject {
    enum ReplyStatus: Equatable {
        case preparing
        case streaming
        case complete
        case interrupted
        case failed
    }

    struct Exchange: Identifiable {
        let id: UUID
        let question: String
        var answer = ""
        var status: ReplyStatus = .preparing
        var errorMessage: String?

        var isReceivingReply: Bool {
            status == .preparing || status == .streaming
        }
    }

    @Published private(set) var latestExchange: Exchange?
    @Published var isExpanded = false
    @Published var maximumPanelHeight: CGFloat = 600

    func panelSize(isReady: Bool) -> CGSize {
        CGSize(
            width: isReady && isExpanded ? 440 : 360,
            height: min(isReady && !isExpanded ? 380 : 560, maximumPanelHeight)
        )
    }

    @discardableResult
    func beginQuestion(_ question: String) -> UUID {
        let exchange = Exchange(id: UUID(), question: question)
        latestExchange = exchange
        isExpanded = true
        return exchange.id
    }

    func receive(_ accumulatedText: String, for exchangeID: UUID) {
        guard var exchange = latestExchange,
              exchange.id == exchangeID, exchange.isReceivingReply else { return }
        exchange.answer = Self.readableReply(from: accumulatedText)
        exchange.status = .streaming
        latestExchange = exchange
    }

    func finish(_ answer: String, for exchangeID: UUID) {
        guard var exchange = latestExchange,
              exchange.id == exchangeID, exchange.isReceivingReply else { return }
        exchange.answer = Self.readableReply(from: answer)
        if exchange.answer.isEmpty {
            exchange.status = .failed
            exchange.errorMessage = "No reply came through. Try asking again."
        } else {
            exchange.status = .complete
        }
        latestExchange = exchange
    }

    func fail(_ message: String, for exchangeID: UUID) {
        guard var exchange = latestExchange,
              exchange.id == exchangeID, exchange.isReceivingReply else { return }
        exchange.status = .failed
        exchange.errorMessage = message
        latestExchange = exchange
    }

    func interrupt() {
        guard var exchange = latestExchange, exchange.isReceivingReply else { return }
        exchange.status = .interrupted
        latestExchange = exchange
    }

    func clear() {
        latestExchange = nil
        isExpanded = false
    }

    /// Hide control tags even when a stream ends partway through a tag. Ordinary
    /// brackets (array examples, for instance) remain part of the readable reply.
    static func readableReply(from text: String) -> String {
        let controlTagNames = [
            "POINT:", "CIRCLE:", "BOX:", "ARROW:", "UNDERLINE:", "STEP:",
            "VISUAL:", "VISUAL_FOLLOWUP:", "WAIT_FOR_CLICK"
        ]
        let completeTagPattern = #"\[(?:(?:POINT|CIRCLE|BOX|ARROW|UNDERLINE|STEP|VISUAL|VISUAL_FOLLOWUP):[^\]]*|WAIT_FOR_CLICK)\]"#
        var readableText = text.replacingOccurrences(
            of: completeTagPattern, with: "", options: .regularExpression
        )
        if let openingBracket = readableText.lastIndex(of: "["),
           !readableText[openingBracket...].contains("]") {
            let unfinishedTag = String(readableText[readableText.index(after: openingBracket)...])
            if controlTagNames.contains(where: { $0.hasPrefix(unfinishedTag) || unfinishedTag.hasPrefix($0) }) {
                readableText = String(readableText[..<openingBracket])
            }
        }
        return readableText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
