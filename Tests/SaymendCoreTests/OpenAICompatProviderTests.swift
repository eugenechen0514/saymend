import Foundation
import Testing
@testable import SaymendCore

/// 攔截 URLSession 的假傳輸層
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("handler 未設定") }
        let (status, data) = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeProvider(apiKey: String? = "sk-test") -> OpenAICompatProvider {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    let config = OpenAICompatConfig(baseURL: URL(string: "https://example.test/v1")!, apiKey: apiKey, model: "test-model")
    return OpenAICompatProvider(configProvider: { config }, session: URLSession(configuration: cfg))
}

/// `.serialized`：三個測試共用 `MockURLProtocol.handler` 這個 static var，
/// Swift Testing 預設平行執行會互相覆蓋 handler 造成 flaky，故強制序列執行。
@Suite(.serialized)
struct OpenAICompatProviderTests {
    @Test func sendsChatCompletionAndDecodesContent() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.absoluteString == "https://example.test/v1/chat/completions")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = #"{"choices":[{"message":{"content":"{\"intent\":\"new_content\",\"text\":\"好\"}"}}]}"#
            return (200, Data(body.utf8))
        }
        let out = try await makeProvider().complete(system: "s", user: "u", timeout: 5)
        #expect(out.contains("new_content"))
    }

    @Test func non200Throws() async {
        MockURLProtocol.handler = { _ in (500, Data()) }
        await #expect(throws: LLMError.badStatus(500)) {
            _ = try await makeProvider().complete(system: "s", user: "u", timeout: 5)
        }
    }

    @Test func noAuthHeaderWhenKeyNil() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8))
        }
        _ = try await makeProvider(apiKey: nil).complete(system: "s", user: "u", timeout: 5)
    }
}
