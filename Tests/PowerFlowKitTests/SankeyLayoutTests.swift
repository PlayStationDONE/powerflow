import CoreGraphics
import Testing
@testable import PowerFlowKit

/// The layout is pinned to the reference screenshot. Its content box is
/// x 57...1222, and the diagram occupies y 194...668 within it, so the frames
/// these tests assert can be checked against the original image directly.
private let referenceRect = CGRect(x: 57, y: 194, width: 1165, height: 474)
private let referenceConfig = SankeyLayout.Config(nodeWidth: 155, gutter: 20, nodePadding: 93)

private func layout(_ s: PowerSnapshot) -> SankeyLayout {
    SankeyLayout.make(for: s, in: referenceRect, config: referenceConfig)
}

private func node(_ l: SankeyLayout, _ kind: SankeyNodeKind, source: Bool) -> SankeyNode? {
    l.nodes.first { $0.kind == kind && $0.isSource == source }
}

@Suite struct SankeyLayoutTests {

    // MARK: reference geometry

    /// Every frame below was measured off the screenshot with a pixel scan.
    @Test func testReferenceLayoutReproducesTheScreenshot() {
        let l = layout(.sample)
        let tolerance: CGFloat = 3

        guard let adapter = node(l, .adapter, source: true),
              let battery = node(l, .battery, source: true),
              let system = node(l, .system, source: false)
        else { return XCTFail("expected adapter, battery and system nodes") }

        // Left column: plug card measured at y 195...511, battery at 604...668.
        XCTAssertEqual(adapter.frame.minX, 57, accuracy: tolerance)
        XCTAssertEqual(adapter.frame.width, 155, accuracy: tolerance)
        XCTAssertEqual(adapter.frame.minY, 195, accuracy: tolerance)
        XCTAssertEqual(adapter.frame.maxY, 511, accuracy: tolerance)
        XCTAssertEqual(battery.frame.minY, 605, accuracy: tolerance)
        XCTAssertEqual(battery.frame.maxY, 668, accuracy: tolerance)

        // Right column: laptop card measured at x 1066...1218, y 242...621.
        XCTAssertEqual(system.frame.minX, 1067, accuracy: tolerance)
        XCTAssertEqual(system.frame.minY, 241, accuracy: tolerance)
        XCTAssertEqual(system.frame.maxY, 621, accuracy: tolerance)

        // Ribbons run x 232...1045 in the original.
        guard let link = l.links.first else { return XCTFail("expected a link") }
        XCTAssertEqual(link.xRange.lowerBound, 232, accuracy: tolerance)
        XCTAssertEqual(link.xRange.upperBound, 1047, accuracy: tolerance)
    }

    /// The screenshot's ribbons measured 315px and 59px thick for 87.77 W and
    /// 16.92 W, i.e. a shared scale of about 3.6 px per watt.
    @Test func testRibbonThicknessIsProportionalToWatts() {
        let l = layout(.sample)
        XCTAssertEqual(l.scale, 3.639, accuracy: 0.02)

        let thicknesses = l.links.map { $0.startY.upperBound - $0.startY.lowerBound }
        XCTAssertEqual(thicknesses.count, 2)
        XCTAssertEqual(thicknesses[0], 319.4, accuracy: 3)
        XCTAssertEqual(thicknesses[1], 61.6, accuracy: 3)
        // Same watts-to-points scale for both ribbons.
        let perWatt = zip(thicknesses, l.links.map { $0.power }).map { $0 / CGFloat($1) }
        XCTAssertEqual(perWatt[0], perWatt[1], accuracy: 0.001)
    }

    /// The busier column fills the available height exactly once its padding
    /// is accounted for; that is what fixes the scale.
    @Test func testBusiestColumnFillsTheHeight() {
        let l = layout(.sample)
        let sources = l.nodes.filter(\.isSource)
        let top = sources.map(\.frame.minY).min()!
        let bottom = sources.map(\.frame.maxY).max()!
        XCTAssertEqual(top, referenceRect.minY, accuracy: 0.5)
        XCTAssertEqual(bottom, referenceRect.maxY, accuracy: 0.5)
    }

    /// The single node on the right is centred on the same axis.
    @Test func testSingleSinkIsVerticallyCentred() {
        let l = layout(.sample)
        let system = node(l, .system, source: false)!
        XCTAssertEqual(system.frame.midY, referenceRect.midY, accuracy: 0.5)
    }

    /// A node's height is its wattage, so the machine's card equals the two
    /// ribbons feeding it stacked together.
    @Test func testSinkHeightEqualsSumOfItsInputs() {
        let l = layout(.sample)
        let system = node(l, .system, source: false)!
        let inputs = l.links.reduce(0) { $0 + ($1.endY.upperBound - $1.endY.lowerBound) }
        XCTAssertEqual(system.frame.height, inputs, accuracy: 0.5)
    }

    // MARK: the other power states

    /// Charging moves the battery to the sink column: the wall feeds both the
    /// machine and the pack.
    @Test func testChargingPutsTheBatteryOnTheRight() {
        let s = PowerSnapshot(
            percent: 40, externalConnected: true, isCharging: true,
            adapterPower: 60, batteryPower: 25, systemLoad: 35
        )
        let l = layout(s)
        XCTAssertNotNil(node(l, .battery, source: false), "battery is a sink while charging")
        XCTAssertNil(node(l, .battery, source: true))
        XCTAssertEqual(l.links.count, 2)
        XCTAssertEqual(Set(l.links.map(\.from)), [.adapter])
        XCTAssertEqual(Set(l.links.map(\.to)), [.system, .battery])
    }

    /// Unplugged there is one source, one sink and one full-height ribbon.
    @Test func testOnBatteryIsOneFullHeightRibbon() {
        let s = PowerSnapshot(
            percent: 55, externalConnected: false,
            adapterPower: 0, batteryPower: -14.5, systemLoad: 14.5
        )
        let l = layout(s)
        XCTAssertEqual(l.nodes.count, 2)
        XCTAssertEqual(l.links.count, 1)
        // No second node means no padding, so the flow spans the whole height.
        XCTAssertEqual(l.links[0].startY.lowerBound, referenceRect.minY, accuracy: 0.5)
        XCTAssertEqual(l.links[0].startY.upperBound, referenceRect.maxY, accuracy: 0.5)
    }

    /// On AC with a full battery the diagram is a single adapter-to-machine
    /// ribbon; the battery card is not drawn at all.
    @Test func testIdleOnACHasNoBatteryNode() {
        let s = PowerSnapshot(
            percent: 100, externalConnected: true, fullyCharged: true,
            adapterPower: 19, batteryPower: 0, systemLoad: 19
        )
        let l = layout(s)
        XCTAssertEqual(l.nodes.count, 2)
        XCTAssertNil(node(l, .battery, source: true))
        XCTAssertNil(node(l, .battery, source: false))
    }

    /// Ribbons must not cross: the adapter's share of the machine sits above
    /// the battery's, matching the order of the source column.
    @Test func testRibbonsDoNotCross() {
        let l = layout(.sample)
        let fromAdapter = l.links.first { $0.from == .adapter }!
        let fromBattery = l.links.first { $0.from == .battery }!
        XCTAssertLessThanOrEqual(fromAdapter.startY.upperBound, fromBattery.startY.lowerBound)
        XCTAssertLessThanOrEqual(fromAdapter.endY.upperBound, fromBattery.endY.lowerBound + 0.001)
    }

    @Test func testNoFlowProducesNothingToDraw() {
        let l = layout(PowerSnapshot())
        XCTAssertTrue(l.nodes.isEmpty)
        XCTAssertTrue(l.links.isEmpty)
    }

    /// The ribbon outline starts and ends at the node edges it connects.
    @Test func testLinkPathSpansTheRibbon() {
        let l = layout(.sample)
        let box = l.links[0].path().boundingBoxOfPath
        XCTAssertEqual(box.minX, l.links[0].xRange.lowerBound, accuracy: 0.5)
        XCTAssertEqual(box.maxX, l.links[0].xRange.upperBound, accuracy: 0.5)
    }

    /// Scaling the panel must not change any proportion.
    @Test func testLayoutIsScaleInvariant() {
        let half = SankeyLayout.make(
            for: .sample,
            in: CGRect(x: 0, y: 0, width: referenceRect.width / 2, height: referenceRect.height / 2),
            config: .init(nodeWidth: 77.5, gutter: 10, nodePadding: 46.5)
        )
        let full = layout(.sample)
        XCTAssertEqual(half.scale * 2, full.scale, accuracy: 0.01)
    }
}
