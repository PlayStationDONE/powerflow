import PowerFlowKit
import SwiftUI

/// The whole popover: battery pill, power-flow diagram, how long the pack would
/// last if the cable came out, and where the power is going by app.
struct PanelView: View {
    let snapshot: PowerSnapshot
    var target: Double = 0.80
    var floor: Double = 0.75
    var panelWidth: CGFloat = 340
    /// Rows for the per-app section, already including the system remainder.
    var rows: [DrawRow] = []
    /// Pre-formatted runtime, e.g. "2h 18m".
    var runtimeText: String?
    /// False renders only the part that mirrors the reference screenshot,
    /// which is how the 1:1 layout is regression tested.
    var showsExtras = true
    /// False on a Mac with no battery, where there is no flow to draw.
    var hasBattery = true
    /// Called while the user drags the charge-target handle.
    var onTargetChange: ((Double) -> Void)? = nil
    /// Called while the user drags the dashed floor marker.
    var onFloorChange: ((Double) -> Void)? = nil

    private var s: Scale { Scale(panelWidth: panelWidth) }

    var body: some View {
        if hasBattery { panel } else { noBattery }
    }

    /// Desktop Macs have no pack, so the diagram would be an empty frame and
    /// the runtime meaningless. Say so instead of drawing nothing.
    private var noBattery: some View {
        VStack(spacing: s(Ref.rowIconGap)) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: s(Ref.plugGlyph)))
                .foregroundStyle(Palette.energy)
            Text("No battery")
                .font(.system(size: s(Ref.labelFontSize), weight: .medium))
                .foregroundStyle(Palette.label)
            Text("PowerFlow needs a laptop battery to chart power flow.")
                .font(.system(size: s(Ref.runtimeCaptionSize)))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(s(Ref.runtimeInset))
        .frame(width: panelWidth, height: s.panelHeight)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            BatteryPillView(
                snapshot: snapshot, target: target, floor: floor, s: s,
                onTargetChange: onTargetChange, onFloorChange: onFloorChange
            )
            .padding(.top, s(Ref.pillTop))

            // Gap between the pill and the diagram, measured from the original.
            Spacer(minLength: 0)
                .frame(height: s(Ref.diagramTop - (Ref.pillTop + Ref.pillHeight)))

            SankeyView(snapshot: snapshot, s: s)

            if showsExtras {
                Spacer(minLength: 0).frame(height: s(Ref.runtimeGap))
                RuntimeCard(text: runtimeText, s: s)

                Spacer(minLength: 0).frame(height: s(Ref.sectionGap))
                AppDrawList(rows: rows, s: s)
            }

            Spacer(minLength: 0)
                .frame(height: s(Ref.height - Ref.diagramBottom))
        }
        .frame(
            width: panelWidth,
            height: showsExtras ? s.extendedPanelHeight : s.panelHeight
        )
        // The diagram follows the sensors; the list moves on its own slower
        // cadence. Animating them with one curve made the rows lurch whenever a
        // reading arrived.
        .animation(Motion.flow, value: snapshot)
        .animation(Motion.appFlow, value: rows)
        .animation(Motion.appFlow, value: runtimeText)
    }
}
