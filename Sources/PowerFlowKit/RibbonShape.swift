import SwiftUI

// Geometry that has to interpolate, so it lives beside the layout it comes from
// and is covered by the same tests.

/// The Sankey ribbon, as an *animatable* shape.
///
/// `Path(...)` is a static view: SwiftUI has no way to interpolate between two
/// of them, so a ribbon built that way jumps straight to each new reading while
/// the node cards beside it glide, which is what made the panel look jerky.
/// Exposing the four edge positions as `animatableData` lets Core Animation
/// tween the geometry every frame instead.
public struct RibbonShape: Shape {

    public init(startTop: CGFloat, startBottom: CGFloat, endTop: CGFloat,
                endBottom: CGFloat, x0: CGFloat, x1: CGFloat) {
        self.startTop = startTop
        self.startBottom = startBottom
        self.endTop = endTop
        self.endBottom = endBottom
        self.x0 = x0
        self.x1 = x1
    }

    /// Where the ribbon leaves the source node.
    public var startTop: CGFloat
    public var startBottom: CGFloat
    /// Where it enters the target node.
    public var endTop: CGFloat
    public var endBottom: CGFloat
    /// Horizontal span. Fixed by the column layout, so it is not animated.
    public var x0: CGFloat
    public var x1: CGFloat

    public var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(startTop, startBottom),
                AnimatablePair(endTop, endBottom)
            )
        }
        set {
            startTop = newValue.first.first
            startBottom = newValue.first.second
            endTop = newValue.second.first
            endBottom = newValue.second.second
        }
    }

    /// Coordinates are absolute within the diagram, so the proposed rect is
    /// only used to size the view, not to place the path.
    public func path(in rect: CGRect) -> Path {
        let mid = (x0 + x1) / 2
        var p = Path()
        p.move(to: CGPoint(x: x0, y: startTop))
        p.addCurve(
            to: CGPoint(x: x1, y: endTop),
            control1: CGPoint(x: mid, y: startTop),
            control2: CGPoint(x: mid, y: endTop)
        )
        p.addLine(to: CGPoint(x: x1, y: endBottom))
        p.addCurve(
            to: CGPoint(x: x0, y: startBottom),
            control1: CGPoint(x: mid, y: endBottom),
            control2: CGPoint(x: mid, y: startBottom)
        )
        p.closeSubpath()
        return p
    }
}

/// Timing shared by everything that moves.
public enum Motion {
    /// How often the sensors are read.
    public static let sampleInterval: TimeInterval = 1.0
    /// How often the per-app list is rebuilt.
    public static let appInterval: TimeInterval = 3.0

    /// Slightly longer than the sample interval and perfectly linear.
    ///
    /// A curve shorter than the interval finishes early and leaves the panel
    /// frozen until the next reading, which reads as a pulse rather than
    /// motion; an ease-in-out restarted every second from a moving state also
    /// breaks velocity at each sample. Linear, slightly overlapping, means one
    /// reading flows into the next without ever stopping.
    public static let flow = Animation.linear(duration: sampleInterval * 1.2)
    public static let appFlow = Animation.linear(duration: appInterval * 0.5)
}

public extension RibbonShape {
    /// Builds the shape for a laid-out link.
    init(_ link: SankeyLink) {
        self.init(
            startTop: link.startY.lowerBound,
            startBottom: link.startY.upperBound,
            endTop: link.endY.lowerBound,
            endBottom: link.endY.upperBound,
            x0: link.xRange.lowerBound,
            x1: link.xRange.upperBound
        )
    }
}
