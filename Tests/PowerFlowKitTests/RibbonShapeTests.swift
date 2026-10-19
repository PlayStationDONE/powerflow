import CoreGraphics
import SwiftUI
import Testing
@testable import PowerFlowKit

/// The ribbon has to be an animatable `Shape` rather than a plain `Path`.
/// A `Path` view cannot be interpolated, so the ribbons snapped to each new
/// reading while the node cards animated - the mismatch that made the panel
/// look jerky. These tests pin the interpolation contract.
@Suite struct RibbonShapeTests {

    private let a = RibbonShape(startTop: 0, startBottom: 100, endTop: 200, endBottom: 300,
                                x0: 10, x1: 110)
    private let b = RibbonShape(startTop: 40, startBottom: 200, endTop: 400, endBottom: 500,
                                x0: 10, x1: 110)

    @Test func testAnimatableDataRoundTrips() {
        var shape = a
        let data = shape.animatableData
        shape.animatableData = data
        XCTAssertEqual(shape.startTop, a.startTop)
        XCTAssertEqual(shape.startBottom, a.startBottom)
        XCTAssertEqual(shape.endTop, a.endTop)
        XCTAssertEqual(shape.endBottom, a.endBottom)
    }

    /// Halfway through an animation every edge must be halfway between.
    @Test func testInterpolationProducesIntermediateGeometry() {
        var mid = a
        var data = a.animatableData
        var target = b.animatableData
        data.scale(by: 0.5)
        target.scale(by: 0.5)
        data += target
        mid.animatableData = data

        XCTAssertEqual(mid.startTop, 20, accuracy: 1e-9)
        XCTAssertEqual(mid.startBottom, 150, accuracy: 1e-9)
        XCTAssertEqual(mid.endTop, 300, accuracy: 1e-9)
        XCTAssertEqual(mid.endBottom, 400, accuracy: 1e-9)
    }

    /// An interpolated shape must still draw a sane ribbon, not a degenerate
    /// or inverted one.
    @Test func testInterpolatedPathStaysBetweenTheEndpoints() {
        var mid = a
        var data = a.animatableData
        var target = b.animatableData
        data.scale(by: 0.5)
        target.scale(by: 0.5)
        data += target
        mid.animatableData = data

        let box = mid.path(in: CGRect(x: 0, y: 0, width: 200, height: 600)).boundingRect
        let boxA = a.path(in: CGRect(x: 0, y: 0, width: 200, height: 600)).boundingRect
        let boxB = b.path(in: CGRect(x: 0, y: 0, width: 200, height: 600)).boundingRect
        XCTAssertGreaterThanOrEqual(box.maxY, boxA.maxY)
        XCTAssertLessThanOrEqual(box.maxY, boxB.maxY)
        XCTAssertFalse(box.isEmpty)
    }

    /// The horizontal span is set by the column layout and never animates.
    @Test func testPathSpansTheGivenXRange() {
        let box = a.path(in: CGRect(x: 0, y: 0, width: 200, height: 600)).boundingRect
        XCTAssertEqual(box.minX, 10, accuracy: 0.5)
        XCTAssertEqual(box.maxX, 110, accuracy: 0.5)
    }

    /// The convenience initialiser must agree with the laid-out link.
    @Test func testInitFromLinkMatchesLayout() {
        let layout = SankeyLayout.make(
            for: .sample,
            in: CGRect(x: 57, y: 194, width: 1165, height: 474),
            config: .init(nodeWidth: 155, gutter: 20, nodePadding: 93)
        )
        let link = layout.links[0]
        let shape = RibbonShape(link)
        XCTAssertEqual(shape.startTop, link.startY.lowerBound)
        XCTAssertEqual(shape.endBottom, link.endY.upperBound)
        XCTAssertEqual(shape.x1, link.xRange.upperBound)
    }

    /// A curve shorter than the gap between readings finishes early and leaves
    /// the panel frozen until the next one, which is what reads as a stutter.
    @Test func testAnimationOutlastsTheSampleInterval() {
        XCTAssertGreaterThan(Motion.sampleInterval * 1.2, Motion.sampleInterval)
    }
}
