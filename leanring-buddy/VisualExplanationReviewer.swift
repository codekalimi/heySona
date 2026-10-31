//
//  VisualExplanationReviewer.swift
//  leanring-buddy
//
//  Optional visual self-check (Settings > Visuals > "Double-check visuals"):
//  after a new explanation finishes streaming, every step is rendered in a
//  hidden web view (the same page as the explainer window), snapshotted, and
//  sent to Claude with the scene and the renderer's own layout issues.
//  Claude returns corrected steps only for the ones that need it; steps the
//  narration hasn't reached yet are swapped in live, and the saved library
//  entry is updated so replays are fixed too. Costs one extra request with a
//  few small images, which is why it's off by default.
//

import AppKit
import Foundation
import WebKit

@MainActor
final class VisualExplanationReviewer: NSObject, WKScriptMessageHandler {
    private static let maximumReviewedStepCount = 8
    private static let snapshotWidthInPoints: CGFloat = 768

    private var hiddenWindow: NSWindow?
    private var hiddenWebView: WKWebView?
    private var rendererReadyContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - Snapshots

    /// Renders each step offscreen and returns JPEG snapshots, in order.
    func snapshotSteps(sceneLines: [String]) async -> [(stepIndex: Int, jpegData: Data)] {
        guard let setupLine = sceneLines.first,
              var sceneDescription = Self.jsonObject(from: setupLine),
              let pageURL = VisualExplainerPanelManager.bundledResourceURL(named: "visual-explainer", withExtension: "html") else {
            return []
        }
        let stepObjects = sceneLines.dropFirst()
            .compactMap(Self.jsonObject(from:))
            .filter { $0["quiz"] == nil && $0["concepts"] == nil }
        guard !stepObjects.isEmpty else { return [] }
        sceneDescription["steps"] = stepObjects
        sceneDescription["quiz"] = nil
        guard let sceneData = try? JSONSerialization.data(withJSONObject: sceneDescription),
              let sceneJSON = String(data: sceneData, encoding: .utf8) else {
            return []
        }

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController.add(self, name: "heySona")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640), configuration: webConfiguration)
        // Far off screen: WebGL only renders in a window, but the user
        // shouldn't see this one.
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        hiddenWindow = window
        hiddenWebView = webView
        defer { tearDownHiddenWebView() }

        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        let isRendererReady = await withCheckedContinuation { continuation in
            rendererReadyContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.resumeRendererReady(false)
            }
        }
        guard isRendererReady else {
            print("⚠️ Visual self-check: the hidden renderer didn't load")
            return []
        }

        // No fades or transitions, so each snapshot shows the finished step.
        _ = try? await webView.evaluateJavaScript("""
        document.head.insertAdjacentHTML('beforeend', '<style>* { transition: none !important; animation: none !important; }</style>');
        heySonaExplainer.loadScene(\(sceneJSON), { autoAdvance: false, stepsStillStreaming: false }); 'ok'
        """)

        var stepSnapshots: [(stepIndex: Int, jpegData: Data)] = []
        for stepIndex in 0..<min(stepObjects.count, Self.maximumReviewedStepCount) {
            _ = try? await webView.evaluateJavaScript(
                "heySonaExplainer.goToStep(\(stepIndex)); heySonaExplainer.advanceFramesForTesting(150); 'ok'"
            )
            let snapshotConfiguration = WKSnapshotConfiguration()
            snapshotConfiguration.snapshotWidth = NSNumber(value: Double(Self.snapshotWidthInPoints))
            guard let snapshotImage = try? await webView.takeSnapshot(configuration: snapshotConfiguration),
                  let jpegData = Self.jpegData(from: snapshotImage) else { continue }
            stepSnapshots.append((stepIndex, jpegData))
        }
        return stepSnapshots
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let messageBody = message.body as? [String: Any], messageBody["type"] as? String == "ready" else { return }
        resumeRendererReady(true)
    }

    private func resumeRendererReady(_ isReady: Bool) {
        rendererReadyContinuation?.resume(returning: isReady)
        rendererReadyContinuation = nil
    }

    private func tearDownHiddenWebView() {
        hiddenWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "heySona")
        hiddenWindow?.orderOut(nil)
        hiddenWindow?.contentView = nil
        hiddenWindow = nil
        hiddenWebView = nil
    }

    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    // MARK: - Claude Review

    static let reviewSystemPromptSection = """


    REVIEW MODE: you are checking a scene you or another writer already made, not writing a new one. Each image shows the stage after one step finished (image labels give the step index, starting at 0). Look for: objects cut off or off screen, labels or cards overlapping or covering the subject, unreadable text, a camera that frames the wrong thing, visuals that don't match the narration, and the layout issues the renderer reported. Output JSON Lines with a corrected step object only for each step that needs fixing, with an extra "index" field: {"index": 2, "narration": "...", "actions": [...]}. Keep object ids, keep the narration unless it's wrong, and only use objects that exist by that step. If every step is fine, output exactly: OK
    """

    /// Asks Claude for corrected steps. Returns step index → step JSON (without "index").
    static func requestStepFixes(
        claudeAPI: ClaudeAPI,
        sceneLines: [String],
        stepSnapshots: [(stepIndex: Int, jpegData: Data)],
        layoutIssuesDescription: String
    ) async throws -> [Int: String] {
        let snapshotImages = stepSnapshots.map { stepSnapshot in
            (data: stepSnapshot.jpegData, label: "step \(stepSnapshot.stepIndex) (shown after its actions played)")
        }
        let reviewUserPrompt = """
        The scene, as JSON Lines (setup first, then steps 0, 1, 2…):
        \(sceneLines.joined(separator: "\n"))

        Layout issues the renderer found: \(layoutIssuesDescription.isEmpty ? "none" : layoutIssuesDescription)

        Review the snapshots and output corrected step lines only where needed, or OK.
        """
        let reviewResponse = try await claudeAPI.analyzeImageStreaming(
            images: snapshotImages,
            systemPrompt: VisualExplanationSession.sceneAuthoringSystemPrompt + reviewSystemPromptSection,
            userPrompt: reviewUserPrompt,
            onTextChunk: { _ in }
        )

        var stepFixesByIndex: [Int: String] = [:]
        for responseLine in reviewResponse.text.components(separatedBy: .newlines) {
            guard var stepObject = jsonObject(from: responseLine.trimmingCharacters(in: .whitespaces)),
                  let stepIndex = (stepObject["index"] as? Int) ?? (stepObject["index"] as? Double).map({ Int($0) }),
                  stepObject["narration"] != nil || stepObject["actions"] != nil else { continue }
            stepObject["index"] = nil
            guard let stepData = try? JSONSerialization.data(withJSONObject: stepObject),
                  let stepJSON = String(data: stepData, encoding: .utf8) else { continue }
            stepFixesByIndex[stepIndex] = stepJSON
        }
        return stepFixesByIndex
    }

    private static func jsonObject(from jsonLine: String) -> [String: Any]? {
        guard jsonLine.hasPrefix("{"), let lineData = jsonLine.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
    }
}
