import SwiftUI
import SpeeckinkCore

/// HUD 顯示資料
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
    @Published var level: Float = 0
    var onUndoTap: (() -> Void)?
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
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
