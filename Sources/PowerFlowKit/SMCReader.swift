import Foundation
import IOKit

/// Read-only access to the System Management Controller's power sensors.
///
/// `AppleSmartBattery` only republishes about once a minute, which is far too
/// slow for a live diagram. The SMC exposes the same three figures as float
/// sensors that update roughly every second:
///
///   * `PDTR` - power delivered in from the adapter
///   * `PPBR` - battery power, positive into the pack
///   * `PSTR` - total system power
///
/// This opens the SMC user client for reading only. It never writes a key.
public final class SMCReader {
    private var connection: io_connect_t = 0

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        connection = conn
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Read a four-character key as a Double, or nil if the key is absent or
    /// carries a type this reader does not decode.
    public func double(_ key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var input = ParamStruct()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.readBytes
        guard var output = call(input) else { return nil }
        return Self.decode(&output, type: info.dataType, size: Int(info.dataSize))
    }

    /// Type code, byte length and raw payload for a key. Used to discover what
    /// a machine actually exposes.
    public func describe(_ key: String) -> (type: String, size: Int, bytes: [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        var input = ParamStruct()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.readBytes
        guard var out = call(input) else { return nil }
        let size = Int(info.dataSize)
        let bytes: [UInt8] = withUnsafeBytes(of: &out.bytes) { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return (0..<min(size, 32)).map { b[$0] }
        }
        return (Self.typeName(info.dataType), size, bytes)
    }

    // MARK: - plumbing

    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    private func keyInfo(_ key: String) -> KeyInfo? {
        var input = ParamStruct()
        input.key = Self.code(key)
        input.data8 = Self.readKeyInfo
        guard let out = call(input), out.result == 0 else { return nil }
        return out.keyInfo
    }

    private func call(_ input: ParamStruct) -> ParamStruct? {
        var input = input
        // A fresh, zeroed output every time: reusing a buffer here is how a
        // failed read silently returns the previous key's payload.
        var output = ParamStruct()
        var outSize = MemoryLayout<ParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<ParamStruct>.stride, &output, &outSize
        )
        // The SMC zeroes the key field in its reply, so there is nothing to
        // echo-check; a non-zero `result` is the only failure signal.
        guard result == kIOReturnSuccess,
              output.result == 0,
              outSize == MemoryLayout<ParamStruct>.stride
        else { return nil }
        return output
    }

    /// Four-character codes are packed big-endian into a UInt32.
    private static func code(_ key: String) -> UInt32 {
        var v: UInt32 = 0
        for ch in key.utf8.prefix(4) { v = (v << 8) | UInt32(ch) }
        return v
    }

    private static func typeName(_ type: UInt32) -> String {
        String(bytes: [
            UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF),
        ], encoding: .ascii) ?? ""
    }

    private static func decode(_ out: inout ParamStruct, type: UInt32, size: Int) -> Double? {
        withUnsafeBytes(of: &out.bytes) { raw -> Double? in
            let b = raw.bindMemory(to: UInt8.self)
            switch typeName(type) {
            case "flt ":
                guard size >= 4 else { return nil }
                let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                return Double(Float(bitPattern: bits))
            case "ui8 ":
                return Double(b[0])
            case "ui16":
                guard size >= 2 else { return nil }
                return Double(UInt16(b[0]) | UInt16(b[1]) << 8)
            case "si16":
                guard size >= 2 else { return nil }
                return Double(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
            case "ui32":
                return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            case "sp78":
                // Signed fixed point, 7 integer bits and 8 fractional.
                let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
                return Double(raw) / 256
            default:
                return nil
            }
        }
    }

    // MARK: - the AppleSMC user-client structures

    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    fileprivate struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}
