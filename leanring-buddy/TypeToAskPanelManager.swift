//
//  TypeToAskPanelManager.swift
//  leanring-buddy
//
//  A Spotlight-style floating text box for asking heySona a question by
//  typing instead of talking. Opened by double-tapping control, or from the
//  menu bar panel. Enter sends the question, Esc or clicking away closes it.
//
//  Typing must work right away, without clicking the box, so opening makes
//  heySona the front app and Enter or Esc gives focus back to the app the
//  user was in (before the screenshot). macOS only lets an app take focus
//  after the user interacted with it, and a double-tap seen by the
//  listen-only event tap doesn't count, so focus is moved through the
//  Accessibility API (heySona already has that permission for push-to-talk),
//  with the regular activation request as a fallback.
//

import AppKit
import ApplicationServices
import SwiftUI

/// Borderless panels can't become key by default, which would stop the
/// text field from receiving keystrokes.
private class TypeToAskKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class TypeToAskPanelManager {
    private var typeToAskPanel: NSPanel?
    private var resignKeyObserver: NSObjectProtocol?
    /// The app the user was in when the box opened, to give focus back to.
    private var applicationActiveBeforePanel: NSRunningApplication?
    /// How long to let that app come back to the front before the question
    /// is sent, so the screenshot and "app in front" describe it.
    private static let focusReturnDelaySeconds: TimeInterval = 0.15

    private let panelWidth: CGFloat = 560

    var isPanelVisible: Bool {
        typeToAskPanel?.isVisible ?? false
    }

    /// Opens the text box on the screen the mouse is on. `onSubmitQuestion`
    /// receives the trimmed question after the panel has closed.
    func showPanel(onSubmitQuestion: @escaping (String) -> Void) {
        hidePanel()

        let typeToAskView = TypeToAskView(
            onSubmitQuestion: { [weak self] typedQuestion in
                guard let self else { return }
                self.hidePanel(returningFocusToPreviousApp: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusReturnDelaySeconds) {
                    onSubmitQuestion(typedQuestion)
                }
            },
            onCancel: { [weak self] in
                self?.hidePanel(returningFocusToPreviousApp: true)
            }
        )

        let hostingView = NSHostingView(rootView: typeToAskView)
        // Size the panel to the SwiftUI content so there's no empty margin.
        let panelHeight = hostingView.fittingSize.height
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = TypeToAskKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            // Non-activating so the app the user is looking at stays in front
            // and remains the "primary focus" in the screenshot Claude sees.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window server draws the shadow around the rounded content, which
        // avoids a SwiftUI shadow being clipped at the panel's edges.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        positionPanelOnScreenWithMouse(panel, panelHeight: panelHeight)

        // Remember the user's app, then take the keyboard so typing lands in
        // the box immediately.
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            applicationActiveBeforePanel = frontmostApplication
        }
        Self.bringApplicationToFront(NSRunningApplication.current)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        focusQuestionField(in: panel)

        // Clicking anywhere else takes key status away from the panel;
        // treat that as cancelling, like Spotlight does.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hidePanel()
            }
        }

        typeToAskPanel = panel
    }

    /// `returningFocusToPreviousApp` is true for Enter and Esc. Clicking
    /// away leaves focus wherever the user clicked.
    func hidePanel(returningFocusToPreviousApp: Bool = false) {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        let wasPanelVisible = typeToAskPanel?.isVisible ?? false
        typeToAskPanel?.orderOut(nil)
        typeToAskPanel = nil

        if returningFocusToPreviousApp, wasPanelVisible,
           let applicationActiveBeforePanel, !applicationActiveBeforePanel.isTerminated {
            NSApp.yieldActivation(to: applicationActiveBeforePanel)
            Self.bringApplicationToFront(applicationActiveBeforePanel)
        }
        applicationActiveBeforePanel = nil
    }

    /// Makes `application` the front app. Accessibility's "frontmost"
    /// attribute works even when macOS would decline a normal activation
    /// request; the request is still made in case Accessibility is off.
    static func bringApplicationToFront(_ application: NSRunningApplication) {
        if AXIsProcessTrusted() {
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
            let accessibilityResult = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            )
            if accessibilityResult != .success {
                print("⚠️ Type to ask: couldn't bring \(application.localizedName ?? "app") to the front (\(accessibilityResult.rawValue))")
            }
        }
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSApp.activate()
        } else {
            application.activate()
        }
    }

    /// Puts the cursor in the text field. SwiftUI's own focus request can run
    /// before the panel is key, so the AppKit text field is also focused
    /// directly once the panel is on screen.
    private func focusQuestionField(in panel: NSPanel) {
        DispatchQueue.main.async {
            guard panel.isVisible, let questionTextField = Self.firstTextField(in: panel.contentView) else { return }
            panel.makeFirstResponder(questionTextField)
        }
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let textField = view as? NSTextField, textField.isEditable { return textField }
        for subview in view.subviews {
            if let textField = firstTextField(in: subview) { return textField }
        }
        return nil
    }

    /// Places the panel horizontally centered, about a quarter of the way down
    /// the screen the mouse is on — where Spotlight appears.
    private func positionPanelOnScreenWithMouse(_ panel: NSPanel, panelHeight: CGFloat) {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        guard let visibleFrame = screenWithMouse?.visibleFrame else { return }

        let panelOriginX = visibleFrame.midX - (panelWidth / 2)
        let panelOriginY = visibleFrame.maxY - (visibleFrame.height * 0.25) - panelHeight

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
            display: true
        )
    }
}

private struct TypeToAskView: View {
    let onSubmitQuestion: (String) -> Void
    let onCancel: () -> Void

    @State private var typedQuestion: String = ""
    @FocusState private var isQuestionFieldFocused: Bool

    private var trimmedTypedQuestion: String {
        typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)

                TextField("Ask heySona about your screen…", text: $typedQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isQuestionFieldFocused)
                    .onSubmit {
                        guard !trimmedTypedQuestion.isEmpty else { return }
                        onSubmitQuestion(trimmedTypedQuestion)
                    }
            }

            Text("Enter to ask · Esc to close")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.leading, 25)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .onExitCommand(perform: onCancel)
        .onAppear {
            isQuestionFieldFocused = true
        }
    }
}
