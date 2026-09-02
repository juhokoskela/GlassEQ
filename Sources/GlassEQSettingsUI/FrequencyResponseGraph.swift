@_spi(GlassEQSettingsUI) import GlassEQCore
import SwiftUI

// Maps frequency (log scale) and magnitude onto the graph's plot area. Shared by the Canvas grid
// and the curve shapes so they line up.
struct PlotScale {
    static let insets = EdgeInsets(top: 15, leading: 42, bottom: 21, trailing: 34)
    static let magnitudeRange = -24.0...12.0
    static let minimumFrequency = 20.0

    let rect: CGRect
    let maximumFrequency: Double

    init(bounds: CGRect, maximumFrequency: Double) {
        rect = CGRect(
            x: bounds.minX + Self.insets.leading,
            y: bounds.minY + Self.insets.top,
            width: bounds.width - Self.insets.leading - Self.insets.trailing,
            height: bounds.height - Self.insets.top - Self.insets.bottom
        )
        self.maximumFrequency = max(maximumFrequency, Self.minimumFrequency + 0.000_1)
    }

    func x(for frequency: Double) -> CGFloat {
        let lower = log10(Self.minimumFrequency)
        let upper = log10(maximumFrequency)
        let fraction = (log10(frequency) - lower) / (upper - lower)
        return rect.minX + rect.width * fraction
    }

    func y(for magnitudeDB: Double) -> CGFloat {
        let range = Self.magnitudeRange
        let fraction = 1 - ((magnitudeDB - range.lowerBound) / (range.upperBound - range.lowerBound))
        return rect.minY + rect.height * fraction
    }
}

struct FrequencyResponseGraph: View {
    var analysis: EQAnalysisSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let scale = PlotScale(bounds: bounds, maximumFrequency: analysis.maximumUsableFrequency)
            context.fill(Path(bounds), with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
            drawGrid(context: context, scale: scale)
            drawAxisLabels(context: context, scale: scale, bounds: bounds)
        }
        .overlay {
            ZStack {
                switch analysis.channelMode {
                case .linked:
                    curve(analysis.linkedPoints, color: .accentColor)
                case .stereo:
                    curve(analysis.leftPoints, color: .blue)
                    curve(analysis.rightPoints, color: .orange)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
    }

    private func curve(_ points: [FrequencyResponsePoint], color: Color) -> some View {
        ResponseCurveShape(
            frequencies: points.map(\.frequency),
            magnitudes: AnimatableMagnitudes(values: points.map(\.magnitudeDB)),
            maximumFrequency: analysis.maximumUsableFrequency
        )
        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: points)
    }

    private func drawGrid(context: GraphicsContext, scale: PlotScale) {
        let rect = scale.rect
        var path = Path()
        for db in [-24.0, -12.0, -6.0, 0.0, 6.0, 12.0] {
            let y = scale.y(for: db)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        for frequency in axisFrequencies {
            let x = scale.x(for: frequency)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

        var zero = Path()
        let zeroY = scale.y(for: 0)
        zero.move(to: CGPoint(x: rect.minX, y: zeroY))
        zero.addLine(to: CGPoint(x: rect.maxX, y: zeroY))
        context.stroke(zero, with: .color(.secondary.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawAxisLabels(context: GraphicsContext, scale: PlotScale, bounds: CGRect) {
        for db in [12.0, 6.0, 0.0, -6.0, -12.0, -24.0] {
            context.draw(
                Text(db.dbAxisLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: bounds.minX + 17, y: scale.y(for: db)),
                anchor: .center
            )
        }

        for frequency in axisFrequencies {
            context.draw(
                Text(axisLabel(for: frequency))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: scale.x(for: frequency), y: bounds.maxY - 10),
                anchor: .center
            )
        }
    }

    private var axisFrequencies: [Double] {
        let maximum = analysis.maximumUsableFrequency
        var frequencies = [20.0, 100.0, 1_000.0, 10_000.0, 20_000.0]
            .filter { $0 <= maximum }
        if frequencies.last != maximum {
            frequencies.append(maximum)
        }
        return frequencies
    }

    private func axisLabel(for frequency: Double) -> String {
        if frequency == analysis.maximumUsableFrequency,
           frequency != EQRouteFrequencyPolicy.maximumProfileFrequency {
            return frequency.frequencyLabel
        }
        return frequency.axisFrequencyLabel
    }
}

struct ResponseCurveShape: Shape {
    var frequencies: [Double]
    var magnitudes: AnimatableMagnitudes
    var maximumFrequency: Double

    var animatableData: AnimatableMagnitudes {
        get { magnitudes }
        set { magnitudes = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = min(frequencies.count, magnitudes.values.count)
        guard count > 1 else {
            return Path()
        }
        let scale = PlotScale(bounds: rect, maximumFrequency: maximumFrequency)
        let range = PlotScale.magnitudeRange
        var path = Path()
        for index in 0..<count {
            let magnitude = min(max(magnitudes.values[index], range.lowerBound), range.upperBound)
            let position = CGPoint(
                x: scale.x(for: frequencies[index]),
                y: scale.y(for: magnitude)
            )
            index == 0 ? path.move(to: position) : path.addLine(to: position)
        }
        return path
    }
}
