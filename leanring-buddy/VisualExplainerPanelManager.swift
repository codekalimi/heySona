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
import WebKit

@MainActor
final class VisualExplainerPanelManager: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    private var explainerPanel: NSPanel?
    private var explainerWebView: WKWebView?

    /// The page posts "ready" once its renderer is set up; scenes sent
    /// before then wait here.
    private var isRendererReady = false
    private var sceneWaitingForRenderer: (sceneJSON: String, autoAdvance: Bool)?

    /// Name the page uses for `window.webkit.messageHandlers.<name>`.
    private static let messageHandlerName = "heySona"
    /// The page, its script, three.js, and the demo scene live in a
    /// `.bundle` folder so Xcode copies them into the app as-is. Loose
    /// `.js` files would be treated as source code and left out.
    private static let explainerResourceBundleName = "VisualExplainer"

    /// Called when a step starts, with its index and narration (used to
    /// sync the voice in phase 2).
    var onStepStarted: ((_ stepIndex: Int, _ narration: String) -> Void)?
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

    /// Shows a scene. With `autoAdvance` the page moves through steps on
    /// its own timing; otherwise the caller drives steps with `goToStep`.
    func showScene(sceneJSON: String, autoAdvance: Bool) {
        // Only well-formed JSON objects are ever passed to the page.
        guard let sceneData = sceneJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: sceneData)) is [String: Any] else {
            print("⚠️ Visual explainer: scene is not a valid JSON object")
            return
        }

        createPanelIfNeeded()
        // The app has no Dock icon; activate so the panel comes to the front
        // and receives keys (Esc, space, arrows).
        NSApp.activate(ignoringOtherApps: true)
        explainerPanel?.makeKeyAndOrderFront(nil)

        if isRendererReady {
            sendSceneToRenderer(sceneJSON: sceneJSON, autoAdvance: autoAdvance)
        } else {
            sceneWaitingForRenderer = (sceneJSON, autoAdvance)
        }
    }

    func goToStep(_ stepIndex: Int) {
        evaluateRendererScript("heySonaExplainer.goToStep(\(stepIndex))")
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
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "heySona Explainer"
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(DS.Colors.background)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 420)
        panel.contentView = webView
        panel.delegate = self
        centerPanelOnScreenWithMouse(panel)

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
        sceneWaitingForRenderer = nil
        onExplainerClosed?()
    }

    // MARK: - Talking To The Page

    private func sendSceneToRenderer(sceneJSON: String, autoAdvance: Bool) {
        // A JSON object is also a valid JavaScript object literal.
        evaluateRendererScript("heySonaExplainer.loadScene(\(sceneJSON), { autoAdvance: \(autoAdvance) })")
    }

    private func evaluateRendererScript(_ script: String) {
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
            if let sceneWaitingForRenderer {
                sendSceneToRenderer(sceneJSON: sceneWaitingForRenderer.sceneJSON, autoAdvance: sceneWaitingForRenderer.autoAdvance)
                self.sceneWaitingForRenderer = nil
            }
        case "stepStarted":
            if let stepIndex = messageBody["index"] as? Int {
                onStepStarted?(stepIndex, messageBody["narration"] as? String ?? "")
            }
        case "close":
            closeExplainer()
        case "error":
            print("⚠️ Visual explainer page error: \(messageBody["message"] as? String ?? "unknown")")
        default:
            break
        }
    }

    // MARK: - Bundle Resources

    /// Finds a file inside VisualExplainer.bundle in the app's resources.
    private static func bundledResourceURL(named resourceName: String, withExtension fileExtension: String) -> URL? {
        guard let explainerResourceFolderURL = Bundle.main.url(forResource: explainerResourceBundleName, withExtension: "bundle") else {
            return nil
        }
        let resourceURL = explainerResourceFolderURL.appendingPathComponent("\(resourceName).\(fileExtension)")
        return FileManager.default.fileExists(atPath: resourceURL.path) ? resourceURL : nil
    }
}
