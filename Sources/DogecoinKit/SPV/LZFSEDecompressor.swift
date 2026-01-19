import Compression
import Foundation

/// Errors that can occur during LZFSE decompression
public enum LZFSEError: Error, Sendable {
    case failedToInitialize
    case decompressionFailed
    case unexpectedEndOfStream
    case failedToOpenFile(URL)
}

/// Streaming LZFSE decompressor for reading compressed header cache files
public enum LZFSEDecompressor {
    /// Buffer size for reading and decompressing chunks
    private static let bufferSize = 64 * 1024

    /// Decompress an LZFSE-compressed file and process chunks via a handler
    /// - Parameters:
    ///   - url: URL of the compressed file
    ///   - chunkHandler: Closure called with each decompressed chunk
    public static func decompress(from url: URL, chunkHandler: (Data) throws -> Void) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LZFSEError.failedToOpenFile(url)
        }
        defer { try? handle.close() }

        let streamHelper = try CompressionStreamHelper(operation: COMPRESSION_STREAM_DECODE, algorithm: COMPRESSION_LZFSE)
        defer { streamHelper.destroy() }

        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)
        var didFinish = false

        while true {
            let inputData = (try? handle.read(upToCount: bufferSize)) ?? Data()
            let isFinal = inputData.isEmpty

            try inputData.withUnsafeBytes { rawBuffer in
                if let srcPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    streamHelper.setSource(srcPtr, size: rawBuffer.count)
                } else {
                    streamHelper.setSourceEmpty()
                }

                let flags: Int32 = isFinal ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

                try outputBuffer.withUnsafeMutableBufferPointer { outputPtr in
                    guard let baseAddress = outputPtr.baseAddress else { return }

                    while true {
                        streamHelper.setDestination(baseAddress, size: outputPtr.count)

                        let processStatus = streamHelper.process(flags: flags)
                        if processStatus == COMPRESSION_STATUS_ERROR {
                            throw LZFSEError.decompressionFailed
                        }

                        let produced = outputPtr.count - streamHelper.destinationSize
                        if produced > 0 {
                            try chunkHandler(Data(outputPtr.prefix(produced)))
                        }

                        if processStatus == COMPRESSION_STATUS_END {
                            didFinish = true
                            break
                        }

                        if streamHelper.sourceSize == 0 {
                            break
                        }
                    }
                }
            }

            if didFinish {
                return
            }

            if isFinal {
                break
            }
        }

        if !didFinish {
            throw LZFSEError.unexpectedEndOfStream
        }
    }

    /// Decompress an entire LZFSE-compressed file into memory
    /// - Parameter url: URL of the compressed file
    /// - Returns: The decompressed data
    public static func decompress(from url: URL) throws -> Data {
        var result = Data()
        try decompress(from: url) { chunk in
            result.append(chunk)
        }
        return result
    }
}

/// Helper class to manage compression_stream lifecycle
private final class CompressionStreamHelper {
    private let streamPtr: UnsafeMutablePointer<compression_stream>
    private let dummyBuffer: UnsafeMutablePointer<UInt8>
    private var isInitialized = false

    init(operation: compression_stream_operation, algorithm: compression_algorithm) throws {
        // Allocate memory for the stream and dummy buffer
        streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        dummyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        dummyBuffer.pointee = 0

        // Zero-initialize the stream memory
        streamPtr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<compression_stream>.size) { ptr in
            ptr.initialize(repeating: 0, count: MemoryLayout<compression_stream>.size)
        }

        let status = compression_stream_init(streamPtr, operation, algorithm)
        guard status != COMPRESSION_STATUS_ERROR else {
            streamPtr.deallocate()
            dummyBuffer.deallocate()
            throw LZFSEError.failedToInitialize
        }
        isInitialized = true
    }

    func setSource(_ ptr: UnsafePointer<UInt8>, size: Int) {
        streamPtr.pointee.src_ptr = ptr
        streamPtr.pointee.src_size = size
    }

    func setSourceEmpty() {
        streamPtr.pointee.src_ptr = UnsafePointer(dummyBuffer)
        streamPtr.pointee.src_size = 0
    }

    func setDestination(_ ptr: UnsafeMutablePointer<UInt8>, size: Int) {
        streamPtr.pointee.dst_ptr = ptr
        streamPtr.pointee.dst_size = size
    }

    var sourceSize: Int {
        streamPtr.pointee.src_size
    }

    var destinationSize: Int {
        streamPtr.pointee.dst_size
    }

    func process(flags: Int32) -> compression_status {
        compression_stream_process(streamPtr, flags)
    }

    func destroy() {
        guard isInitialized else { return }
        compression_stream_destroy(streamPtr)
        isInitialized = false
        streamPtr.deallocate()
        dummyBuffer.deallocate()
    }
}
