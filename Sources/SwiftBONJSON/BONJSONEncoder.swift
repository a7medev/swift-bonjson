import Foundation
import CKSBONJSON

/// An object that encodes instances of a data type as BONJSON data.
public final class BONJSONEncoder {

    /// The strategy to use for encoding `Date` values.
    public enum DateEncodingStrategy: Sendable {
        /// Encode the `Date` as a UNIX timestamp (seconds since 1970-01-01).
        case secondsSince1970
        /// Encode the `Date` as a UNIX timestamp (milliseconds since 1970-01-01).
        case millisecondsSince1970
        /// Encode the `Date` as an ISO8601 formatted string.
        case iso8601
        /// Encode the `Date` using a custom formatter.
        case formatted(DateFormatter)
        /// Encode the `Date` using a custom closure.
        case custom(@Sendable (Date, any Encoder) throws -> Void)
    }

    /// The strategy to use for encoding `Data` values.
    public enum DataEncodingStrategy: Sendable {
        /// Encode the `Data` as a Base64 encoded string.
        case base64
        /// Encode the `Data` using a custom closure.
        case custom(@Sendable (Data, any Encoder) throws -> Void)
    }

    /// The strategy to use for non-conforming floating-point values.
    public enum NonConformingFloatEncodingStrategy: Sendable {
        /// Throw an error upon encountering non-conforming values.
        case `throw`
        /// Convert to a given string.
        case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The strategy used to encode dates. Defaults to `.secondsSince1970`.
    public var dateEncodingStrategy: DateEncodingStrategy = .secondsSince1970

    /// The strategy used to encode Data values. Defaults to `.base64`.
    public var dataEncodingStrategy: DataEncodingStrategy = .base64

    /// The strategy used for encoding non-conforming floats. Defaults to `.throw`.
    public var nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy = .throw

    /// Contextual user-provided information for use during encoding.
    public var userInfo: [CodingUserInfoKey: any Sendable] = [:]

    /// Creates a new, reusable BONJSON encoder.
    public init() {}

    /// Encodes the given top-level value and returns its BONJSON representation.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: A new `Data` value containing the encoded BONJSON data.
    /// - Throws: An error if any value throws an error during encoding.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let impl = _BONJSONEncoderImpl(options: _Options(
            dateEncodingStrategy: dateEncodingStrategy,
            dataEncodingStrategy: dataEncodingStrategy,
            nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy,
            userInfo: userInfo
        ))

        try impl.encodeTopLevel(value)
        return try impl.finalize()
    }
}

// MARK: - Internal Options

extension BONJSONEncoder {
    struct _Options {
        let dateEncodingStrategy: DateEncodingStrategy
        let dataEncodingStrategy: DataEncodingStrategy
        let nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy
        let userInfo: [CodingUserInfoKey: any Sendable]
    }
}

// MARK: - Encoding Error

/// An error that occurs during BONJSON encoding.
public enum BONJSONEncodingError: Error, CustomStringConvertible {
    case invalidValue(Any, EncodingError.Context)
    case encoderError(String)

    public var description: String {
        switch self {
        case .invalidValue(let value, let context):
            return "Invalid value '\(value)' at \(context.codingPath): \(context.debugDescription)"
        case .encoderError(let message):
            return "Encoder error: \(message)"
        }
    }
}

// MARK: - Container State Tracking

private final class _ContainerState {
    enum ContainerKind {
        case none
        case keyed
        case unkeyed
    }
    var kind: ContainerKind = .none
    var started: Bool = false
}

// MARK: - Internal Encoder Implementation

private final class _BONJSONEncoderImpl {
    let options: BONJSONEncoder._Options
    private var context: KSBONJSONEncodeContext
    private var buffer: [UInt8]

    init(options: BONJSONEncoder._Options) {
        self.options = options
        self.buffer = []
        self.context = KSBONJSONEncodeContext()

        // Initialize the encoder context
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        ksbonjson_beginEncode(&context, { data, length, userData in
            guard let data = data, let userData = userData else {
                return KSBONJSON_ENCODE_NULL_POINTER
            }
            let encoder = Unmanaged<_BONJSONEncoderImpl>.fromOpaque(userData).takeUnretainedValue()
            encoder.buffer.append(contentsOf: UnsafeBufferPointer(start: data, count: length))
            return KSBONJSON_ENCODE_OK
        }, selfPtr)
    }

    func encodeTopLevel<T: Encodable>(_ value: T) throws {
        try encodeValue(value, at: [])
    }

    func encodeValue<T: Encodable>(_ value: T, at codingPath: [any CodingKey]) throws {
        // Handle special types
        if let date = value as? Date {
            try encodeDate(date, at: codingPath)
        } else if let data = value as? Data {
            try encodeData(data)
        } else if let url = value as? URL {
            try encode(url.absoluteString)
        } else {
            // Use a tracking encoder to detect what container type is used
            let tracker = _BONJSONTrackingEncoder(impl: self, codingPath: codingPath)
            try value.encode(to: tracker)

            // Close any container that was opened, or handle empty containers
            if tracker.containerState.started {
                try endContainer()
            } else if tracker.containerState.kind != .none {
                // Container was requested but not started (empty container)
                switch tracker.containerState.kind {
                case .keyed:
                    try beginObject()
                    try endContainer()
                case .unkeyed:
                    try beginArray()
                    try endContainer()
                case .none:
                    break
                }
            }
        }
    }

    private func encodeDate(_ date: Date, at codingPath: [any CodingKey]) throws {
        switch options.dateEncodingStrategy {
        case .secondsSince1970:
            try encode(date.timeIntervalSince1970, codingPath: codingPath)
        case .millisecondsSince1970:
            try encode(date.timeIntervalSince1970 * 1000, codingPath: codingPath)
        case .iso8601:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = .withInternetDateTime
            try encode(formatter.string(from: date))
        case .formatted(let formatter):
            try encode(formatter.string(from: date))
        case .custom(let closure):
            let wrapper = _BONJSONTrackingEncoder(impl: self, codingPath: codingPath)
            try closure(date, wrapper)
            if wrapper.containerState.started {
                try endContainer()
            }
        }
    }

    private func encodeData(_ data: Data) throws {
        switch options.dataEncodingStrategy {
        case .base64:
            try encode(data.base64EncodedString())
        case .custom(let closure):
            let wrapper = _BONJSONTrackingEncoder(impl: self, codingPath: [])
            try closure(data, wrapper)
            if wrapper.containerState.started {
                try endContainer()
            }
        }
    }

    // MARK: - Primitive encoding methods

    func beginObject() throws {
        let status = ksbonjson_beginObject(&context)
        try checkStatus(status)
    }

    func beginArray() throws {
        let status = ksbonjson_beginArray(&context)
        try checkStatus(status)
    }

    func endContainer() throws {
        let status = ksbonjson_endContainer(&context)
        try checkStatus(status)
    }

    func encodeNil() throws {
        let status = ksbonjson_addNull(&context)
        try checkStatus(status)
    }

    func encode(_ value: Bool) throws {
        let status = ksbonjson_addBoolean(&context, value)
        try checkStatus(status)
    }

    func encode(_ value: String) throws {
        let status = value.withCString { cString in
            ksbonjson_addString(&context, cString, value.utf8.count)
        }
        try checkStatus(status)
    }

    func encode(_ value: Int) throws {
        let status = ksbonjson_addSignedInteger(&context, Int64(value))
        try checkStatus(status)
    }

    func encode(_ value: Int8) throws {
        let status = ksbonjson_addSignedInteger(&context, Int64(value))
        try checkStatus(status)
    }

    func encode(_ value: Int16) throws {
        let status = ksbonjson_addSignedInteger(&context, Int64(value))
        try checkStatus(status)
    }

    func encode(_ value: Int32) throws {
        let status = ksbonjson_addSignedInteger(&context, Int64(value))
        try checkStatus(status)
    }

    func encode(_ value: Int64) throws {
        let status = ksbonjson_addSignedInteger(&context, value)
        try checkStatus(status)
    }

    func encode(_ value: UInt) throws {
        let status = ksbonjson_addUnsignedInteger(&context, UInt64(value))
        try checkStatus(status)
    }

    func encode(_ value: UInt8) throws {
        let status = ksbonjson_addUnsignedInteger(&context, UInt64(value))
        try checkStatus(status)
    }

    func encode(_ value: UInt16) throws {
        let status = ksbonjson_addUnsignedInteger(&context, UInt64(value))
        try checkStatus(status)
    }

    func encode(_ value: UInt32) throws {
        let status = ksbonjson_addUnsignedInteger(&context, UInt64(value))
        try checkStatus(status)
    }

    func encode(_ value: UInt64) throws {
        let status = ksbonjson_addUnsignedInteger(&context, value)
        try checkStatus(status)
    }

    func encode(_ value: Float, codingPath: [any CodingKey]) throws {
        guard value.isFinite else {
            try handleNonConformingFloat(Double(value), codingPath: codingPath)
            return
        }
        let status = ksbonjson_addFloat(&context, Double(value))
        try checkStatus(status)
    }

    func encode(_ value: Double, codingPath: [any CodingKey]) throws {
        guard value.isFinite else {
            try handleNonConformingFloat(value, codingPath: codingPath)
            return
        }
        let status = ksbonjson_addFloat(&context, value)
        try checkStatus(status)
    }

    private func handleNonConformingFloat(_ value: Double, codingPath: [any CodingKey]) throws {
        switch options.nonConformingFloatEncodingStrategy {
        case .throw:
            throw BONJSONEncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unable to encode \(value) directly in BONJSON. Use NonConformingFloatEncodingStrategy.convertToString to convert to a string representation."
            ))
        case .convertToString(let posInf, let negInf, let nan):
            let string: String
            if value.isNaN {
                string = nan
            } else if value == .infinity {
                string = posInf
            } else {
                string = negInf
            }
            try encode(string)
        }
    }

    private func checkStatus(_ status: ksbonjson_encodeStatus) throws {
        guard status == KSBONJSON_ENCODE_OK else {
            let description = String(cString: ksbonjson_describeEncodeStatus(status))
            throw BONJSONEncodingError.encoderError(description)
        }
    }

    func finalize() throws -> Data {
        let status = ksbonjson_endEncode(&context)
        try checkStatus(status)
        return Data(buffer)
    }
}

// MARK: - Tracking Encoder (Encoder protocol)

private struct _BONJSONTrackingEncoder: Encoder {
    let impl: _BONJSONEncoderImpl
    var codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { impl.options.userInfo }
    let containerState: _ContainerState

    init(impl: _BONJSONEncoderImpl, codingPath: [any CodingKey]) {
        self.impl = impl
        self.codingPath = codingPath
        self.containerState = _ContainerState()
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        containerState.kind = .keyed
        let container = _BONJSONKeyedEncodingContainer<Key>(impl: impl, codingPath: codingPath, state: containerState)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        containerState.kind = .unkeyed
        return _BONJSONUnkeyedEncodingContainer(impl: impl, codingPath: codingPath, state: containerState)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        return _BONJSONSingleValueEncodingContainer(impl: impl, codingPath: codingPath)
    }
}

// MARK: - Keyed Encoding Container

private struct _BONJSONKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let impl: _BONJSONEncoderImpl
    var codingPath: [any CodingKey]
    let state: _ContainerState

    init(impl: _BONJSONEncoderImpl, codingPath: [any CodingKey], state: _ContainerState) {
        self.impl = impl
        self.codingPath = codingPath
        self.state = state
    }

    private func ensureStarted() throws {
        if !state.started {
            try impl.beginObject()
            state.started = true
        }
    }

    mutating func encodeNil(forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encodeNil()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value, codingPath: codingPath + [key])
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value, codingPath: codingPath + [key])
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encode(value)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try ensureStarted()
        try impl.encode(key.stringValue)
        try impl.encodeValue(value, at: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        do {
            try ensureStarted()
            try impl.encode(key.stringValue)
        } catch {
            // Error will surface when container is used
        }
        let nestedState = _ContainerState()
        let container = _BONJSONKeyedEncodingContainer<NestedKey>(
            impl: impl,
            codingPath: codingPath + [key],
            state: nestedState
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        do {
            try ensureStarted()
            try impl.encode(key.stringValue)
        } catch {
            // Error will surface when container is used
        }
        let nestedState = _ContainerState()
        return _BONJSONUnkeyedEncodingContainer(
            impl: impl,
            codingPath: codingPath + [key],
            state: nestedState
        )
    }

    mutating func superEncoder() -> any Encoder {
        _BONJSONTrackingEncoder(impl: impl, codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        _BONJSONTrackingEncoder(impl: impl, codingPath: codingPath + [key])
    }
}

// MARK: - Unkeyed Encoding Container

private struct _BONJSONUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let impl: _BONJSONEncoderImpl
    var codingPath: [any CodingKey]
    var count: Int = 0
    let state: _ContainerState

    init(impl: _BONJSONEncoderImpl, codingPath: [any CodingKey], state: _ContainerState) {
        self.impl = impl
        self.codingPath = codingPath
        self.state = state
    }

    private func ensureStarted() throws {
        if !state.started {
            try impl.beginArray()
            state.started = true
        }
    }

    mutating func encodeNil() throws {
        try ensureStarted()
        try impl.encodeNil()
        count += 1
    }

    mutating func encode(_ value: Bool) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: String) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: Double) throws {
        try ensureStarted()
        try impl.encode(value, codingPath: codingPath + [_BONJSONKey(index: count)])
        count += 1
    }

    mutating func encode(_ value: Float) throws {
        try ensureStarted()
        try impl.encode(value, codingPath: codingPath + [_BONJSONKey(index: count)])
        count += 1
    }

    mutating func encode(_ value: Int) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: Int8) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: Int16) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: Int32) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: Int64) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: UInt) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: UInt8) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: UInt16) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: UInt32) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode(_ value: UInt64) throws {
        try ensureStarted()
        try impl.encode(value)
        count += 1
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try ensureStarted()
        try impl.encodeValue(value, at: codingPath + [_BONJSONKey(index: count)])
        count += 1
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        do {
            try ensureStarted()
        } catch {
            // Error will surface when container is used
        }
        let currentIndex = count
        count += 1
        let nestedState = _ContainerState()
        let container = _BONJSONKeyedEncodingContainer<NestedKey>(
            impl: impl,
            codingPath: codingPath + [_BONJSONKey(index: currentIndex)],
            state: nestedState
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        do {
            try ensureStarted()
        } catch {
            // Error will surface when container is used
        }
        let currentIndex = count
        count += 1
        let nestedState = _ContainerState()
        return _BONJSONUnkeyedEncodingContainer(
            impl: impl,
            codingPath: codingPath + [_BONJSONKey(index: currentIndex)],
            state: nestedState
        )
    }

    mutating func superEncoder() -> any Encoder {
        _BONJSONTrackingEncoder(impl: impl, codingPath: codingPath)
    }
}

// MARK: - Single Value Encoding Container

private struct _BONJSONSingleValueEncodingContainer: SingleValueEncodingContainer {
    let impl: _BONJSONEncoderImpl
    var codingPath: [any CodingKey]

    func encodeNil() throws {
        try impl.encodeNil()
    }

    func encode(_ value: Bool) throws {
        try impl.encode(value)
    }

    func encode(_ value: String) throws {
        try impl.encode(value)
    }

    func encode(_ value: Double) throws {
        try impl.encode(value, codingPath: codingPath)
    }

    func encode(_ value: Float) throws {
        try impl.encode(value, codingPath: codingPath)
    }

    func encode(_ value: Int) throws {
        try impl.encode(value)
    }

    func encode(_ value: Int8) throws {
        try impl.encode(value)
    }

    func encode(_ value: Int16) throws {
        try impl.encode(value)
    }

    func encode(_ value: Int32) throws {
        try impl.encode(value)
    }

    func encode(_ value: Int64) throws {
        try impl.encode(value)
    }

    func encode(_ value: UInt) throws {
        try impl.encode(value)
    }

    func encode(_ value: UInt8) throws {
        try impl.encode(value)
    }

    func encode(_ value: UInt16) throws {
        try impl.encode(value)
    }

    func encode(_ value: UInt32) throws {
        try impl.encode(value)
    }

    func encode(_ value: UInt64) throws {
        try impl.encode(value)
    }

    func encode<T: Encodable>(_ value: T) throws {
        try impl.encodeValue(value, at: codingPath)
    }
}

// MARK: - Internal Coding Key

internal struct _BONJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

    init(index: Int) {
        self.stringValue = "Index \(index)"
        self.intValue = index
    }
}
