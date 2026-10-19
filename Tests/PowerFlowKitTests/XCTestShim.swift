// Command Line Tools ships Swift Testing but not XCTest, so the original
// XCTest-style assertions are provided here on top of Swift Testing. Test
// bodies are unchanged; only the harness differs.
import Testing

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    Issue.record(Comment(rawValue: message), sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 1))
}

private func fail(_ msg: String, _ file: StaticString, _ line: UInt) {
    XCTFail(msg, file: file, line: line)
}

func XCTAssertTrue(_ e: @autoclosure () -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if !e() { fail("expected true. \(m())", file, line) }
}
func XCTAssertFalse(_ e: @autoclosure () -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if e() { fail("expected false. \(m())", file, line) }
}
func XCTAssertNil(_ e: @autoclosure () -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if let v = e() { fail("expected nil, got \(v). \(m())", file, line) }
}
func XCTAssertNotNil(_ e: @autoclosure () -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if e() == nil { fail("expected non-nil. \(m())", file, line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let (x, y) = (a(), b())
    if x != y { fail("\(x) is not equal to \(y). \(m())", file, line) }
}
func XCTAssertEqual<T: BinaryFloatingPoint>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, accuracy: T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let (x, y) = (a(), b())
    if !(abs(x - y) <= accuracy) { fail("\(x) is not equal to \(y) +/- \(accuracy). \(m())", file, line) }
}
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let (x, y) = (a(), b()); if !(x > y) { fail("\(x) is not greater than \(y)", file, line) }
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let (x, y) = (a(), b()); if !(x >= y) { fail("\(x) is not >= \(y)", file, line) }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let (x, y) = (a(), b()); if !(x <= y) { fail("\(x) is not <= \(y)", file, line) }
}
