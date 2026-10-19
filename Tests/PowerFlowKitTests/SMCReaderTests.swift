import Testing
@testable import PowerFlowKit

/// Byte payloads captured from a real `AppleSMC` on Apple silicon.
///
/// The endianness here was not guessed. It was established by cross-checking
/// two keys against IORegistry: `B0AV` decodes to 13227 mV little-endian
/// against a reported pack voltage of 13228, and `B0CT` decodes to 23 against a
/// reported cycle count of 23. Big-endian gives 43827 and 5888 — nonsense for
/// both. These tests pin that down so a future "fix" cannot quietly flip it.
@Suite struct SMCDecodeTests {

    /// `PSTR`, system total power, as captured while the machine drew ~30 W.
    @Test func testFloatIsLittleEndian() {
        let watts = SMCReader.decode(bytes: [0xf9, 0xb0, 0xed, 0x41], type: "flt ")
        XCTAssertEqual(watts ?? 0, 29.711, accuracy: 0.001)
    }

    /// `B0AV`, pack voltage. IORegistry reported 13228 mV at the same moment.
    @Test func testUInt16IsLittleEndian() {
        XCTAssertEqual(SMCReader.decode(bytes: [0xab, 0x33], type: "ui16") ?? 0, 13227)
    }

    /// `B0CT`, cycle count. IORegistry reported 23.
    @Test func testUInt16CycleCount() {
        XCTAssertEqual(SMCReader.decode(bytes: [0x17, 0x00], type: "ui16") ?? 0, 23)
    }

    /// `B0AC`, pack current, is signed: negative means the battery is supplying
    /// the machine. Getting this wrong inverts the whole diagram.
    @Test func testSignedInt16HandlesDischarge() {
        // -1500 mA little-endian is 0xFA24.
        XCTAssertEqual(SMCReader.decode(bytes: [0x24, 0xfa], type: "si16") ?? 0, -1500)
        XCTAssertEqual(SMCReader.decode(bytes: [0xdc, 0x05], type: "si16") ?? 0, 1500)
        XCTAssertEqual(SMCReader.decode(bytes: [0x00, 0x00], type: "si16") ?? 0, 0)
    }

    /// `BRSC`, state of charge.
    @Test func testUInt8() {
        XCTAssertEqual(SMCReader.decode(bytes: [0x64], type: "ui8 ") ?? 0, 100)
    }

    @Test func testUInt32IsLittleEndian() {
        XCTAssertEqual(SMCReader.decode(bytes: [0x01, 0x00, 0x00, 0x00], type: "ui32") ?? 0, 1)
    }

    /// Temperatures are big-endian fixed point, unlike the integer types.
    @Test func testSignedFixedPoint() {
        XCTAssertEqual(SMCReader.decode(bytes: [0x1e, 0x80], type: "sp78") ?? 0, 30.5, accuracy: 0.001)
    }

    /// A key whose type this reader does not understand must report nothing
    /// rather than a plausible-looking wrong number.
    @Test func testUnknownTypeIsRejected() {
        XCTAssertNil(SMCReader.decode(bytes: [0x01, 0x02, 0x03, 0x04], type: "ch8*"))
    }

    /// A truncated payload must not read past the end.
    @Test func testShortPayloadIsRejected() {
        XCTAssertNil(SMCReader.decode(bytes: [0x01], type: "ui16"))
        XCTAssertNil(SMCReader.decode(bytes: [0x01, 0x02], type: "flt "))
        XCTAssertNil(SMCReader.decode(bytes: [], type: "ui8 "))
    }
}
