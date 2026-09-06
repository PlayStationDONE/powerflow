import PowerFlowKit
import SwiftUI

/// The power-flow diagram: source cards on the left, the machine on the right,
/// and ribbons whose thickness is the wattage flowing through them.
struct SankeyView: View {
    let snapshot: PowerSnapshot
    let s: Scale

    private var config: SankeyLayout.Config {
        .init(
            nodeWidth: s(Ref.nodeWidth),
            gutter: s(Ref.nodeGutter),
            nodePadding: s(Ref.nodePadding)
        )
    }

    var body: some View {
        let w = s(Ref.contentWidth)
        let h = s(Ref.diagramHeight)
        let layout = SankeyLayout.make(
            for: snapshot,
            in: CGRect(x: 0, y: 0, width: w, height: h),
            config: config
        )

        ZStack(alignment: .topLeading) {
            ForEach(layout.links) { link in
                RibbonShape(link)
                    .fill(Palette.surface)
                    .frame(width: w, height: h)
                    .transition(.opacity)
            }
            ForEach(layout.nodes) { node in
                card(for: node)
            }
            ForEach(layout.links) { link in
                ribbonLabel(link)
            }
        }
        .frame(width: w, height: h)
    }

    // MARK: - nodes

    @ViewBuilder
    private func card(for node: SankeyNode) -> some View {
        let radius = min(s(Ref.nodeRadius), min(node.frame.width, node.frame.height) / 2)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.surface)
            .overlay { glyph(for: node) }
            .frame(width: node.frame.width, height: node.frame.height)
            .position(x: node.frame.midX, y: node.frame.midY)
    }

    @ViewBuilder
    private func glyph(for node: SankeyNode) -> some View {
        switch node.kind {
        case .adapter:
            Image(systemName: "powerplug.portrait.fill")
                .font(.system(size: s(Ref.plugGlyph)))
                .foregroundStyle(Palette.energy)
        case .battery:
            Image(systemName: "battery.100")
                .font(.system(size: s(Ref.batteryGlyph)))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Palette.batteryFill, Palette.batteryCase)
        case .system:
            VStack(spacing: s(Ref.systemLabelGap)) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: s(Ref.laptopGlyph)))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Palette.laptopBody, Palette.laptopScreen)
                Text(Format.nodeWatts(node.power))
                    .font(.system(size: s(Ref.labelFontSize), weight: .medium))
                    .contentTransition(.numericText(value: node.power))
                    .foregroundStyle(Palette.label)
            }
            .offset(y: s(Ref.systemBlockNudge))
        }
    }

    // MARK: - ribbon labels

    @ViewBuilder
    private func ribbonLabel(_ link: SankeyLink) -> some View {
        let thickness = link.startY.upperBound - link.startY.lowerBound
        // Only label a ribbon that can actually hold the text.
        if thickness > s(Ref.labelFontSize) * 0.85 {
            let midY = ((link.startY.lowerBound + link.startY.upperBound)
                + (link.endY.lowerBound + link.endY.upperBound)) / 4
            Text(Format.ribbonWatts(link.power))
                .font(.system(size: s(Ref.labelFontSize), weight: .medium))
                .contentTransition(.numericText(value: link.power))
                .foregroundStyle(Palette.label)
                .position(
                    x: (link.xRange.lowerBound + link.xRange.upperBound) / 2,
                    y: midY + s(Ref.labelNudge)
                )
        }
    }
}
