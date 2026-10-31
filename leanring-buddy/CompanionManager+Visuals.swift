//
//  CompanionManager+Visuals.swift
//  leanring-buddy
//
//  Visual output beyond the cursor: drawings on screen, captions, step-by-step
//  guidance, and visual explanations in the explainer window.
//  Split out of CompanionManager.swift; the state these methods use
//  lives there.
//

import AppKit
import Foundation
import SwiftUI

extension CompanionManager {
    /// Opens the built-in rocket engine demo (Settings > Visuals).
    func showVisualExplainerDemo() {
        stopVisualExplanation()
        visualExplainerPanelManager.showDemoRocketExplanation()
    }

    func startVisualExplanation(brief: String, userQuestion: String) {
        stopVisualExplanation()
        print("🎬 Visual explanation requested: \(brief)")

        let visualExplanationSession = VisualExplanationSession(
            explanationBrief: brief,
            userQuestion: userQuestion,
            claudeAPI: claudeAPI,
            elevenLabsTTSClient: elevenLabsTTSClient,
            explainerPanelManager: visualExplainerPanelManager,
            isNarrationEnabled: isSpokenReplyEnabled
        )
        visualExplanationSession.onSceneFailed = { [weak self] spokenFailureMessage in
            guard let self else { return }
            if self.isSpokenReplyEnabled {
                Task { try? await self.elevenLabsTTSClient.speakText(spokenFailureMessage) }
            } else {
                self.responseOverlayManager.showOverlayAndBeginStreaming()
                self.responseOverlayManager.updateStreamingText(spokenFailureMessage)
                self.responseOverlayManager.finishStreaming()
            }
        }
        // Closing the window stops generation and narration.
        visualExplainerPanelManager.onExplainerClosed = { [weak self] in
            self?.stopVisualExplanation()
        }

        currentVisualExplanationSession = visualExplanationSession
        visualExplanationSession.start()
    }

    func stopVisualExplanation() {
        currentVisualExplanationSession?.stop()
        currentVisualExplanationSession = nil
    }

    /// Plays the reply and shows each step (numbered circle + cursor flight)
    /// as the voice reaches it. With spoken replies off, the text is shown
    /// and the steps advance on a reading-pace timer instead.
    func presentReplyWithStepGuidance(spokenText: String, guidanceSteps: [GuidanceStep]) async {
        var stepActivationTimesInSeconds: [Double]

        if isSpokenReplyEnabled {
            do {
                let timestampedPlayback: (characterStartTimesInSeconds: [Double]?, audioDurationInSeconds: Double)
                do {
                    timestampedPlayback = try await elevenLabsTTSClient.speakTextWithCharacterTimestamps(spokenText)
                } catch is CancellationError {
                    return
                } catch {
                    // Timestamps are a nice-to-have: fall back to plain speech
                    // and estimate step timing from the text.
                    print("⚠️ Timestamped speech failed, estimating step timing: \(error)")
                    try await elevenLabsTTSClient.speakText(spokenText)
                    timestampedPlayback = (nil, elevenLabsTTSClient.currentAudioDurationInSeconds)
                }

                voiceState = .responding
                if isLiveCaptionsEnabled {
                    showCaptionUntilSpeechEnds(captionText: spokenText)
                }
                stepActivationTimesInSeconds = StepGuidanceParser.activationTimesInSeconds(
                    for: guidanceSteps,
                    spokenText: spokenText,
                    characterStartTimesInSeconds: timestampedPlayback.characterStartTimesInSeconds,
                    audioDurationInSeconds: timestampedPlayback.audioDurationInSeconds
                )
            } catch {
                print("⚠️ ElevenLabs TTS error: \(error)")
                speakCreditsErrorFallback()
                return
            }
        } else {
            responseOverlayManager.showOverlayAndBeginStreaming()
            responseOverlayManager.updateStreamingText(spokenText)
            responseOverlayManager.finishStreaming(afterDelayInSeconds: 6 + Double(guidanceSteps.count) * 3)
            let secondsBetweenStepsWhenReading = 3.0
            stepActivationTimesInSeconds = guidanceSteps.indices.map { stepIndex in
                0.4 + Double(stepIndex) * secondsBetweenStepsWhenReading
            }
        }

        print("🪜 Guiding through \(guidanceSteps.count) step(s) at \(stepActivationTimesInSeconds.map { String(format: "%.1fs", $0) })")
        isGuidingThroughSteps = true
        stepGuidanceTask?.cancel()
        let playbackStartDate = Date()

        stepGuidanceTask = Task { [weak self] in
            for (guidanceStep, activationTimeInSeconds) in zip(guidanceSteps, stepActivationTimesInSeconds) {
                let secondsUntilActivation = activationTimeInSeconds - Date().timeIntervalSince(playbackStartDate)
                if secondsUntilActivation > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(secondsUntilActivation * 1_000_000_000))
                }
                guard !Task.isCancelled, let self else { return }
                self.showGuidanceStep(guidanceStep)
            }

            // Keep the cursor on the last step until the voice finishes.
            while self?.elevenLabsTTSClient.isPlaying == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.isGuidingThroughSteps = false
            // Step circles are added after the reply starts, so the fade-out
            // is scheduled here, once the last step has been shown.
            self?.scheduleScreenDrawingsFadeOut()
        }
    }

    /// Circles the step's target with its number and flies the cursor there.
    func showGuidanceStep(_ guidanceStep: GuidanceStep) {
        let stepLabelText = guidanceStep.label.map { "\(guidanceStep.stepNumber) · \($0)" } ?? "\(guidanceStep.stepNumber)"

        screenDrawingsFadeOutTask?.cancel()
        screenDrawings.append(ScreenDrawing(
            shape: .circle(center: guidanceStep.displayLocalTargetPoint, radius: 22),
            label: stepLabelText,
            displayFrame: guidanceStep.displayFrame,
            drawingOrder: 0
        ))

        // The bubble text and display frame must be set before the location,
        // since the overlay starts the flight when the location changes.
        detectedElementBubbleText = stepLabelText
        detectedElementDisplayFrame = guidanceStep.displayFrame
        detectedElementScreenLocation = guidanceStep.globalScreenTargetPoint
        print("🪜 Step \(guidanceStep.stepNumber): \(guidanceStep.label ?? "unlabeled")")
    }

    func stopStepGuidance() {
        stepGuidanceTask?.cancel()
        stepGuidanceTask = nil
        isGuidingThroughSteps = false
    }

    func showScreenDrawings(_ drawingsToShow: [ScreenDrawing]) {
        screenDrawingsFadeOutTask?.cancel()
        screenDrawings = drawingsToShow
        print("✏️ Drawing \(drawingsToShow.count) annotation(s) on screen")
    }

    func clearScreenDrawings() {
        screenDrawingsFadeOutTask?.cancel()
        screenDrawingsFadeOutTask = nil
        guard !screenDrawings.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            screenDrawings = []
        }
    }

    /// Keeps drawings up while the reply is spoken (or read, when muted),
    /// then fades them out so they don't linger over the user's work.
    func scheduleScreenDrawingsFadeOut() {
        guard !screenDrawings.isEmpty else { return }
        screenDrawingsFadeOutTask?.cancel()
        screenDrawingsFadeOutTask = Task { [weak self] in
            while self?.elevenLabsTTSClient.isPlaying == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            // Text-only replies need longer, since they're being read.
            let secondsToKeepDrawingsAfterReply: UInt64 = self?.isSpokenReplyEnabled == true ? 4 : 8
            try? await Task.sleep(nanoseconds: secondsToKeepDrawingsAfterReply * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                self.screenDrawings = []
            }
        }
    }

    /// Shows the spoken reply as a caption next to the cursor and hides it
    /// shortly after the audio finishes.
    func showCaptionUntilSpeechEnds(captionText: String) {
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(captionText)

        captionHideTask?.cancel()
        captionHideTask = Task { [weak self] in
            while self?.elevenLabsTTSClient.isPlaying == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            self?.responseOverlayManager.finishStreaming(afterDelayInSeconds: 1.5)
        }
    }

    func hideCaptionAndBubble() {
        captionHideTask?.cancel()
        captionHideTask = nil
        responseOverlayManager.hideOverlay()
    }
}
