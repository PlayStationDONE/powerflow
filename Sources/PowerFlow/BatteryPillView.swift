import PowerFlowKit
import SwiftUI

/// The capsule at the top of the panel: charge level, live status glyphs, the
/// charge-target handle and the dashed resume marker.
struct BatteryPillView: View {
    let snapshot: PowerSnapshot
    /// Charge target, 0...1. Drawn as the handle.
    let target: Double
    /// Resume-charging floor, 0...1. Drawn as the dashed line.
    let floor: Double
    let s: Scale
    var onTargetChange: ((Double) -> Void)? = nil
    var onFloorChange: ((Double) -> Void)? = nil

    /// Which marker the current drag grabbed.
    @State private var dragging: Marker?
    private enum Marker { case target, floor }

    private var fraction: CGFloat { CGFloat(min(100, max(0, snapshot.percent)) / 100) }

    /// Which status glyphs apply right now, in the reference's order. Each
    /// carries its own size and leading gap, which is how the original reads:
    /// a large plug, a small pause tucked beside it, then a wider break before
    /// the discharge marker.
    private var glyphs: [Glyph] {
        var out: [Glyph] = []
        if snapshot.externalConnected {
            out.append(.init(name: "powerplug.portrait.fill", size: Ref.pillPlugSize, lead: 0, rotation: 0))
        }
        if snapshot.chargingPaused {
            out.append(.init(name: pauseGlyphName, size: 0, lead: Ref.pillPauseLead, rotation: 0))
        }
        if snapshot.isCharging {
            out.append(.init(name: "bolt.fill", size: Ref.pillBoltSize, lead: Ref.pillPauseLead, rotation: 0))
        }
        // Net discharge while plugged in: the load is outrunning the adapter.
        if snapshot.externalConnected, snapshot.batteryOutput > 0.01 {
            out.append(.init(name: "paperplane.fill", size: Ref.pillPlaneSize, lead: Ref.pillPlaneLead, rotation: 40))
        }
        return out
    }

    struct Glyph: Identifiable {
        let name: String
        let size: CGFloat
        let lead: CGFloat
        let rotation: Double
        var id: String { name }
    }

    var body: some View {
        let width = s(Ref.contentWidth)
        let height = s(Ref.pillHeight)
        // Never let the fill collapse below a round cap.
        let fillWidth = max(height, width * fraction)

        ZStack(alignment: .leading) {
            Capsule().fill(Palette.pillTrack)

            Capsule()
                .fill(Palette.pillFill)
                .frame(width: fillWidth)

            // Glyphs sit centred within the filled portion, as in the reference.
            HStack(spacing: 0) {
                ForEach(glyphs) { g in
                    Group {
                        if g.name == pauseGlyphName {
                            PauseGlyph(s: s)
                        } else {
                            Image(systemName: g.name)
                                .font(.system(size: s(g.size)))
                                .foregroundStyle(.white)
                                .rotationEffect(.degrees(g.rotation))
                        }
                    }
                    .padding(.leading, s(g.lead))
                }
            }
            .frame(width: fillWidth)

            Text("\(Int(snapshot.percent.rounded()))%")
                .font(.system(size: s(Ref.pillFontSize), weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: s(Ref.pillTextNudge))
                .padding(.leading, s(Ref.pillTextInset))

            // Resume-charging marker, clipped to the capsule.
            DashedMarker(dash: [s(Ref.dashOn), s(Ref.dashOff)], width: s(Ref.dashWidth))
                .stroke(Palette.marker, style: StrokeStyle(
                    lineWidth: s(Ref.dashWidth),
                    dash: [s(Ref.dashOn), s(Ref.dashOff)]
                ))
                .offset(x: width * CGFloat(floor))
                .clipShape(Capsule())
        }
        .frame(width: width, height: height)
        .overlay(alignment: .leading) {
            // Charge-target handle, deliberately taller than the pill.
            RoundedRectangle(cornerRadius: s(Ref.thumbWidth) / 2, style: .continuous)
                .fill(Palette.marker)
                .frame(width: s(Ref.thumbWidth), height: s(Ref.thumbHeight))
                .offset(x: width * CGFloat(target) - s(Ref.thumbWidth) / 2)
        }
        .contentShape(Rectangle())
        .gesture(markerDrag(width: width))
    }

    /// Drags the nearer marker, but only when the press starts near one, so a
    /// stray click on the pill never moves anything.
    private func markerDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = Double(min(max(value.location.x / width, 0), 1))
                if dragging == nil {
                    let start = Double(min(max(value.startLocation.x / width, 0), 1))
                    let grabRadius = 0.06
                    let dTarget = abs(start - target)
                    let dFloor = abs(start - floor)
                    guard min(dTarget, dFloor) <= grabRadius else { return }
                    dragging = dTarget <= dFloor ? .target : .floor
                }
                switch dragging {
                case .target: onTargetChange?(fraction)
                case .floor: onFloorChange?(fraction)
                case nil: break
                }
            }
            .onEnded { _ in dragging = nil }
    }
}

/// Sentinel name for the hand-drawn pause glyph.
let pauseGlyphName = "__pause__"

/// Two bars, sized from the reference rather than from `pause.fill`.
private struct PauseGlyph: View {
    let s: Scale
    var body: some View {
        HStack(spacing: s(Ref.pauseBarGap)) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: s(Ref.pauseBarRadius), style: .continuous)
                    .fill(.white)
                    .frame(width: s(Ref.pauseBarWidth), height: s(Ref.pauseBarHeight))
            }
        }
    }
}

/// A single vertical line spanning the shape's height, drawn at x = 0 so the
/// caller can position it with an offset.
private struct DashedMarker: Shape {
    let dash: [CGFloat]
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.minY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY))
        return p
    }
}
