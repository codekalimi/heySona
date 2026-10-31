//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// Runs one tool call Claude asked for and returns the text to send back as
/// its `tool_result`, plus whether the call failed.
typealias ClaudeToolCallHandler = @MainActor (_ toolName: String, _ toolInput: [String: Any]) async -> (resultText: String, isError: Bool)

/// The model declined the request (`stop_reason: "refusal"`) and no
/// fallback model answered instead.
struct ClaudeResponseRefusedError: LocalizedError {
    var errorDescription: String? { "Claude declined to answer this request." }
}

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    var model: String
    private let session: URLSession

    init(model: String = ClaudeModelCatalog.defaultModelOption.modelID) {
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() throws -> URLRequest {
        // Read the key on every request so a key saved after launch is picked up.
        let anthropicAPIKey = try APIKeyKeychainStore.requireAPIKey(for: .anthropic)

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    ///
    /// When `tools` and `toolCallHandler` are given, this runs the tool-use
    /// loop: whenever Claude stops to call tools, each call is passed to
    /// `toolCallHandler`, the results are sent back, and Claude continues.
    /// The returned text is everything Claude said across all those turns.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        tools: [[String: Any]] = [],
        toolCallHandler: ClaudeToolCallHandler? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let isToolUseEnabled = !tools.isEmpty && toolCallHandler != nil
        var accumulatedResponseText = ""

        for toolRoundTripIndex in 0...Self.maximumToolRoundTripsPerResponse {
            var body: [String: Any] = [
                "model": model,
                "max_tokens": ClaudeModelCatalog.streamingResponseMaximumTokens,
                "stream": true,
                "system": systemPrompt,
                "messages": messages,
                // Thinking is always on for the current models; effort sets how much.
                "output_config": ["effort": ClaudeModelCatalog.responseEffortLevel],
                // Thinking blocks are only valid in the exact conversation that
                // produced them. This loop only appends, but if a block ever
                // fails that check, drop it instead of failing the request.
                "thinking": [
                    "type": "adaptive",
                    "block_binding": ["prefix_mismatch_behavior": "drop_block"]
                ] as [String: Any]
            ]
            if isToolUseEnabled {
                body["tools"] = tools
            }

            var betaFeatureNames = ["thinking-binding-controls-2026-08-01"]
            // When a safety classifier declines a request (sometimes a false
            // positive), re-run it on the model Anthropic recommends instead
            // of returning a refusal.
            if ClaudeModelCatalog.modelOption(forModelID: model)?.supportsServerSideRefusalFallback == true {
                body["fallbacks"] = "default"
                betaFeatureNames.append("server-side-fallback-2026-07-01")
            }

            var request = try makeAPIRequest()
            request.setValue(betaFeatureNames.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
            // Sorted keys keep the serialized history byte-identical between
            // tool round trips, which thinking-block checks and caching rely on.
            let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.httpBody = bodyData
            let payloadMB = Double(bodyData.count) / 1_048_576.0
            print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), turn \(toolRoundTripIndex + 1)")

            let completedAssistantTurn = try await streamOneAssistantTurn(
                request: request,
                onTextFragment: { textFragment, isStartOfNewTextBlock in
                    // Separate text from consecutive turns (e.g. "opening it."
                    // then "done.") so they don't run together when spoken.
                    if isStartOfNewTextBlock,
                       let lastCharacter = accumulatedResponseText.last,
                       !lastCharacter.isWhitespace {
                        accumulatedResponseText += " "
                    }
                    accumulatedResponseText += textFragment
                    // Send the accumulated text so far to the UI for progressive rendering
                    let currentAccumulatedText = accumulatedResponseText
                    onTextChunk(currentAccumulatedText)
                }
            )

            // A refusal that survived any fallback ends the reply. Whatever
            // partial text arrived is discarded rather than spoken as an answer.
            if completedAssistantTurn.stopReason == "refusal" {
                throw ClaudeResponseRefusedError()
            }

            let assistantContentBlocksToEcho = Self.contentBlocksAfterRemovingDeclinedFallbackAttempt(
                completedAssistantTurn.contentBlocks
            )
            let toolUseBlocks = assistantContentBlocksToEcho.filter { ($0["type"] as? String) == "tool_use" }

            // Only run tools when Claude actually stopped to call them. On
            // "max_tokens" or "refusal" a tool_use block may be cut off
            // mid-input, so its tools must never run.
            guard isToolUseEnabled,
                  let toolCallHandler,
                  completedAssistantTurn.stopReason == "tool_use",
                  !toolUseBlocks.isEmpty else {
                break
            }

            guard toolRoundTripIndex < Self.maximumToolRoundTripsPerResponse else {
                print("⚠️ Claude tool loop: stopped after \(Self.maximumToolRoundTripsPerResponse) tool round trips")
                break
            }

            // Echo the assistant turn back unchanged (text, tool_use, and any
            // thinking blocks), as the API requires before tool results.
            messages.append(["role": "assistant", "content": assistantContentBlocksToEcho])

            var toolResultBlocks: [[String: Any]] = []
            for toolUseBlock in toolUseBlocks {
                // Don't perform actions after the user interrupted the reply.
                try Task.checkCancellation()

                let toolUseID = toolUseBlock["id"] as? String ?? ""
                let toolName = toolUseBlock["name"] as? String ?? ""

                if let invalidToolInputJSON = completedAssistantTurn.invalidToolInputJSONByToolUseID[toolUseID] {
                    toolResultBlocks.append([
                        "type": "tool_result",
                        "tool_use_id": toolUseID,
                        "is_error": true,
                        "content": "{\"INVALID_JSON\": \(Self.jsonStringLiteral(invalidToolInputJSON))}"
                    ])
                    continue
                }

                let toolInput = toolUseBlock["input"] as? [String: Any] ?? [:]
                let toolCallResult = await toolCallHandler(toolName, toolInput)
                toolResultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolUseID,
                    "is_error": toolCallResult.isError,
                    "content": toolCallResult.resultText
                ])
            }

            // All results for one assistant turn go back in a single user message.
            messages.append(["role": "user", "content": toolResultBlocks])
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Upper limit on tool round trips in one reply, so a confused model
    /// can't loop forever on the user's Mac.
    private static let maximumToolRoundTripsPerResponse = 6

    /// When a model declines partway through and a fallback model continues
    /// on the same stream, a `fallback` block marks the switch. Anything the
    /// declined model produced before that point other than plain text
    /// (thinking, tool calls) must not be echoed back or acted on. The
    /// marker itself is only an audit record, so it's dropped too.
    private static func contentBlocksAfterRemovingDeclinedFallbackAttempt(
        _ contentBlocks: [[String: Any]]
    ) -> [[String: Any]] {
        guard let lastFallbackMarkerIndex = contentBlocks.lastIndex(where: { ($0["type"] as? String) == "fallback" }) else {
            return contentBlocks
        }

        let textBlocksFromDeclinedAttempt = contentBlocks[..<lastFallbackMarkerIndex].filter { contentBlock in
            (contentBlock["type"] as? String) == "text"
        }
        let blocksFromFallbackModel = contentBlocks[(lastFallbackMarkerIndex + 1)...]
        return Array(textBlocksFromDeclinedAttempt) + Array(blocksFromFallbackModel)
    }

    /// One finished assistant turn from the stream.
    private struct CompletedAssistantTurn {
        /// Content blocks in order, ready to be sent back as the assistant message.
        let contentBlocks: [[String: Any]]
        let stopReason: String?
        /// Raw input text for tool_use blocks whose input wasn't valid JSON.
        let invalidToolInputJSONByToolUseID: [String: String]
    }

    /// Streams one request and rebuilds the assistant's content blocks from
    /// the SSE events: text, tool_use (input arrives as JSON fragments), and
    /// thinking blocks, which must be passed back unchanged in tool loops.
    private func streamOneAssistantTurn(
        request: URLRequest,
        onTextFragment: (_ textFragment: String, _ isStartOfNewTextBlock: Bool) async -> Void
    ) async throws -> CompletedAssistantTurn {
        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var contentBlocksByIndex: [Int: [String: Any]] = [:]
        var partialToolInputJSONByIndex: [Int: String] = [:]
        var stopReason: String?

        // Parse SSE stream — each event is "data: {json}\n\n"
        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            switch eventType {
            case "content_block_start":
                guard let blockIndex = eventPayload["index"] as? Int,
                      let startingContentBlock = eventPayload["content_block"] as? [String: Any] else { continue }
                contentBlocksByIndex[blockIndex] = startingContentBlock
                let startingBlockType = startingContentBlock["type"] as? String
                if startingBlockType == "tool_use" {
                    partialToolInputJSONByIndex[blockIndex] = ""
                }
                if startingBlockType == "text" {
                    let initialText = startingContentBlock["text"] as? String ?? ""
                    await onTextFragment(initialText, true)
                }

            case "content_block_delta":
                guard let blockIndex = eventPayload["index"] as? Int,
                      let delta = eventPayload["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String,
                      var updatedContentBlock = contentBlocksByIndex[blockIndex] else { continue }

                switch deltaType {
                case "text_delta":
                    let textChunk = delta["text"] as? String ?? ""
                    updatedContentBlock["text"] = (updatedContentBlock["text"] as? String ?? "") + textChunk
                    await onTextFragment(textChunk, false)
                case "input_json_delta":
                    partialToolInputJSONByIndex[blockIndex, default: ""] += delta["partial_json"] as? String ?? ""
                case "thinking_delta":
                    updatedContentBlock["thinking"] = (updatedContentBlock["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    updatedContentBlock["signature"] = delta["signature"] as? String ?? ""
                default:
                    break
                }
                contentBlocksByIndex[blockIndex] = updatedContentBlock

            case "message_delta":
                if let messageDelta = eventPayload["delta"] as? [String: Any],
                   let streamedStopReason = messageDelta["stop_reason"] as? String {
                    stopReason = streamedStopReason
                }

            case "error":
                let streamedError = eventPayload["error"] as? [String: Any]
                let errorMessage = streamedError?["message"] as? String ?? "Unknown streaming error"
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "API stream error: \(errorMessage)"]
                )

            default:
                break
            }

            if eventType == "message_stop" { break }
        }

        // Finalize tool inputs. Inputs stream without server-side validation,
        // so parse strictly and report anything unparseable instead of guessing.
        var invalidToolInputJSONByToolUseID: [String: String] = [:]
        for (blockIndex, accumulatedToolInputJSON) in partialToolInputJSONByIndex {
            guard var toolUseBlock = contentBlocksByIndex[blockIndex] else { continue }
            let trimmedToolInputJSON = accumulatedToolInputJSON.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedToolInputJSON.isEmpty {
                toolUseBlock["input"] = [String: Any]()
            } else if let toolInputData = trimmedToolInputJSON.data(using: .utf8),
                      let parsedToolInput = try? JSONSerialization.jsonObject(with: toolInputData) as? [String: Any] {
                toolUseBlock["input"] = parsedToolInput
            } else {
                toolUseBlock["input"] = [String: Any]()
                let toolUseID = toolUseBlock["id"] as? String ?? ""
                invalidToolInputJSONByToolUseID[toolUseID] = accumulatedToolInputJSON
            }
            contentBlocksByIndex[blockIndex] = toolUseBlock
        }

        // The API rejects empty text blocks in an assistant message, so drop
        // any (Claude sometimes opens one right before a tool call).
        let orderedContentBlocks = contentBlocksByIndex.keys.sorted()
            .compactMap { contentBlocksByIndex[$0] }
            .filter { contentBlock in
                guard (contentBlock["type"] as? String) == "text" else { return true }
                let blockText = contentBlock["text"] as? String ?? ""
                return !blockText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        return CompletedAssistantTurn(
            contentBlocks: orderedContentBlocks,
            stopReason: stopReason,
            invalidToolInputJSONByToolUseID: invalidToolInputJSONByToolUseID
        )
    }

    /// Encodes text as a JSON string literal (with quotes and escaping).
    private static func jsonStringLiteral(_ text: String) -> String {
        guard let encodedData = try? JSONSerialization.data(withJSONObject: [text]),
              let encodedArray = String(data: encodedData, encoding: .utf8) else {
            return "\"\""
        }
        // Strip the surrounding [ ] from the one-element array.
        return String(encodedArray.dropFirst().dropLast())
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = try makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
