import SwiftUI

/// 割合（0〜1 など）を「%」の数値で入力する欄。スライダーと並べて、数字でも決められるようにする
struct PercentField: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        HStack(spacing: 3) {
            TextField("", value: Binding(
                get: { (value * 1000).rounded() / 10 },
                set: { value = min(range.upperBound, max(range.lowerBound, $0 / 100)) }),
                format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .textFieldStyle(.roundedBorder)
            Text("%").foregroundStyle(.secondary)
        }
    }
}
