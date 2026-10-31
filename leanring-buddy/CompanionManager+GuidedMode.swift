//
//  CompanionManager+GuidedMode.swift
//  leanring-buddy
//
//  Guided mode: for tasks that continue past what's on screen now (the next
//  control is inside a menu or dialog that only appears after a click),
//  Claude guides the visible steps and ends with [WAIT_FOR_CLICK]. heySona
//  then waits for the user's click, takes a fresh screenshot, and asks
//  Claude for the next step, until the task is done.
//
//  Limits: at most 10 rounds per task, 3 minutes waiting for a click, and
//  Esc or a new question stops it. The state lives in CompanionManager.swift.
//

import AppKit
import Foundation
import SwiftUI

extension CompanionManager {
    static let waitForClickTag = "[WAIT_FOR_CLICK]"
    static let maximumGuidedModeRounds = 10
    static let guidedModeClickTimeoutInSeconds: UInt64 = 180

    /// Appended to the system prompt while guided mode and step-by-step
    /// guidance are both on.
    static let guidedModeSystemPromptSection = """

    guided mode:
    when a task continues past what's visible right now (the next control is inside a menu, panel, or dialog that will only appear after the user clicks), guide only the steps you can see now, then end your reply with [WAIT_FOR_CLICK] (before the [POINT:...] tag). heySona will wait for the user's click, take a new screenshot, and send it to you so you can show the next step. keep each turn short: one or two steps. when the whole task is done, say so in a few words and don't add the tag. never add it for questions that aren't a task the user is doing on screen.
    """

    /// Removes every [WAIT_FOR_CLICK] tag and reports whether there was one.
    static func removeWaitForClickTag(from responseText: String) -> (textWithoutTag: String, didRequestWaitForClick: Bool) {
        guard responseText.range(of: waitForClickTag, options: .caseInsensitive) != nil else {
            return (responseText, false)
        }
        let textWithoutTag = responseText
            .replacingOccurrences(of: waitForClickTag, with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (textWithoutTag, true)
    }

    // MARK: - Waiting For The Click

    /// Called after a guided reply finishes. With spoken replies off, pass the
    /// reply so it stays readable above the waiting hint.
    func startWaitingForGuidedModeClick(replyTextToKeepVisible: String? = nil) {
        guard guidedModeRoundCount < Self.maximumGuidedModeRounds else {
            print("🧭 Guided mode: reached \(Self.maximumGuidedModeRounds) rounds, stopping")
            stopGuidedMode()
            return
        }

        isWaitingForGuidedModeClick = true
        print("🧭 Guided mode: waiting for the user's click (round \(guidedModeRoundCount + 1))")

        // A persistent hint by the cursor, so it's clear heySona is waiting.
        let waitingHint = "Do that, then I'll show you the next step. Esc to stop."
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(
            replyTextToKeepVisible.map { $0 + "\n\n" + waitingHint } ?? waitingHint
        )

        // Listen a moment later so a click already in progress doesn't count.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isWaitingForGuidedModeClick, self.guidedModeClickMonitor == nil else { return }
            // Global monitors see clicks in other apps (not heySona's own
            // windows), which is exactly where the user does the step.
            self.guidedModeClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleGuidedModeClick()
                }
            }
        }

        guidedModeTimeoutTask?.cancel()
        guidedModeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.guidedModeClickTimeoutInSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isWaitingForGuidedModeClick else { return }
            print("🧭 Guided mode: no click for \(Self.guidedModeClickTimeoutInSeconds) seconds, stopping")
            self.stopGuidedMode()
            self.scheduleScreenDrawingsFadeOut()
        }
    }

    private func handleGuidedModeClick() {
        guard isWaitingForGuidedModeClick else { return }
        removeGuidedModeWaitingState()

        // Give the app a moment to react (open the menu, show the dialog)
        // before taking the next screenshot.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.guidedTaskQuestion != nil else { return }
            self.continueGuidedTask()
        }
    }

    private func continueGuidedTask() {
        guard let guidedTaskQuestion else { return }
        guidedModeRoundCount += 1

        // Same cleanup as a new question, without ending guided mode.
        isContinuingGuidedTask = true
        prepareForNewInteraction()
        isContinuingGuidedTask = false

        let continuationMessage = """
        (guided mode) I did the step you showed me. Here's my screen now. Keep guiding me, one visible step at a time, through my original request: "\(guidedTaskQuestion)". If the task is complete, say so briefly and don't add [WAIT_FOR_CLICK].
        """
        print("🧭 Guided mode: continuing (round \(guidedModeRoundCount + 1))")
        sendTranscriptToClaudeWithScreenshot(transcript: continuationMessage)
    }

    // MARK: - Stopping

    /// Ends guided mode (task finished, Esc, a new question, or a limit).
    func stopGuidedMode() {
        let wasWaiting = isWaitingForGuidedModeClick
        removeGuidedModeWaitingState()
        guidedTaskQuestion = nil
        guidedModeRoundCount = 0
        if wasWaiting {
            responseOverlayManager.hideOverlay()
        }
    }

    private func removeGuidedModeWaitingState() {
        isWaitingForGuidedModeClick = false
        if let guidedModeClickMonitor {
            NSEvent.removeMonitor(guidedModeClickMonitor)
            self.guidedModeClickMonitor = nil
        }
        guidedModeTimeoutTask?.cancel()
        guidedModeTimeoutTask = nil
        responseOverlayManager.hideOverlay()
    }
}
