//
//  CompanionManager+Shortcuts.swift
//  leanring-buddy
//
//  Type-to-ask (double-tap control) and Esc to stop a reply.
//  Split out of CompanionManager.swift; the state these methods use
//  lives there.
//

import AppKit
import Carbon
import Combine
import Foundation
import SwiftUI

extension CompanionManager {
    /// Control tapped twice, detected by the same listen-only event tap as
    /// push-to-talk (a modifier-only shortcut can't be a Carbon hot key).
    func bindTypeToAskDoubleTap() {
        guard typeToAskDoubleTapCancellable == nil else { return }
        typeToAskDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .typeToAskDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.toggleTypeToAskPanel()
            }
    }

    func toggleTypeToAskPanel() {
        if typeToAskPanelManager.isPanelVisible {
            typeToAskPanelManager.hidePanel(returningFocusToPreviousApp: true)
        } else {
            openTypeToAskPanel()
        }
    }

    /// Opens the Spotlight-style text box. Also used by the menu bar panel's
    /// "Type a question" button.
    func openTypeToAskPanel() {
        // Same conditions as push-to-talk: setup must be finished and the
        // onboarding video must not be playing.
        guard hasCompletedOnboarding && allPermissionsGranted else {
            print("⚠️ Type to ask: finish setup in the menu bar panel first")
            return
        }
        guard !showOnboardingVideo else { return }

        NotificationCenter.default.post(name: .heySonaDismissPanel, object: nil)

        typeToAskPanelManager.showPanel(onSubmitQuestion: { [weak self] typedQuestion in
            self?.submitTypedQuestion(typedQuestion)
        })
    }

    func submitTypedQuestion(_ typedQuestion: String, presentInMenuBar: Bool = false) {
        guard !buddyDictationManager.isDictationInProgress else { return }

        prepareForNewInteraction()

        lastTranscript = typedQuestion
        print("⌨️ Companion received typed question: \(typedQuestion)")
        sendTranscriptToClaudeWithScreenshot(transcript: typedQuestion, presentInMenuBar: presentInMenuBar)
    }

    /// Stops the current reply right away: cancels the Claude request if it's
    /// still running, cuts off speech, and hides the text bubble. Triggered by
    /// Esc while a reply is in progress.
    func stopCurrentResponse() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentStreamingReplySpeaker?.cancel()
        panelConversation.interrupt()
        stopGuidedMode()
        elevenLabsTTSClient.stopPlayback()
        hideCaptionAndBubble()
        stopStepGuidance()
        stopVisualExplanation()
        clearScreenDrawings()
        clearDetectedElementLocation()

        if voiceState != .listening {
            voiceState = .idle
        }

        disarmEscapeToStop()
        scheduleTransientHideIfNeeded()
        print("⏹️ Companion response stopped by user")
    }

    /// Registers Esc as a stop key until the current reply has finished
    /// generating and speaking. Must be called after `currentResponseTask`
    /// is assigned so it waits on the right task.
    func armEscapeToStopUntilResponseFinishes() {
        if escapeToStopHotKey == nil {
            escapeToStopHotKey = globalHotKeyRegistrar.register(
                carbonKeyCode: kVK_Escape,
                carbonModifierFlags: 0,
                action: { [weak self] in
                    self?.stopCurrentResponse()
                }
            )
        }

        escapeToStopReleaseTask?.cancel()
        let responseTaskToWaitFor = currentResponseTask
        escapeToStopReleaseTask = Task { [weak self] in
            await responseTaskToWaitFor?.value

            // speakText returns as soon as playback starts, so also wait
            // for the audio itself to finish.
            // Also stay armed while guided mode waits for a click, so Esc
            // can end it.
            while self?.elevenLabsTTSClient.isPlaying == true || self?.isWaitingForGuidedModeClick == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            guard !Task.isCancelled else { return }
            self?.disarmEscapeToStop()
        }
    }

    func disarmEscapeToStop() {
        escapeToStopReleaseTask?.cancel()
        escapeToStopReleaseTask = nil
        if let escapeToStopHotKey {
            globalHotKeyRegistrar.unregister(escapeToStopHotKey)
            self.escapeToStopHotKey = nil
        }
    }
}
