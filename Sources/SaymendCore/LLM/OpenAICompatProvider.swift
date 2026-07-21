import Foundation

public struct OpenAICompatConfig: Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String

    public init(baseURL: URL, apiKey: String?, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}

/// OpenAI Compatible adapter：通吃 OpenAI／OpenRouter／Groq／Ollama／LM Studio（規格 §4.3 順序 1）
public final class OpenAICompatProvider: LLMProvider {
    private let configProvider: () -> OpenAICompatConfig
    private let session: URLSession

    /// configProvider 於每次呼叫時讀取，設定視窗改了 base URL／model 立即生效
    public init(configProvider: @escaping () -> OpenAICompatConfig, session: URLSession = .shared) {
        self.configProvider = configProvider
        self.session = session
    }

    private struct ChatRequest: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Msg]
        let temperature: Double
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct M: Decodable { let content: String? }
            let message: M
        }
        let choices: [Choice]
    }

    public func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        let config = configProvider()
        let url = config.baseURL.appending(path: "chat/completions")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(ChatRequest(
            model: config.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: 0.2
        ))
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }
}
