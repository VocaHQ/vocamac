import SwiftUI

/// High-frequency meter changes do not invalidate AppState's other observers.
@MainActor
final class AudioMeterState: ObservableObject {
    @Published private(set) var level: Float = 0

    func update(_ value: Float) {
        let next = value.isFinite ? min(1, max(0, value)) : 0
        guard next != level else { return }
        level = next
    }
}

struct ObservedAudioLevelView: View {
    @ObservedObject var meter: AudioMeterState
    var tint: Color? = nil

    var body: some View {
        if let tint {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint)
                        .frame(width: max(4, geometry.size.width * CGFloat(meter.level)))
                }
            }
        } else {
            AudioLevelView(level: meter.level)
        }
    }
}
