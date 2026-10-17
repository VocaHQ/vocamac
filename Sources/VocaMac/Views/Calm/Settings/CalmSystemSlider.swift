// CalmSystemSlider.swift
// VocaMac
//
// A slider in the switch's language (the boards draw none): a 4 pt `off`
// track filled with ink up to an 18-point knob. Used for the double-tap
// speed and silence sensitivity.

import SwiftUI

/// A Calm slider over a closed range, snapping to `step`. Drag or click
/// the track; arrow keys move one step while it has keyboard focus.
struct CalmSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double
    let label: String
    var valueText: String?

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var hasFocus: Bool

    private let knob = CalmMetrics.switchKnob

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, label: String, valueText: String? = nil) {
        _value = value
        self.range = range
        self.step = step
        self.label = label
        self.valueText = valueText
    }

    /// Where `value` sits, 0...1.
    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knob, 1)
            let knobX = travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(CalmColor.off).frame(height: 4)
                Capsule().fill(CalmColor.ink).frame(width: knobX + knob / 2, height: 4)
                Circle()
                    .fill(CalmColor.knobOn)
                    .overlay(Circle().strokeBorder(CalmColor.line2, lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .calmFocusRing(hasFocus && isEnabled, radius: knob / 2)
                    .offset(x: knobX)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    guard isEnabled else { return }
                    set(fraction: (drag.location.x - knob / 2) / travel)
                }
            )
        }
        .frame(height: 24)
        .focusable(isEnabled, interactions: .activate)
        .focused($hasFocus)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1) }
        .onKeyPress(.rightArrow) { nudge(1) }
        .calmDisabledDimming()
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText ?? String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = nudge(1)
            case .decrement: _ = nudge(-1)
            @unknown default: break
            }
        }
    }

    private func set(fraction newFraction: Double) {
        let clamped = min(max(newFraction, 0), 1)
        let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        let snapped = (raw / step).rounded() * step
        let next = min(max(snapped, range.lowerBound), range.upperBound)
        if abs(next - value) > step / 1000 { value = next }
    }

    @discardableResult
    private func nudge(_ steps: Int) -> KeyPress.Result {
        let next = min(max(value + Double(steps) * step, range.lowerBound), range.upperBound)
        value = (next / step).rounded() * step
        return .handled
    }
}
