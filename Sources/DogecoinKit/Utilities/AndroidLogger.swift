#if canImport(Android)
import Android

/// Android's stand-in for `os.Logger`: the same call sites, written to
/// logcat under the tag `<subsystem>.<category>`.
///
/// Release builds behave like the unified log on Apple platforms: debug
/// messages are dropped, and interpolated values are redacted as
/// `<private>` unless they are numbers or Booleans or marked
/// `privacy: .public`. Debug builds log everything, as Xcode's console does.
struct Logger: Sendable {
    private let tag: String

    init(subsystem: String, category: String) {
        tag = "\(subsystem).\(category)"
    }

    func debug(_ message: @autoclosure () -> LogMessage) {
        #if DEBUG
        write(message(), priority: ANDROID_LOG_DEBUG)
        #endif
    }

    func info(_ message: LogMessage) {
        write(message, priority: ANDROID_LOG_INFO)
    }

    func notice(_ message: LogMessage) {
        write(message, priority: ANDROID_LOG_INFO)
    }

    func warning(_ message: LogMessage) {
        write(message, priority: ANDROID_LOG_WARN)
    }

    func error(_ message: LogMessage) {
        write(message, priority: ANDROID_LOG_ERROR)
    }

    private func write(_ message: LogMessage, priority: android_LogPriority) {
        _ = __android_log_write(Int32(priority.rawValue), tag, message.text)
    }
}

/// How an interpolated value appears in a release-build log, mirroring
/// `OSLogPrivacy`.
enum LogPrivacy {
    case `public`
    case `private`
    /// Public for numbers and Booleans, private for everything else.
    case auto
}

/// A log message built by string interpolation, taking the `privacy:`
/// arguments `os.Logger` does.
struct LogMessage: ExpressibleByStringInterpolation {
    fileprivate let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: some Any, privacy: LogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy == .public)
        }

        mutating func appendInterpolation(_ value: some Numeric, privacy: LogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy != .private)
        }

        mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .auto) {
            append(String(value), isPublic: privacy != .private)
        }

        private mutating func append(_ description: String, isPublic: Bool) {
            #if DEBUG
            text += description
            #else
            text += isPublic ? description : "<private>"
            #endif
        }
    }
}
#endif
