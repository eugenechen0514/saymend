/// 視覺回饋層的 Core 側接點（規格 §3.5）。Core 只發語意事件，
/// 「畫在哪裡、能不能畫」（AX 座標、能力偵測、降級）全是 App 端 FeedbackCoordinator 的事。
public struct FeedbackUpdate: Equatable, Sendable {
    /// session 起點的欄位 UTF-16 錨位；nil＝無 AX 錨位（overlay 註定不可用，直接走 diff 降級）
    public var anchor: Int?
    /// session 目前的完整文字（含進行中 utterance）＝底線應涵蓋的範圍
    public var text: String
    /// 最近異動相對 text 的 UTF-16 範圍（nil＝無異動，純底線更新）
    public var highlight: SpanUTF16?
    /// 異動前全文（diff 降級的比對基準；nil＝無異動）
    public var oldText: String?

    public init(anchor: Int?, text: String, highlight: SpanUTF16? = nil, oldText: String? = nil) {
        self.anchor = anchor
        self.text = text
        self.highlight = highlight
        self.oldText = oldText
    }
}

public protocol SessionFeedbackPresenting: AnyObject {
    func sessionUpdated(_ update: FeedbackUpdate)
    /// 凍結：底線淡出（文字定稿）
    func sessionFrozen()
    /// 封存：立即全部隱藏
    func sessionEnded()
}
