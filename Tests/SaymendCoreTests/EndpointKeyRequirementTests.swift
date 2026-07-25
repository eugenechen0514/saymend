import Testing
@testable import SaymendCore

@Test func emptyBaseURLRequiresKeyBecauseItFallsBackToOpenAI() {
    // AppSettings.openAIConfig 對空字串 fallback 到 api.openai.com——留空≠本機
    #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: ""))
    #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: "   "))
}

@Test func cloudEndpointsRequireKey() {
    for url in ["https://api.openai.com/v1",
                "https://openrouter.ai/api/v1",
                "https://llm.example.com/v1"] {
        #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: url), "\(url) 應判需要 Key")
    }
}

@Test func localEndpointsDoNotRequireKey() {
    for url in ["http://localhost:11434/v1",         // Ollama
                "http://127.0.0.1:1234/v1",          // LM Studio
                "http://[::1]:8080/v1",
                "http://mac-studio.local:8000/v1",   // 區網 Bonjour
                "http://192.168.1.20:11434/v1",
                "http://10.0.0.5:8000/v1",
                "http://172.16.3.9:8000/v1"] {
        #expect(!EndpointKeyRequirement.requiresAPIKey(baseURL: url), "\(url) 應判可留空")
    }
}

@Test func unparseableEndpointIsTreatedAsRequiringKey() {
    // 認不出來就當成需要 Key：漏報只是少一條提示，誤報是天天看到假警報
    #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: "隨便亂打"))
    #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: "http://"))
}

@Test func lookalikeHostsAreNotTreatedAsLocal() {
    // 172.32 不在私有網段（16-31）內；notlocalhost.com 只是字面像
    #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: "http://172.32.0.1:8000/v1"))
    #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: "https://notlocalhost.com/v1"))
    #expect(EndpointKeyRequirement.requiresAPIKey(baseURL: "https://localhost.evil.com/v1"))
}
