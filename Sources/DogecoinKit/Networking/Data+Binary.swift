import Foundation

extension Data {
    func readInteger<T: FixedWidthInteger>(at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, count >= offset + size else { return nil }

        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { (buffer: UnsafeMutableRawBufferPointer) in
            _ = copyBytes(to: buffer, from: offset..<(offset + size))
        }

        return value
    }
}
