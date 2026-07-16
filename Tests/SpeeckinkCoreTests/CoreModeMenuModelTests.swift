import Foundation
import Testing
@testable import SpeeckinkCore

private let builtins = PromptAssembler.builtinCoreModes

@Test func menuChecksResolvedActiveModeNotRawSetting() {
    // 勾選必須反映 resolver 的「目前有效模式」，不是只比對某一層的 raw setting
    let m = CoreModeMenuModel(allModes: builtins,
                              active: PromptAssembler.assistantMode,
                              frontAppBundleID: "com.apple.TextEdit")
    #expect(m.isChecked(PromptAssembler.assistantMode))
    #expect(!m.isChecked(PromptAssembler.pureDictationMode))
    #expect(m.allModes.filter(m.isChecked).count == 1)   // 只能有一個打勾
}

@Test func menuDisablesPerAppBindWhenNoFrontmostBundle() {
    let withApp = CoreModeMenuModel(allModes: builtins,
                                    active: PromptAssembler.pureDictationMode,
                                    frontAppBundleID: "com.apple.TextEdit")
    #expect(withApp.canBindFrontApp)

    let noApp = CoreModeMenuModel(allModes: builtins,
                                  active: PromptAssembler.pureDictationMode,
                                  frontAppBundleID: nil)
    #expect(!noApp.canBindFrontApp)      // 無 frontmost bundle → per-app 子選單停用
}

@Test func menuIncludesUserModesAlongsideBuiltins() {
    let mine = CoreMode(name: "我的模式", systemRules: "規則")
    let m = CoreModeMenuModel(allModes: builtins + [mine],
                              active: mine,
                              frontAppBundleID: "com.apple.TextEdit")
    #expect(m.allModes.count == 5)
    #expect(m.isChecked(mine))
}

@Test func menuAfterStaleModeDeletedChecksFallbackNotGhost() {
    // 使用者刪掉正被 session override 指向的自建模式後，resolver 已 fallback；
    // menu 必須勾選 fallback 的結果，且清單不得再出現該幽靈模式。
    let resolver = CoreModeResolver()
    let ghostID = UUID().uuidString
    let resolved = resolver.resolve(sessionModeID: ghostID,     // 已被刪除
                                    appModeID: nil,
                                    defaultModeID: nil,
                                    availableModes: builtins)
    let m = CoreModeMenuModel(allModes: builtins,
                              active: resolved,
                              frontAppBundleID: "com.apple.TextEdit")
    #expect(m.isChecked(PromptAssembler.pureDictationMode))     // 落回內建預設
    #expect(!m.allModes.contains { $0.id == ghostID })          // 清單無幽靈
}
