import Foundation

/// Splits a byte stream into LF-terminated records (strips a trailing CR).
/// Splits on the LF byte only, so U+2028/U+2029 inside JSON strings are never record boundaries.
public struct LineFramer: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}
