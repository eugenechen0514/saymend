import Testing
@testable import SaymendApp

@Suite struct RemoteSettingsTextTests {
    /// 遠端發起的聽寫在浮條上要看得出主機，和本機 CLI 分得開
    @Test func hudLabelNamesTheRemoteHost() {
        #expect(HUDView.cliListeningLabel(loadingModel: false, origin: nil) == "CLI 聽寫中｜Esc 取消")
        #expect(HUDView.cliListeningLabel(loadingModel: false, origin: "devbox") == "遠端 devbox 聽寫中｜Esc 取消")
        #expect(HUDView.cliListeningLabel(loadingModel: true, origin: "devbox") == "遠端 devbox 聽寫中（載入模型中…）｜Esc 取消")
    }

    /// 設定頁必須明講的安全界線
    @Test func securityTextStatesTheTrustBoundary() {
        let w = RemoteSettingsText.securityWarning
        #expect(w.contains("同一個帳號執行的任何程式"))
        #expect(w.contains("只連你信任的主機"))
        #expect(w.contains("不要用多人共用的帳號"))
        let details = RemoteSettingsText.securityDetails.joined()
        #expect(details.contains("不存密碼、不存金鑰"))
        #expect(details.contains("0600"))
        #expect(details.contains("不開任何 TCP port"))
        #expect(details.contains("不含你說的話或朗讀的內容"))
    }
}
