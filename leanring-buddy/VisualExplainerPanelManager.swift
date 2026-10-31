//
//  VisualExplainerPanelManager.swift
//  leanring-buddy
//
//  Floating window for visual explanations: an animated 3D or 2D scene,
//  explained step by step. The scene is drawn by a bundled web page
//  (VisualExplainer.bundle/visual-explainer.html + three.js) inside a WKWebView;
//  this class owns the window and talks to the page.
//
//  Scenes are data (shapes, labels, arrows, flows, camera moves), never
//  code, so nothing Claude writes is executed. See the top of
//  visual-explainer.js for the scene format.
//

import AppKit
import ApplicationServices
import SwiftUI
import WebKit

/// Where the explainer window appears.
enum ExplainerPlacement {
    /// The full explainer, centered on the screen with the mouse.
    case centered
    /// A compact diagram beside the app the user is looking at ([VISUAL_DOCK]).
    case dockedBesideFrontWindow
}

@MainActor
final class VisualExplainerPanelManager: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    private var explainerPanel: NSPanel?
    private var explainerWebView: WKWebView?

    /// The page posts "ready" once its renderer is set up; commands sent
    /// before then wait here and run in order.
    private var isRendererReady = false
    private var scriptsWaitingForRenderer: [String] = []

    /// Name the page uses for `window.webkit.messageHandlers.<name>`.
    private static let messageHandlerName = "heySona"
    /// The page, its script, three.js, and the demo scene live in a
    /// `.bundle` folder so Xcode copies them into the app as-is. Loose
    /// `.js` files would be treated as source code and left out.
    private static let explainerResourceBundleName = "VisualExplainer"

    /// Called when a step starts, with its index and narration (used to
    /// sync the voice in phase 2).
    var onStepStarted: ((_ stepIndex: Int, _ narration: String) -> Void)?
    /// The user pressed play/pause in the window.
    var onPlayPauseRequested: ((_ isPlaying: Bool) -> Void)?
    /// The user opened the library, picked an entry, or deleted one.
    var onLibraryRequested: (() -> Void)?
    var onLibraryEntrySelected: ((_ explanationID: String) -> Void)?
    var onLibraryEntryDeleted: ((_ explanationID: String) -> Void)?
    /// The user pressed the Map button.
    var onConceptMapRequested: (() -> Void)?
    /// The renderer's layout self-check found (and maybe fixed) problems in a step.
    var onStepIssuesReported: ((_ stepIndex: Int, _ issues: [String]) -> Void)?
    var onExplainerClosed: (() -> Void)?

    var isExplainerVisible: Bool {
        explainerPanel?.isVisible ?? false
    }

    // MARK: - Showing Scenes

    /// Opens the built-in rocket engine demo, which plays on its own.
    func showDemoRocketExplanation() {
        guard let demoSceneURL = Self.bundledResourceURL(named: "visual-explainer-demo-rocket", withExtension: "json"),
              let demoSceneJSON = try? String(contentsOf: demoSceneURL, encoding: .utf8) else {
            print("⚠️ Visual explainer: demo scene is missing from the app bundle")
            return
        }
        showScene(sceneJSON: demoSceneJSON, autoAdvance: true)
    }

    /// Opens the window with a status message while a scene is prepared.
    func showPreparingStatus(_ statusText: String) {
        bringPanelToFront()
        evaluateRendererScript("heySonaExplainer.showStatus(\(Self.javaScriptStringLiteral(statusText)))")
    }

    /// Shows a scene. With `autoAdvance` the page moves through steps on its
    /// own timing; otherwise the caller drives steps with `goToStep`. With
    /// `stepsStillStreaming`, more steps arrive later through `appendStep`.
    func showScene(sceneJSON: String, autoAdvance: Bool, stepsStillStreaming: Bool = false) {
        // Only well-formed JSON objects are ever passed to the page.
        guard Self.isJSONObject(sceneJSON) else {
            print("⚠️ Visual explainer: scene is not a valid JSON object")
            return
        }
        bringPanelToFront()
        // A JSON object is also a valid JavaScript object literal.
        evaluateRendererScript("heySonaExplainer.loadScene(\(sceneJSON), { autoAdvance: \(autoAdvance), stepsStillStreaming: \(stepsStillStreaming) })")
    }

    func appendStep(stepJSON: String) {
        guard Self.isJSONObject(stepJSON) else { return }
        evaluateRendererScript("heySonaExplainer.appendSteps([\(stepJSON)])")
    }

    /// No more steps will be appended.
    func finishSteps() {
        evaluateRendererScript("heySonaExplainer.finishSteps()")
    }

    /// Narration finished the last step; the play button becomes "replay".
    func markFinished() {
        evaluateRendererScript("heySonaExplainer.markFinished()")
    }

    /// `quizJSON` is a JSON array of { question, choices, answerIndex, explanation }.
    func setQuiz(quizJSON: String) {
        guard let quizData = quizJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: quizData)) is [Any] else { return }
        evaluateRendererScript("heySonaExplainer.setQuiz(\(quizJSON))")
    }

    /// A follow-up question is about to append steps to the current scene.
    func continueScene() {
        bringPanelToFront()
        evaluateRendererScript("heySonaExplainer.continueScene()")
    }

    /// Shows the saved-explanations list (opening the window if needed).
    func showLibrary(entriesJSON: String) {
        bringPanelToFront()
        evaluateRendererScript("heySonaExplainer.showLibrary(\(entriesJSON))")
    }

    /// `graphJSON` comes from `ExplanationLibraryStore.conceptGraphJSON()`.
    func showConceptMap(graphJSON: String) {
        bringPanelToFront()
        evaluateRendererScript("heySonaExplainer.showConceptMap(\(graphJSON))")
    }

    /// The step's narration started playing and lasts this long, so the page
    /// can fire word-timed ("at") actions and pace the subtitles to it.
    func startNarrationClock(stepIndex: Int, durationInSeconds: Double) {
        guard durationInSeconds.isFinite, durationInSeconds > 0 else { return }
        evaluateRendererScript("heySonaExplainer.startNarrationClock(\(stepIndex), \(durationInSeconds))")
    }

    /// Swaps in a corrected step from the visual self-check.
    func replaceStep(stepIndex: Int, stepJSON: String) {
        guard Self.isJSONObject(stepJSON) else { return }
        evaluateRendererScript("heySonaExplainer.replaceStep(\(stepIndex), \(stepJSON))")
    }

    func goToStep(_ stepIndex: Int) {
        evaluateRendererScript("heySonaExplainer.goToStep(\(stepIndex))")
    }

    private func bringPanelToFront() {
        createPanelIfNeeded()
        if placement == .dockedBesideFrontWindow {
            // Docked beside the user's app: show it without taking focus,
            // so they keep working in their app (Esc still stops it).
            explainerPanel?.orderFrontRegardless()
            return
        }
        // The app has no Dock icon; activate so the panel comes to the front
        // and receives keys (Esc, space, arrows).
        NSApp.activate(ignoringOtherApps: true)
        explainerPanel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Placement

    private(set) var placement: ExplainerPlacement = .centered
    private static let centeredPanelSize = NSSize(width: 900, height: 640)
    private static let dockedPanelSize = NSSize(width: 480, height: 360)

    /// Switches between the centered explainer and a compact one docked
    /// beside the front window. Moving happens only when the placement
    /// changes, so a window the user moved stays put.
    func setPlacement(_ newPlacement: ExplainerPlacement) {
        let didPlacementChange = newPlacement != placement
        placement = newPlacement
        if didPlacementChange || newPlacement == .dockedBesideFrontWindow, let explainerPanel {
            applyPlacement(to: explainerPanel)
        }
        evaluateRendererScript("heySonaExplainer.setCompact(\(newPlacement == .dockedBesideFrontWindow))")
    }

    private func applyPlacement(to panel: NSPanel) {
        switch placement {
        case .centered:
            panel.minSize = NSSize(width: 560, height: 420)
            if panel.frame.width < Self.centeredPanelSize.width * 0.8 {
                panel.setContentSize(Self.centeredPanelSize)
            }
            centerPanelOnScreenWithMouse(panel)
        case .dockedBesideFrontWindow:
            panel.minSize = NSSize(width: 360, height: 280)
            panel.setContentSize(Self.dockedPanelSize)
            panel.setFrameOrigin(Self.dockedPanelOrigin(panelSize: panel.frame.size))
        }
    }

    /// Beside the front window (right side first, then left), or inside its
    /// bottom-right corner when there's no room, or the screen's corner.
    private static func dockedPanelOrigin(panelSize: NSSize) -> NSPoint {
        let gapBesideWindow: CGFloat = 12
        if let frontWindowFrame = frontWindowFrameInAppKitCoordinates(),
           let windowScreen = NSScreen.screens.first(where: { $0.frame.intersects(frontWindowFrame) }) ?? NSScreen.main {
            let visibleFrame = windowScreen.visibleFrame
            let topAlignedY = min(frontWindowFrame.maxY, visibleFrame.maxY) - panelSize.height
            var dockedOrigin: NSPoint
            if visibleFrame.maxX - frontWindowFrame.maxX >= panelSize.width + gapBesideWindow {
                dockedOrigin = NSPoint(x: frontWindowFrame.maxX + gapBesideWindow, y: topAlignedY)
            } else if frontWindowFrame.minX - visibleFrame.minX >= panelSize.width + gapBesideWindow {
                dockedOrigin = NSPoint(x: frontWindowFrame.minX - gapBesideWindow - panelSize.width, y: topAlignedY)
            } else {
                dockedOrigin = NSPoint(x: frontWindowFrame.maxX - panelSize.width - 16, y: frontWindowFrame.minY + 16)
            }
            dockedOrigin.x = min(max(dockedOrigin.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
            dockedOrigin.y = min(max(dockedOrigin.y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
            return dockedOrigin
        }
        let screenWithMouse = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visibleFrame = screenWithMouse?.visibleFrame ?? NSRect(origin: .zero, size: panelSize)
        return NSPoint(x: visibleFrame.maxX - panelSize.width - 16, y: visibleFrame.minY + 16)
    }

    /// The front app's focused window frame, via Accessibility (which heySona
    /// already has for push-to-talk). Nil when heySona is in front or it's unavailable.
    private static func frontWindowFrameInAppKitCoordinates() -> CGRect? {
        guard AXIsProcessTrusted(),
              let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindowElement = focusedWindowValue as! AXUIElement
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindowElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindowElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var windowTopLeft = CGPoint.zero
        var windowSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &windowTopLeft),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &windowSize) else {
            return nil
        }
        // Accessibility measures from the top-left of the primary screen;
        // AppKit from the bottom-left.
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: windowTopLeft.x,
            y: primaryScreenHeight - windowTopLeft.y - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    func closeExplainer() {
        explainerPanel?.close()
    }

    // MARK: - Window

    private func createPanelIfNeeded() {
        guard explainerPanel == nil else { return }

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController.add(self, name: Self.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)

        let panelSize = NSSize(width: 900, height: 640)
        // A titled window keeps native rounded corners, shadow, and edge
        // resizing; its title bar and buttons are hidden so the explanation
        // fills the whole frosted-glass window instead of looking like a
        // separate app with a video player.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "heySona Explainer"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for windowButtonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(windowButtonType)?.isHidden = true
        }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 420)

        // Frosted glass behind a transparent page.
        let glassBackgroundView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        glassBackgroundView.material = .hudWindow
        glassBackgroundView.blendingMode = .behindWindow
        glassBackgroundView.state = .active
        glassBackgroundView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.frame = glassBackgroundView.bounds
        webView.autoresizingMask = [.width, .height]
        glassBackgroundView.addSubview(webView)

        // The page covers the title bar area, so this strip is what moves the window.
        let dragStripView = ExplainerWindowDragStripView(frame: NSRect(
            x: 0,
            y: panelSize.height - ExplainerWindowDragStripView.stripHeight,
            width: panelSize.width,
            height: ExplainerWindowDragStripView.stripHeight
        ))
        dragStripView.autoresizingMask = [.width, .minYMargin]
        glassBackgroundView.addSubview(dragStripView)

        panel.contentView = glassBackgroundView
        panel.delegate = self
        applyPlacement(to: panel)

        explainerPanel = panel
        explainerWebView = webView
        isRendererReady = false

        guard let explainerPageURL = Self.bundledResourceURL(named: "visual-explainer", withExtension: "html") else {
            print("⚠️ Visual explainer: visual-explainer.html is missing from the app bundle")
            return
        }
        // Read access to the page's folder lets it load three.js beside it.
        webView.loadFileURL(explainerPageURL, allowingReadAccessTo: explainerPageURL.deletingLastPathComponent())
    }

    private func centerPanelOnScreenWithMouse(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let visibleFrame = screenWithMouse?.visibleFrame else {
            panel.center()
            return
        }
        let panelSize = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2
        ))
    }

    func windowWillClose(_ notification: Notification) {
        // Tear the web view down so its animation stops using the GPU, and
        // remove the message handler, which otherwise keeps this object alive.
        explainerWebView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        explainerWebView = nil
        explainerPanel?.delegate = nil
        explainerPanel = nil
        isRendererReady = false
        scriptsWaitingForRenderer = []
        onExplainerClosed?()
    }

    // MARK: - Talking To The Page

    private func evaluateRendererScript(_ script: String) {
        guard isRendererReady else {
            scriptsWaitingForRenderer.append(script)
            return
        }
        explainerWebView?.evaluateJavaScript(script + "; undefined") { _, error in
            if let error {
                print("⚠️ Visual explainer script error: \(error.localizedDescription)")
            }
        }
    }

    /// WebKit delivers page messages on the main thread.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let messageBody = message.body as? [String: Any],
              let messageType = messageBody["type"] as? String else { return }

        switch messageType {
        case "ready":
            isRendererReady = true
            let scriptsToRun = scriptsWaitingForRenderer
            scriptsWaitingForRenderer = []
            scriptsToRun.forEach(evaluateRendererScript)
        case "playPauseRequested":
            onPlayPauseRequested?(messageBody["isPlaying"] as? Bool ?? true)
        case "stepStarted":
            if let stepIndex = messageBody["index"] as? Int {
                onStepStarted?(stepIndex, messageBody["narration"] as? String ?? "")
            }
        case "close":
            closeExplainer()
        case "libraryRequested":
            onLibraryRequested?()
        case "stepIssues":
            if let stepIndex = messageBody["index"] as? Int, let issues = messageBody["issues"] as? [String] {
                print("🧪 Step \(stepIndex) layout: \(issues.joined(separator: "; "))")
                onStepIssuesReported?(stepIndex, issues)
            }
        case "conceptMapRequested":
            onConceptMapRequested?()
        case "libraryEntrySelected":
            if let explanationID = messageBody["id"] as? String {
                onLibraryEntrySelected?(explanationID)
            }
        case "libraryEntryDeleted":
            if let explanationID = messageBody["id"] as? String {
                onLibraryEntryDeleted?(explanationID)
            }
        case "error":
            print("⚠️ Visual explainer page error: \(messageBody["message"] as? String ?? "unknown")")
        default:
            break
        }
    }

    private static func isJSONObject(_ jsonText: String) -> Bool {
        guard let jsonData = jsonText.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: jsonData)) is [String: Any]
    }

    /// Encodes text as a quoted, escaped JavaScript string.
    private static func javaScriptStringLiteral(_ text: String) -> String {
        guard let encodedData = try? JSONSerialization.data(withJSONObject: [text]),
              let encodedArray = String(data: encodedData, encoding: .utf8) else {
            return "\"\""
        }
        return String(encodedArray.dropFirst().dropLast())
    }

    // MARK: - Bundle Resources

    /// Finds a file inside VisualExplainer.bundle in the app's resources.
    static func bundledResourceURL(named resourceName: String, withExtension fileExtension: String) -> URL? {
        guard let explainerResourceFolderURL = Bundle.main.url(forResource: explainerResourceBundleName, withExtension: "bundle") else {
            return nil
        }
        let resourceURL = explainerResourceFolderURL.appendingPathComponent("\(resourceName).\(fileExtension)")
        return FileManager.default.fileExists(atPath: resourceURL.path) ? resourceURL : nil
    }
}

/// A thin transparent strip along the top edge of the explainer window. The
/// web page fills the window (including the hidden title bar), so dragging
/// this strip, marked by a small handle drawn by the page, moves the window.
private final class ExplainerWindowDragStripView: NSView {
    static let stripHeight: CGFloat = 16

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
