//
//  TypeToAskPanelManager.swift
//  leanring-buddy
//
//  A Spotlight-style floating text box for asking heySona a question by
//  typing instead of talking. Opened by double-tapping control, or from the
//  menu bar panel. Enter sends the question, Esc or clicking away closes it.
//

import AppKit
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
                self?.hidePanel()
                onSubmitQuestion(typedQuestion)
            },
            onCancel: { [weak self] in
                self?.hidePanel()
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
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

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

    func hidePanel() {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        typeToAskPanel?.orderOut(nil)
        typeToAskPanel = nil
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
