import Foundation

/// 端點是否需要 API Key 的判定，供設定頁決定要不要對「Key 留空」示警。
///
/// 為什麼需要判定而非一律示警：OpenAI 相容區塊同時服務雲端端點與本機端點
/// （Ollama／LM Studio 走 http://localhost:11434/v1 之類），本機端點留空是正常用法，
/// 一律示警等於對這批使用者常駐一條假警報。
///
/// 高 precision、低 recall 的取向（同 RewriteSemanticDetector）：只有「明確判定為本機」
/// 才視為可留空；認不出來的一律當成需要 Key——漏報只是少一條提示，誤報是天天看到假警報。
public enum EndpointKeyRequirement {
    /// 空字串＝尚未填，實際會 fallback 到 api.openai.com（AppSettings.openAIConfig），故需要 Key。
    public static func requiresAPIKey(baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return true }
        return !isLocal(host)
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" { return true }
        if host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        // 私有網段（自架在區網另一台機器）
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        if let range = host.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression),
           range.lowerBound == host.startIndex { return true }
        return false
    }
}
