//
//  AFMAssistTests.swift
//  McBopomofoTests
//
//  Copyright © 2025 McBopomofo Project
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation
import Testing

@testable import McBopomofo

@Suite("Native AFM Assist", .serialized)
struct AFMAssistTests {

    // MARK: - selectedIndex tests

    @Test("selectedIndex accepts valid id with whitespace")
    func testSelectedIndexAcceptsWhitespace() {
        #expect(AFMAssistClient.selectedIndex(content: "  {\"id\": 1}  \n", candidateCount: 3) == 1)
    }

    @Test("selectedIndex rejects boolean value")
    func testSelectedIndexRejectsBool() {
        #expect(AFMAssistClient.selectedIndex(content: "{\"id\": true}", candidateCount: 3) == nil)
    }

    @Test("selectedIndex rejects string value")
    func testSelectedIndexRejectsString() {
        #expect(AFMAssistClient.selectedIndex(content: "{\"id\": \"1\"}", candidateCount: 3) == nil)
    }

    @Test("selectedIndex rejects fraction")
    func testSelectedIndexRejectsFraction() {
        #expect(AFMAssistClient.selectedIndex(content: "{\"id\": 1.5}", candidateCount: 3) == nil)
    }

    @Test("selectedIndex rejects unknown key")
    func testSelectedIndexRejectsUnknownKey() {
        #expect(AFMAssistClient.selectedIndex(content: "{\"foo\": 1}", candidateCount: 3) == nil)
    }

    @Test("selectedIndex rejects overflow")
    func testSelectedIndexRejectsOverflow() {
        #expect(AFMAssistClient.selectedIndex(content: "{\"id\": 999}", candidateCount: 3) == nil)
    }

    @Test("selectedIndex rejects malformed JSON")
    func testSelectedIndexRejectsMalformed() {
        #expect(AFMAssistClient.selectedIndex(content: "{not json}", candidateCount: 3) == nil)
    }

    @Test("selectedIndex rejects codefence")
    func testSelectedIndexRejectsCodefence() {
        let fence = String(repeating: "`", count: 3)
        let content = "\(fence)json\n{\"id\": 1}\n\(fence)"
        #expect(AFMAssistClient.selectedIndex(content: content, candidateCount: 3) == nil)
    }

    @Test("selectedIndex rejects zero candidate count")
    func testSelectedIndexRejectsZeroCount() {
        #expect(AFMAssistClient.selectedIndex(content: "{\"id\": 0}", candidateCount: 0) == nil)
    }

    // MARK: - AFMRequestGate tests

    @Test("AFMRequestGate invalidates old token")
    func testRequestGateInvalidatesOldToken() {
        let gate = AFMRequestGate()
        let oldToken = gate.token()
        gate.invalidate()
        let newToken = gate.token()
        #expect(!gate.isCurrent(oldToken))
        #expect(gate.isCurrent(newToken))
    }

    @Test("AFMRequestGate stale token after async delay")
    func testRequestGateStaleTokenAfterDelay() async {
        let gate = AFMRequestGate()
        let token = gate.token()
        try? await Task.sleep(nanoseconds: 10_000_000)
        gate.invalidate()
        #expect(!gate.isCurrent(token))
    }

    // MARK: - URLProtocol stub

    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: NSError(domain: "test", code: -1))
                return
            }

            // Safely consume httpBodyStream if httpBody is nil
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                    if bytesRead <= 0 { break }
                }
                stream.close()
            }

            let (data, response) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeSession(handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    /// Build an OpenAI-compatible chat completion response body.
    /// The `content` string is the JSON payload the model would return,
    /// e.g. `{"id": 1}`.
    private func makeOpenAIResponse(content: String, statusCode: Int = 200) -> (Data, HTTPURLResponse) {
        let body: [String: Any] = [
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "model": "system",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": content
                    ],
                    "finish_reason": "stop"
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let url = URL(string: "http://127.0.0.1:1975/v1/chat/completions")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    // MARK: - AFMAssistClient select tests

    @Test("select returns valid id from JSON response")
    func testSelectReturnsValidId() async {
        let session = makeSession { _ in
            makeOpenAIResponse(content: "{\"id\": 1}")
        }
        defer {
            StubURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let client = AFMAssistClient(session: session, timeout: 1.0)
        let result = await client.select(context: "test context", candidates: ["a", "b", "c"])
        #expect(result == 1)
    }

    @Test("select returns nil on HTTP 500")
    func testSelectReturnsNilOnHTTP500() async {
        let session = makeSession { _ in
            makeOpenAIResponse(content: "{\"id\": 1}", statusCode: 500)
        }
        defer {
            StubURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let client = AFMAssistClient(session: session, timeout: 1.0)
        let result = await client.select(context: "test context", candidates: ["a", "b", "c"])
        #expect(result == nil)
    }

    @Test("select returns nil for invalid id")
    func testSelectReturnsNilForInvalidId() async {
        let session = makeSession { _ in
            makeOpenAIResponse(content: "{\"id\": 99}")
        }
        defer {
            StubURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let client = AFMAssistClient(session: session, timeout: 1.0)
        let result = await client.select(context: "test context", candidates: ["a", "b", "c"])
        #expect(result == nil)
    }

    @Test("select returns nil for direct id-only HTTP body without choices wrapper")
    func testSelectReturnsNilForDirectIdBody() async {
        let session = makeSession { _ in
            // A bare {"id": 0} body is NOT a valid OpenAI chat completion response.
            let json = "{\"id\": 0}"
            let url = URL(string: "http://127.0.0.1:1975/v1/chat/completions")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json.data(using: .utf8)!, response)
        }
        defer {
            StubURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let client = AFMAssistClient(session: session, timeout: 1.0)
        let result = await client.select(context: "test context", candidates: ["a", "b", "c"])
        #expect(result == nil)
    }

    @Test("select verifies request structure")
    func testSelectVerifiesRequestStructure() async {
        var capturedRequest: URLRequest?
        let session = makeSession { request in
            // Store a copy of the request so we can inspect httpBody after the
            // URLProtocol may have consumed the stream.
            var copy = request
            if copy.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                    if bytesRead <= 0 { break }
                    data.append(contentsOf: buffer[0..<bytesRead])
                }
                stream.close()
                copy.httpBody = data
            }
            capturedRequest = copy
            return makeOpenAIResponse(content: "{\"id\": 0}")
        }
        defer {
            StubURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let client = AFMAssistClient(session: session, timeout: 1.0)
        let context = String(repeating: "x", count: 300)
        _ = await client.select(context: context, candidates: ["alpha", "beta"])

        guard let req = capturedRequest else {
            Issue.record("No request captured")
            return
        }
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://127.0.0.1:1975/v1/chat/completions")

        guard let bodyData = req.httpBody else {
            Issue.record("No body data")
            return
        }
        guard let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            Issue.record("Body not valid JSON")
            return
        }
        #expect(body["model"] as? String == "system")
        #expect(body["temperature"] as? Int == 0)
        #expect(body["max_tokens"] as? Int == 16)
        #expect(body["stream"] as? Bool == false)

        guard let messages = body["messages"] as? [[String: Any]] else {
            Issue.record("No messages")
            return
        }
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")

        // Parse the user content as JSON to verify structure.
        guard let userContent = messages[1]["content"] as? String,
              let userPayload = try? JSONSerialization.jsonObject(with: userContent.data(using: .utf8)!) as? [String: Any] else {
            Issue.record("User content is not valid JSON")
            return
        }

        // Verify context suffix (last 256 chars of the 300-char context).
        let expectedSuffix = String(context.suffix(256))
        #expect(userPayload["context_suffix"] as? String == expectedSuffix)

        // Verify full candidates array with correct ids and texts.
        guard let candidates = userPayload["candidates"] as? [[String: Any]] else {
            Issue.record("No candidates in user payload")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates[0]["id"] as? Int == 0)
        #expect(candidates[0]["text"] as? String == "alpha")
        #expect(candidates[1]["id"] as? Int == 1)
        #expect(candidates[1]["text"] as? String == "beta")
    }

    @Test("select returns nil when task is cancelled")
    func testSelectReturnsNilWhenCancelled() async {
        let session = makeSession { _ in
            makeOpenAIResponse(content: "{\"id\": 0}")
        }
        defer {
            StubURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let client = AFMAssistClient(session: session, timeout: 1.0)

        let task = Task {
            await client.select(context: "test", candidates: ["a"])
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }

    // MARK: - Preferences AFM Assist test

    @Test("afmAssistEnabled defaults to false")
    func testAFMAssistEnabledDefaultsFalse() {
        let keys = Preferences.allKeys
        var snapshot: [String: Any] = [:]
        keys.forEach { snapshot[$0] = UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

        #expect(Preferences.afmAssistEnabled == false)

        keys.forEach { UserDefaults.standard.set(snapshot[$0], forKey: $0) }
    }
}
