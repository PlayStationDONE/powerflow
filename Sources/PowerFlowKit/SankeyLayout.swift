import CoreGraphics
import Foundation

/// What a node represents. Drives which glyph the view draws.
public enum SankeyNodeKind: String, Sendable, Equatable {
    case adapter
    case battery
    case system
}

public struct SankeyNode: Equatable, Sendable, Identifiable {
    public let kind: SankeyNodeKind
    /// Which column the node sits in: sources on the left, sinks on the right.
    public let isSource: Bool
    /// Watts flowing through the node.
    public let power: Double
    public let frame: CGRect
    public var id: String { "\(kind.rawValue)-\(isSource ? "src" : "dst")" }

    public init(kind: SankeyNodeKind, isSource: Bool, power: Double, frame: CGRect) {
        self.kind = kind
        self.isSource = isSource
        self.power = power
        self.frame = frame
        }
}

public struct SankeyLink: Equatable, Sendable, Identifiable {
    public let from: SankeyNodeKind
    public let to: SankeyNodeKind
    public let power: Double
    /// Vertical span where the ribbon leaves the source node.
    public let startY: ClosedRange<CGFloat>
    /// Vertical span where the ribbon enters the target node.
    public let endY: ClosedRange<CGFloat>
    /// Horizontal span the ribbon covers.
    public let xRange: ClosedRange<CGFloat>
    public var id: String { "\(from.rawValue)->\(to.rawValue)" }

    /// The ribbon outline, as the d3-sankey style pair of horizontally-tangent
    /// cubic Beziers: across the top edge, down the right, back along the
    /// bottom, and closed up the left.
    public func path() -> CGPath {
        let p = CGMutablePath()
        let x0 = xRange.lowerBound, x1 = xRange.upperBound
        let mid = (x0 + x1) / 2
        p.move(to: CGPoint(x: x0, y: startY.lowerBound))
        p.addCurve(
            to: CGPoint(x: x1, y: endY.lowerBound),
            control1: CGPoint(x: mid, y: startY.lowerBound),
            control2: CGPoint(x: mid, y: endY.lowerBound)
        )
        p.addLine(to: CGPoint(x: x1, y: endY.upperBound))
        p.addCurve(
            to: CGPoint(x: x0, y: startY.upperBound),
            control1: CGPoint(x: mid, y: endY.upperBound),
            control2: CGPoint(x: mid, y: startY.upperBound)
        )
        p.closeSubpath()
        return p
    }
}

public struct SankeyLayout: Equatable, Sendable {
    public var nodes: [SankeyNode]
    public var links: [SankeyLink]
    /// Points of height per watt actually used. Zero when there is no flow.
    public var scale: CGFloat

    public struct Config: Equatable, Sendable {
        /// Width of a node card.
        public var nodeWidth: CGFloat
        /// Space between a node card and the ribbon it feeds.
        public var gutter: CGFloat
        /// Vertical space between two nodes stacked in the same column.
        public var nodePadding: CGFloat

        public init(nodeWidth: CGFloat, gutter: CGFloat, nodePadding: CGFloat) {
            self.nodeWidth = nodeWidth
            self.gutter = gutter
            self.nodePadding = nodePadding
        }
    }

    /// Lay the diagram out inside `rect`.
    ///
    /// Node heights and ribbon thicknesses are both proportional to watts. The
    /// scale is chosen so the busiest column exactly fills the height once its
    /// inter-node padding is accounted for, then each column is centred on the
    /// same axis.
    public static func make(for snapshot: PowerSnapshot, in rect: CGRect, config: Config) -> SankeyLayout {
        // Sources feed the machine; sinks consume. The battery swaps sides
        // depending on which way it is flowing.
        var sources: [(SankeyNodeKind, Double)] = []
        var sinks: [(SankeyNodeKind, Double)] = []

        let charging = snapshot.batteryInput
        let discharging = snapshot.batteryOutput

        if snapshot.adapterPower > 0.01 { sources.append((.adapter, snapshot.adapterPower)) }
        if discharging > 0.01 { sources.append((.battery, discharging)) }
        if snapshot.systemLoad > 0.01 { sinks.append((.system, snapshot.systemLoad)) }
        if charging > 0.01 { sinks.append((.battery, charging)) }

        guard !sources.isEmpty, !sinks.isEmpty else {
            return SankeyLayout(nodes: [], links: [], scale: 0)
        }

        let total = max(sources.reduce(0) { $0 + $1.1 }, sinks.reduce(0) { $0 + $1.1 })
        let gaps = CGFloat(max(sources.count, sinks.count) - 1)
        let usable = max(1, rect.height - gaps * config.nodePadding)
        let scale = total > 0 ? usable / total : 0

        // Stack a column's nodes and centre the stack vertically.
        func place(_ entries: [(SankeyNodeKind, Double)], x: CGFloat, isSource: Bool) -> [SankeyNode] {
            let heights = entries.map { CGFloat($0.1) * scale }
            let stack = heights.reduce(0, +) + CGFloat(entries.count - 1) * config.nodePadding
            var y = rect.minY + (rect.height - stack) / 2
            var out: [SankeyNode] = []
            for (i, entry) in entries.enumerated() {
                let frame = CGRect(x: x, y: y, width: config.nodeWidth, height: heights[i])
                out.append(SankeyNode(kind: entry.0, isSource: isSource, power: entry.1, frame: frame))
                y += heights[i] + config.nodePadding
            }
            return out
        }

        let leftNodes = place(sources, x: rect.minX, isSource: true)
        let rightNodes = place(sinks, x: rect.maxX - config.nodeWidth, isSource: false)

        // Ribbons run between the inner edges of the two columns.
        let ribbonX = (rect.minX + config.nodeWidth + config.gutter)
            ... (rect.maxX - config.nodeWidth - config.gutter)

        // Each node pays out its links from the top down, so ribbons never
        // cross: the adapter's share of the system node sits above the
        // battery's, matching the order of the source column.
        var sourceCursor: [SankeyNodeKind: CGFloat] = [:]
        var sinkCursor: [SankeyNodeKind: CGFloat] = [:]
        for n in leftNodes { sourceCursor[n.kind] = n.frame.minY }
        for n in rightNodes { sinkCursor[n.kind] = n.frame.minY }

        var links: [SankeyLink] = []
        func connect(_ from: SankeyNodeKind, _ to: SankeyNodeKind, _ power: Double) {
            guard power > 0.01,
                  let s = sourceCursor[from], let d = sinkCursor[to] else { return }
            let thickness = CGFloat(power) * scale
            links.append(SankeyLink(
                from: from, to: to, power: power,
                startY: s...(s + thickness),
                endY: d...(d + thickness),
                xRange: ribbonX
            ))
            sourceCursor[from] = s + thickness
            sinkCursor[to] = d + thickness
        }

        // Order matters: emit adapter flows first so they occupy the top of
        // every node they touch.
        if charging > 0.01 {
            // Charging: the wall covers the machine, the surplus fills the pack.
            connect(.adapter, .system, snapshot.systemLoad)
            connect(.adapter, .battery, charging)
        } else {
            connect(.adapter, .system, snapshot.adapterPower)
            connect(.battery, .system, discharging)
        }

        return SankeyLayout(nodes: leftNodes + rightNodes, links: links, scale: scale)
    }
}
