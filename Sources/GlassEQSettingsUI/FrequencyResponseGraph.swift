@_spi(GlassEQSettingsUI) import GlassEQCore
import SwiftUI

// Maps logarithmic frequency and gain onto the same plot area for the grid and curves.
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

    // Core Graphics expands dashes before clipping. Trim each segment just outside the plot
    // so deep notches keep their visible slopes without generating offscreen dashes.
    func curvePath(for points: [FrequencyResponsePoint]) -> Path {
        let band = rect.minY - 3...rect.maxY + 3
        func endpoint(_ point: CGPoint, toward other: CGPoint) -> CGPoint {
            let y = min(max(point.y, band.lowerBound), band.upperBound)
            guard y != point.y else { return point }
            let fraction = (y - point.y) / (other.y - point.y)
            return CGPoint(x: point.x + (other.x - point.x) * fraction, y: y)
        }

        var path = Path()
        var previous: CGPoint?
        var lastEnd: CGPoint?
        for sample in points {
            let point = CGPoint(x: x(for: sample.frequency), y: y(for: sample.magnitudeDB))
            defer { previous = point }
            guard let previous, point.x.isFinite, point.y.isFinite, previous.x.isFinite, previous.y.isFinite,
                max(previous.y, point.y) >= band.lowerBound, min(previous.y, point.y) <= band.upperBound
            else { continue }
            let start = endpoint(previous, toward: point)
            let end = endpoint(point, toward: previous)
            if lastEnd != start { path.move(to: start) }
            path.addLine(to: end)
            lastEnd = end
        }
        return path
    }

}

struct FrequencyResponseGraph: View {
    private static let magnitudeTicks = [-24.0, -18, -12, -6, 0, 6, 12]
    var analysis: EQAnalysisSnapshot

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let scale = PlotScale(bounds: bounds, maximumFrequency: analysis.maximumUsableFrequency)
            drawGrid(context: context, scale: scale)
            drawAxisLabels(context: context, scale: scale, bounds: bounds)
            context.clip(to: Path(scale.rect))
            switch analysis.channelMode {
            case .linked:
                drawCurve(analysis.linkedPoints, color: .accentColor, context: context, scale: scale)
            case .stereo:
                drawCurve(analysis.leftPoints, color: .blue, context: context, scale: scale)
                drawCurve(analysis.rightPoints, color: .orange, dashed: true, context: context, scale: scale)
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private func drawCurve(
        _ points: [FrequencyResponsePoint], color: Color, dashed: Bool = false, context: GraphicsContext,
        scale: PlotScale
    ) {
        let path = scale.curvePath(for: points)
        context.stroke(
            path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round, dash: dashed ? [6, 3] : []))
    }

    private func drawGrid(context: GraphicsContext, scale: PlotScale) {
        let rect = scale.rect
        var path = Path()
        for db in Self.magnitudeTicks {
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
        for db in Self.magnitudeTicks {
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
            frequency != EQRouteFrequencyPolicy.maximumProfileFrequency
        {
            return frequency.frequencyLabel
        }
        return frequency.axisFrequencyLabel
    }
}
