//
//  StreamingSpeech.swift
//  leanring-buddy
//
//  Speaks Claude's reply while it's still being written, instead of waiting
//  for the whole reply. SpokenTextStreamSegmenter cuts the streaming text
//  into sentences (and pulls out [TAG:...] tags as they complete);
//  StreamingSpeechPlayer turns each sentence into audio with ElevenLabs and
//  plays them back to back, preparing the next sentence while the current
//  one plays.
//

import Foundation

// MARK: - Segmenter

enum SpokenTextStreamEvent {
    /// A sentence (or a few short ones) ready to be spoken.
    case speech(String)
    /// A complete [TAG:...] including the brackets.
    case tag(String)
}

/// Turns ever-growing streamed text into speech segments and tags, each
/// returned exactly once and in order.
@MainActor
final class SpokenTextStreamSegmenter {
    private var consumedCharacterCount = 0
    private var hasEmittedFirstSpeech = false
    /// A short sentence held back so it can be spoken together with the
    /// next one (fewer, more natural-sounding audio clips).
    private var heldBackShortSpeech = ""

    /// Short sentences after the first are merged until a segment reaches
    /// this length. The first sentence always goes out right away.
    private static let preferredMinimumSegmentLength = 50

    /// Call with the full text received so far.
    func newEvents(in accumulatedText: String) -> [SpokenTextStreamEvent] {
        segment(accumulatedText, isStreamFinished: false)
    }

    /// Call once with the final text; returns whatever is left.
    func finalEvents(in fullText: String) -> [SpokenTextStreamEvent] {
        segment(fullText, isStreamFinished: true)
    }

    private func segment(_ accumulatedText: String, isStreamFinished: Bool) -> [SpokenTextStreamEvent] {
        let characters = Array(accumulatedText)
        var events: [SpokenTextStreamEvent] = []
        var position = consumedCharacterCount

        func emitSpeech(_ speechText: String, isFollowedByTag: Bool) {
            let trimmedSpeechText = speechText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSpeechText.isEmpty || !heldBackShortSpeech.isEmpty else { return }
            // A sentence followed by a tag (often a step) is spoken on its
            // own, so whatever the tag triggers lines up with that sentence.
            if isFollowedByTag && !heldBackShortSpeech.isEmpty && !trimmedSpeechText.isEmpty {
                events.append(.speech(heldBackShortSpeech))
                heldBackShortSpeech = ""
            }
            let combinedSpeechText = [heldBackShortSpeech, trimmedSpeechText]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let shouldHoldBack = hasEmittedFirstSpeech
                && !isFollowedByTag
                && !isStreamFinished
                && combinedSpeechText.count < Self.preferredMinimumSegmentLength
            if shouldHoldBack {
                heldBackShortSpeech = combinedSpeechText
                return
            }
            heldBackShortSpeech = ""
            hasEmittedFirstSpeech = true
            events.append(.speech(combinedSpeechText))
        }

        scanning: while position < characters.count {
            // Skip whitespace between pieces.
            if characters[position].isWhitespace {
                position += 1
                continue
            }

            // A tag: wait until its closing bracket has arrived.
            if characters[position] == "[" {
                guard let closingBracketIndex = characters[position...].firstIndex(of: "]") else {
                    if isStreamFinished {
                        position = characters.count
                    }
                    break scanning
                }
                // A step tag belongs to the sentence before it, so any
                // held-back text is spoken first.
                emitSpeech("", isFollowedByTag: true)
                events.append(.tag(String(characters[position...closingBracketIndex])))
                position = closingBracketIndex + 1
                continue
            }

            // Speech: up to the end of a sentence or the start of a tag.
            var scanIndex = position
            var speechEndIndex: Int?
            var isFollowedByTag = false
            while scanIndex < characters.count {
                let character = characters[scanIndex]
                if character == "[" {
                    speechEndIndex = scanIndex
                    isFollowedByTag = true
                    break
                }
                let isSentenceEnd = ".!?".contains(character)
                    && scanIndex + 1 < characters.count
                    && characters[scanIndex + 1].isWhitespace
                if isSentenceEnd {
                    // Look past the whitespace: is a tag next? If the text
                    // hasn't arrived yet, wait for it (unless the stream ended).
                    var lookAheadIndex = scanIndex + 1
                    while lookAheadIndex < characters.count && characters[lookAheadIndex].isWhitespace {
                        lookAheadIndex += 1
                    }
                    if lookAheadIndex >= characters.count && !isStreamFinished {
                        break
                    }
                    isFollowedByTag = lookAheadIndex < characters.count && characters[lookAheadIndex] == "["
                    speechEndIndex = scanIndex + 1
                    break
                }
                scanIndex += 1
            }

            guard let speechEndIndex else {
                if isStreamFinished {
                    emitSpeech(String(characters[position...]), isFollowedByTag: false)
                    position = characters.count
                }
                break scanning
            }

            emitSpeech(String(characters[position..<speechEndIndex]), isFollowedByTag: isFollowedByTag)
            position = speechEndIndex
        }

        if isStreamFinished {
            emitSpeech("", isFollowedByTag: false)
        }
        consumedCharacterCount = position
        return events
    }
}

// MARK: - Player

/// Plays speech segments in order as they're added. Audio for upcoming
/// segments is prepared ahead (at most two at once, to stay within
/// ElevenLabs' concurrency limits).
@MainActor
final class StreamingSpeechPlayer {
    private struct QueuedSpeechSegment {
        let text: String
        let onStartPlaying: (() -> Void)?
    }

    private let elevenLabsTTSClient: ElevenLabsTTSClient
    private var queuedSpeechSegments: [QueuedSpeechSegment] = []
    private var audioPreparationTasks: [Int: Task<Data?, Never>] = [:]
    private var isInputFinished = false
    private var isCancelled = false
    private var playbackTask: Task<Void, Never>?

    private(set) var playedSegmentCount = 0
    private(set) var failedSegmentCount = 0

    /// Called once, when the first segment starts playing.
    var onFirstAudioStarted: (() -> Void)?

    init(elevenLabsTTSClient: ElevenLabsTTSClient) {
        self.elevenLabsTTSClient = elevenLabsTTSClient
    }

    /// `onStartPlaying` runs when this segment's audio begins (used to show
    /// step-by-step guidance and captions in sync with the voice).
    func appendSpeechSegment(_ speechText: String, onStartPlaying: (() -> Void)? = nil) {
        guard !isCancelled else { return }
        queuedSpeechSegments.append(QueuedSpeechSegment(text: speechText, onStartPlaying: onStartPlaying))
        if playbackTask == nil {
            playbackTask = Task { [weak self] in
                await self?.playSegmentsInOrder()
            }
        }
    }

    /// Runs `action` when the most recently added segment starts playing,
    /// or right away if nothing has been added yet.
    func attachToLatestSegment(_ action: @escaping () -> Void) {
        guard let latestSegmentIndex = queuedSpeechSegments.indices.last else {
            action()
            return
        }
        let latestSegment = queuedSpeechSegments[latestSegmentIndex]
        let previousAction = latestSegment.onStartPlaying
        // Once a segment is playing, its start has passed; run immediately.
        if latestSegmentIndex < playedSegmentCount + failedSegmentCount {
            action()
            return
        }
        queuedSpeechSegments[latestSegmentIndex] = QueuedSpeechSegment(text: latestSegment.text) {
            previousAction?()
            action()
        }
    }

    /// No more segments will be added.
    func finishInput() {
        isInputFinished = true
        if playbackTask == nil {
            playbackTask = Task { [weak self] in
                await self?.playSegmentsInOrder()
            }
        }
    }

    /// Returns when every segment has played (or playback was cancelled).
    func waitUntilFinished() async {
        await playbackTask?.value
    }

    func cancel() {
        isCancelled = true
        playbackTask?.cancel()
        audioPreparationTasks.values.forEach { $0.cancel() }
        elevenLabsTTSClient.stopPlayback()
    }

    private func playSegmentsInOrder() async {
        var segmentIndex = 0
        while !isCancelled && !Task.isCancelled {
            // Wait for the next segment to be added, or for input to end.
            while segmentIndex >= queuedSpeechSegments.count && !isInputFinished {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if isCancelled || Task.isCancelled { return }
            }
            guard segmentIndex < queuedSpeechSegments.count else { return }

            prepareAudio(forSegmentIndex: segmentIndex)
            prepareAudio(forSegmentIndex: segmentIndex + 1)

            let segmentAudio = await audioPreparationTasks[segmentIndex]?.value
            if isCancelled || Task.isCancelled { return }

            let segment = queuedSpeechSegments[segmentIndex]
            if let segmentAudio, (try? elevenLabsTTSClient.playSpeechAudio(segmentAudio)) != nil {
                if playedSegmentCount == 0 {
                    onFirstAudioStarted?()
                }
                playedSegmentCount += 1
                segment.onStartPlaying?()
                // Prepare one further ahead while this segment plays.
                prepareAudio(forSegmentIndex: segmentIndex + 2)
                while elevenLabsTTSClient.isPlaying {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if isCancelled || Task.isCancelled { return }
                }
            } else {
                failedSegmentCount += 1
                print("⚠️ Streaming speech: couldn't voice a segment, skipping it")
                segment.onStartPlaying?()
            }
            audioPreparationTasks[segmentIndex] = nil
            segmentIndex += 1
        }
    }

    private func prepareAudio(forSegmentIndex segmentIndex: Int) {
        guard segmentIndex < queuedSpeechSegments.count,
              audioPreparationTasks[segmentIndex] == nil else { return }
        let segmentText = queuedSpeechSegments[segmentIndex].text
        audioPreparationTasks[segmentIndex] = Task { [elevenLabsTTSClient] in
            try? await elevenLabsTTSClient.synthesizeSpeechAudio(segmentText)
        }
    }
}

// MARK: - Reply Speaker

/// Speaks one streaming reply: feeds text into the segmenter, queues each
/// sentence on the player, and fires step-by-step guidance and captions
/// when the matching sentence starts playing.
@MainActor
final class StreamingReplySpeaker {
    private let segmenter = SpokenTextStreamSegmenter()
    private let player: StreamingSpeechPlayer
    private let screenCaptures: [CompanionScreenCapture]
    private let isStepGuidanceEnabled: Bool

    /// Number of [STEP] tags turned into guidance steps so far.
    private(set) var guidanceStepCount = 0

    /// A sentence started playing (for captions).
    var onSegmentStarted: ((_ segmentText: String) -> Void)?
    /// The voice reached a step's sentence.
    var onGuidanceStepReached: ((_ guidanceStep: GuidanceStep) -> Void)?
    /// The voice reached the sentence a drawing tag follows, so the circle,
    /// box, arrow, or underline appears on the real screen as it's spoken.
    var onDrawingReached: ((_ screenDrawing: ScreenDrawing) -> Void)?
    /// Number of drawing tags handled while speaking; when above zero the
    /// reply's drawings must not be drawn again at the end.
    private(set) var liveDrawingCount = 0
    private let isLiveDrawingEnabled: Bool
    var onFirstAudioStarted: (() -> Void)? {
        get { player.onFirstAudioStarted }
        set { player.onFirstAudioStarted = newValue }
    }

    /// True once at least one sentence was actually voiced.
    var didSpeakAnything: Bool { player.playedSegmentCount > 0 }

    init(
        elevenLabsTTSClient: ElevenLabsTTSClient,
        screenCaptures: [CompanionScreenCapture],
        isStepGuidanceEnabled: Bool,
        isLiveDrawingEnabled: Bool = false
    ) {
        self.player = StreamingSpeechPlayer(elevenLabsTTSClient: elevenLabsTTSClient)
        self.screenCaptures = screenCaptures
        self.isStepGuidanceEnabled = isStepGuidanceEnabled
        self.isLiveDrawingEnabled = isLiveDrawingEnabled
    }

    /// Call with the full text received so far, as it streams.
    func receive(accumulatedText: String) {
        handle(segmenter.newEvents(in: accumulatedText))
    }

    /// Call once with the complete reply; speaks whatever is left.
    func finish(fullText: String) {
        handle(segmenter.finalEvents(in: fullText))
        player.finishInput()
    }

    func waitUntilFinished() async {
        await player.waitUntilFinished()
    }

    func cancel() {
        player.cancel()
    }

    private func handle(_ streamEvents: [SpokenTextStreamEvent]) {
        for streamEvent in streamEvents {
            switch streamEvent {
            case .speech(let segmentText):
                player.appendSpeechSegment(segmentText) { [weak self] in
                    self?.onSegmentStarted?(segmentText)
                }
            case .tag(let tagText):
                // Drawing tags appear with the sentence before them.
                let uppercasedTagText = tagText.uppercased()
                if isLiveDrawingEnabled,
                   ["[CIRCLE:", "[BOX:", "[ARROW:", "[UNDERLINE:"].contains(where: { uppercasedTagText.hasPrefix($0) }) {
                    if let liveDrawing = ScreenDrawingTagParser.extractDrawings(from: tagText, screenCaptures: screenCaptures).drawings.first {
                        liveDrawingCount += 1
                        player.attachToLatestSegment { [weak self] in
                            self?.onDrawingReached?(liveDrawing)
                        }
                    }
                    continue
                }
                // Steps also play with their sentence; [POINT] and [VISUAL]
                // are handled once the reply ends.
                guard isStepGuidanceEnabled, uppercasedTagText.hasPrefix("[STEP:"),
                      let parsedStep = StepGuidanceParser.extractSteps(from: tagText, screenCaptures: screenCaptures).steps.first else {
                    continue
                }
                guidanceStepCount += 1
                let numberedStep = GuidanceStep(
                    stepNumber: guidanceStepCount,
                    label: parsedStep.label,
                    displayFrame: parsedStep.displayFrame,
                    displayLocalTargetPoint: parsedStep.displayLocalTargetPoint,
                    globalScreenTargetPoint: parsedStep.globalScreenTargetPoint,
                    spokenTextStartCharacterOffset: 0
                )
                player.attachToLatestSegment { [weak self] in
                    self?.onGuidanceStepReached?(numberedStep)
                }
            }
        }
    }
}
