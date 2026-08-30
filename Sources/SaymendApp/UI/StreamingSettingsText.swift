/// 串流設定的使用者可見說明。抽離 `SettingsView` 是為了讓產品取捨能直接測試，
/// 避免只剩「套件預設」數字，卻沒說預設值對短句體感的影響。
enum StreamingSettingsText {
    static let requiredSegmentsTradeoff =
        "數值 1 通常會讓文字在說話時更快上屏，但只留一個片段等待後文修正，錯字可能較早鎖進定稿。"
        + "數值 2 以上保留更多後文，較穩定；典型短句可能主要到結束時才集中上屏。"
}
