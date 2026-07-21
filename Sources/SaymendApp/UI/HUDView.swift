import SwiftUI
import SaymendCore

/// HUD 顯示資料
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
    @Published var level: Float = 0
    var onUndoTap: (() -> Void)?
    /// 內容實際渲染尺寸回報：視窗尺寸由 controller 手動貼齊，不得走 autolayout
    /// （macOS 26 的 NSHostingView 視窗尺寸約束會在 layout pass 內重入 update-constraints 而被 AppKit 摔例外）
    var onContentSizeChange: ((CGSize) -> Void)?
}

/// 螢幕下緣浮條（規格 §3.1）：模式、音量、volatile 預覽、通知
struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .hidden:
                EmptyView()
            case .listening(let mode, let volatile):
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                LevelBar(level: model.level)
                Text(mode == .locked ? "鎖定聽寫" : "聽寫中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !volatile.isEmpty {
                    Text(volatile)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                UndoPill(action: model.onUndoTap)
            case .selectionListening(_, let volatile):
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(.orange)
                LevelBar(level: model.level)
                Text("改寫選取中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !volatile.isEmpty {
                    Text(volatile)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            case .lingering:
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("可修正（8 秒內可續說／復原）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                UndoPill(action: model.onUndoTap)
            case .notice(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message).font(.caption)
            case .diff(let windows):
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(windows.prefix(3).enumerated()), id: \.offset) { _, window in
                        Text(Self.attributed(window))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if windows.count > 3 {
                        Text("…共 \(windows.count) 處異動")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        // fixedSize：量測永遠取理想尺寸，不受視窗當下大小壓縮——否則「先縮小再變大」的內容
        // 會被舊視窗尺寸截斷、回報值卡死在壓縮後的大小，視窗永遠長不回來
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            model.onContentSizeChange?(size)
        }
    }

    /// diff 窗口 → 富文字：刪除＝刪除線＋紅、 新增＝底線（規格 §3.5）
    static func attributed(_ window: DiffWindow) -> AttributedString {
        var out = AttributedString()
        for op in window.ops {
            switch op {
            case .kept(let t):
                var seg = AttributedString(t)
                seg.foregroundColor = .secondary
                out += seg
            case .deleted(let t):
                var seg = AttributedString(t)
                seg.strikethroughStyle = .single
                seg.foregroundColor = .red
                out += seg
            case .added(let t):
                var seg = AttributedString(t)
                seg.underlineStyle = .single
                out += seg
            }
        }
        return out
    }
}

/// 復原鈕：規格 §3.3「HUD 常駐復原」。onTapGesture 在 nonactivating panel 上可點且不搶焦點。
struct UndoPill: View {
    var action: (() -> Void)?
    var body: some View {
        Text("復原")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .onTapGesture { action?() }
    }
}

/// 簡易音量條
struct LevelBar: View {
    var level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green)
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(width: 60, height: 6)
    }
}
