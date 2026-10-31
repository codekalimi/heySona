//
//  StepByStepGuidance.swift
//  leanring-buddy
//
//  Walks the user through multi-step tasks on screen. Claude puts a
//  [STEP:x,y:label] tag right after each step's sentence; as heySona speaks
//  that sentence, the cursor flies to the step's target and a numbered
//  circle appears there. Step timing comes from ElevenLabs character
//  timestamps, so the cursor moves in sync with the voice.
//
//  Tag format (screenshot pixel coordinates, top-left origin):
//    [STEP:x,y:label:screenN]   label and :screenN are optional
//

import Foundation

struct GuidanceStep: Equatable {
    /// 1-based, in the order the steps are spoken.
    let stepNumber: Int
    let label: String?
    /// The display the target is on, in AppKit global coordinates.
    let displayFrame: CGRect
    /// Target in the display's local points (top-left origin), for drawings.
    let displayLocalTargetPoint: CGPoint
    /// Target in AppKit global coordinates (bottom-left origin), for the cursor.
    let globalScreenTargetPoint: CGPoint
    /// Character index in the spoken text where this step's sentence starts.
    /// The step is shown when the voice reaches this character.
    let spokenTextStartCharacterOffset: Int
}

enum StepGuidanceParser {
    static let maximumStepCount = 8

    private static let stepTagPattern =
        #"\[STEP:\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*(?::(?!screen\d+\])([^\]:]+))?(?::screen(\d+))?\]"#

    /// Removes every step tag from `responseText` (so tags are never spoken)
    /// and returns the steps with the spoken-text position each one starts at.
    static func extractSteps(
        from responseText: String,
        screenCaptures: [CompanionScreenCapture]
    ) -> (spokenTextWithoutStepTags: String, steps: [GuidanceStep]) {
        guard let stepTagRegex = try? NSRegularExpression(pattern: stepTagPattern, options: [.caseInsensitive]) else {
            return (responseText, [])
        }
        let tagMatches = stepTagRegex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))
        guard !tagMatches.isEmpty else { return (responseText, []) }

        var spokenText = ""
        var steps: [GuidanceStep] = []
        var textPositionAfterPreviousTag = responseText.startIndex

        // Appends a piece of reply text with single spaces between pieces,
        // and returns where the piece starts in `spokenText`.
        func appendSpokenPiece(_ piece: Substring) -> Int? {
            let trimmedPiece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPiece.isEmpty else { return nil }
            if !spokenText.isEmpty {
                spokenText += " "
            }
            let pieceStartOffset = spokenText.count
            spokenText += trimmedPiece
            return pieceStartOffset
        }

        for tagMatch in tagMatches {
            guard let tagRange = Range(tagMatch.range, in: responseText) else { continue }

            let textBeforeTag = responseText[textPositionAfterPreviousTag..<tagRange.lowerBound]
            let pieceStartOffset = appendSpokenPiece(textBeforeTag) ?? spokenText.count
            textPositionAfterPreviousTag = tagRange.upperBound

            guard steps.count < maximumStepCount else { continue }

            func capturedText(_ groupIndex: Int) -> String? {
                guard let groupRange = Range(tagMatch.range(at: groupIndex), in: responseText) else { return nil }
                let groupText = String(responseText[groupRange]).trimmingCharacters(in: .whitespaces)
                return groupText.isEmpty ? nil : groupText
            }

            guard let xText = capturedText(1), let yText = capturedText(2),
                  let screenshotX = Double(xText), let screenshotY = Double(yText) else { continue }

            // Start the step at its own sentence: the last sentence in the
            // text before the tag, not any untagged sentences ahead of it.
            let pieceText = String(spokenText.dropFirst(pieceStartOffset))
            let stepSentenceStartOffset = pieceStartOffset + startOffsetOfLastSentence(in: pieceText)

            if let guidanceStep = makeGuidanceStep(
                stepNumber: steps.count + 1,
                screenshotPoint: CGPoint(x: screenshotX, y: screenshotY),
                label: capturedText(3),
                screenNumber: capturedText(4).flatMap { Int($0) },
                spokenTextStartCharacterOffset: stepSentenceStartOffset,
                screenCaptures: screenCaptures
            ) {
                steps.append(guidanceStep)
            }
        }

        _ = appendSpokenPiece(responseText[textPositionAfterPreviousTag...])
        return (spokenText, steps)
    }

    /// Offset where the last sentence of `text` begins (0 if it's one sentence).
    private static func startOffsetOfLastSentence(in text: String) -> Int {
        let characters = Array(text)
        // Ignore the closing punctuation of the last sentence itself.
        var searchIndex = characters.count - 2
        while searchIndex > 0 {
            let isSentenceEnd = ".?!".contains(characters[searchIndex]) && characters[searchIndex + 1] == " "
            if isSentenceEnd {
                return searchIndex + 2
            }
            searchIndex -= 1
        }
        return 0
    }

    private static func makeGuidanceStep(
        stepNumber: Int,
        screenshotPoint: CGPoint,
        label: String?,
        screenNumber: Int?,
        spokenTextStartCharacterOffset: Int,
        screenCaptures: [CompanionScreenCapture]
    ) -> GuidanceStep? {
        // Same rule as pointing: the numbered screen, else the cursor's screen.
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber, screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()
        guard let targetScreenCapture else { return nil }

        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)

        let clampedX = max(0, min(screenshotPoint.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPoint.y, screenshotHeight))
        let displayLocalPoint = CGPoint(
            x: clampedX * (displayWidth / screenshotWidth),
            y: clampedY * (displayHeight / screenshotHeight)
        )

        // AppKit global coordinates have a bottom-left origin.
        let displayFrame = targetScreenCapture.displayFrame
        let globalPoint = CGPoint(
            x: displayLocalPoint.x + displayFrame.origin.x,
            y: (displayHeight - displayLocalPoint.y) + displayFrame.origin.y
        )

        return GuidanceStep(
            stepNumber: stepNumber,
            label: label,
            displayFrame: displayFrame,
            displayLocalTargetPoint: displayLocalPoint,
            globalScreenTargetPoint: globalPoint,
            spokenTextStartCharacterOffset: spokenTextStartCharacterOffset
        )
    }

    // MARK: - Timing

    /// When (seconds from the start of playback) each step should appear.
    /// Uses ElevenLabs' per-character start times when they line up with the
    /// spoken text; otherwise estimates from the step's position in the text.
    static func activationTimesInSeconds(
        for steps: [GuidanceStep],
        spokenText: String,
        characterStartTimesInSeconds: [Double]?,
        audioDurationInSeconds: Double
    ) -> [Double] {
        let spokenCharacterCount = max(1, spokenText.count)
        return steps.map { guidanceStep in
            let characterOffset = min(guidanceStep.spokenTextStartCharacterOffset, spokenCharacterCount - 1)
            if let characterStartTimesInSeconds,
               characterStartTimesInSeconds.count == spokenText.count,
               characterOffset < characterStartTimesInSeconds.count {
                return characterStartTimesInSeconds[characterOffset]
            }
            return audioDurationInSeconds * Double(characterOffset) / Double(spokenCharacterCount)
        }
    }

    // MARK: - Prompt

    /// Appended to the system prompt while step-by-step guidance is on.
    static let systemPromptSection = """

    step-by-step guidance:
    when the user asks how to do something that takes two or more steps in what they're looking at, walk them through it one step per sentence, in order, and put a step tag right after each step's sentence: [STEP:x,y:label]. as you say each step, the cursor flies to it and circles it with its number, so the tags must be in the order you say them. use the same pixel coordinates as pointing, with :screenN for another screen, and a 1-3 word label. only tag targets you can see in the screenshot right now. for a step whose target isn't visible yet (like an item inside a menu that's still closed), describe it in its own sentence without a tag. when you use step tags, end with [POINT:none] and don't add drawing tags. never say tags or coordinates out loud.

    example: "first, click the view menu at the top. [STEP:212,12:view menu] then choose show sidebar in the menu that opens. finally, drag the sidebar's edge to make it wider. [STEP:248,400:sidebar edge] [POINT:none]"
    """
}
