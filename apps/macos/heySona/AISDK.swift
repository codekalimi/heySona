import Foundation


class AISDK {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    private let session: URLSession

    init(proxyURL: String) {
        self.apiURL = URL(string: proxyURL)!

        
        
        
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        
        
        
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func addAuthorizationHeader(to request: inout URLRequest) async {
        if let sessionToken = await HeySonaAuthManager.shared.sessionToken() {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
    }

    
    
    
    
    private func detectImageMediaType(for imageData: Data) -> String {
        
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        
        return "image/jpeg"
    }

    
    
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
            
        }.resume()
    }

    
    
    
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void,
        onToolActivity: (@MainActor @Sendable (_ toolName: String, _ isRunning: Bool) -> Void)? = nil
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()
        await addAuthorizationHeader(to: &request)

        
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "image": image.data.base64EncodedString(),
                "mediaType": detectImageMediaType(for: image.data)
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
            "maxOutputTokens": 1024,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("AI SDK streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "AISDK",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "AISDK",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) 

            
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            var textChunk: String?

            if eventType == "text-delta" {
                textChunk = eventPayload["delta"] as? String
            } else if eventType == "tool-input-available",
                      let toolName = eventPayload["toolName"] as? String,
                      toolName == "pointAt",
                      let input = eventPayload["input"] as? [String: Any],
                      let x = input["x"] as? NSNumber,
                      let y = input["y"] as? NSNumber {
                let labelText = (input["label"] as? String)?
                    .replacingOccurrences(of: "]", with: " ")
                    .replacingOccurrences(of: ":", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (labelText?.isEmpty == false) ? ":\(labelText!)" : ""
                let screen = (input["screen"] as? NSNumber).map { ":screen\($0.intValue)" } ?? ""
                let description = ((input["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : " \($0) "
                } ?? " "
                textChunk = " [POINT:\(x.intValue),\(y.intValue)\(label)\(screen)]\(description)"
            } else if eventType == "tool-input-available",
                      let toolName = eventPayload["toolName"] as? String {
                await onToolActivity?(toolName, true)
            } else if eventType == "tool-output-available",
                      let toolName = eventPayload["toolName"] as? String {
                await onToolActivity?(toolName, false)
            }

            if let textChunk {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()
        await addAuthorizationHeader(to: &request)

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "image": image.data.base64EncodedString(),
                "mediaType": detectImageMediaType(for: image.data)
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
            "maxOutputTokens": 256,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("AI SDK request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "AISDK",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "AISDK",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
