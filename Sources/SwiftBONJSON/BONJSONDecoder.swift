import Foundation
import CKSBONJSON

/// An object that decodes instances of a data type from BONJSON data.
public final class BONJSONDecoder: @unchecked Sendable {

    /// The strategy to use for decoding `Date` values.
    public enum DateDecodingStrategy: Sendable {
        /// Decode the `Date` as a UNIX timestamp (seconds since 1970-01-01).
        case secondsSince1970
        /// Decode the `Date` as a UNIX timestamp (milliseconds since 1970-01-01).
        case millisecondsSince1970
        /// Decode the `Date` as an ISO8601 formatted string.
        case iso8601
        /// Decode the `Date` using a custom formatter.
        case formatted(DateFormatter)
        /// Decode the `Date` using a custom closure.
        case custom(@Sendable (any Decoder) throws -> Date)
    }

    /// The strategy to use for non-conforming floating-point values.
    public enum NonConformingFloatDecodingStrategy: Sendable {
        /// Throw an error upon encountering non-conforming values.
        case `throw`
        /// Decode the string as the associated non-conforming value.
        case convertFromString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The strategy used to decode dates. Defaults to `.secondsSince1970`.
    public var dateDecodingStrategy: DateDecodingStrategy = .secondsSince1970

    /// The strategy used for decoding non-conforming floats. Defaults to `.throw`.
    public var nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy = .throw

    /// Contextual user-provided information for use during decoding.
    public var userInfo: [CodingUserInfoKey: any Sendable] = [:]

    /// Creates a new, reusable BONJSON decoder.
    public init() {}

    /// Decodes a top-level value of the given type from the given BONJSON representation.
    ///
    /// - Parameters:
    ///   - type: The type of the value to decode.
    ///   - data: The BONJSON data to decode from.
    /// - Returns: A value of the requested type.
    /// - Throws: An error if any value throws an error during decoding.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let value = try parseBONJSON(data)
        let decoder = _BONJSONDecoder(value: value, options: _Options(
            dateDecodingStrategy: dateDecodingStrategy,
            nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
            userInfo: userInfo
        ))
        return try T(from: decoder)
    }

    private func parseBONJSON(_ data: Data) throws -> BONJSONValue {
        let parser = BONJSONParser()
        return try parser.parse(data)
    }
}

// MARK: - Internal Options

extension BONJSONDecoder {
    struct _Options {
        let dateDecodingStrategy: DateDecodingStrategy
        let nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy
        let userInfo: [CodingUserInfoKey: any Sendable]
    }
}

// MARK: - Decoding Error

/// An error that occurs during BONJSON decoding.
public enum BONJSONDecodingError: Error, CustomStringConvertible {
    case typeMismatch(Any.Type, DecodingError.Context)
    case valueNotFound(Any.Type, DecodingError.Context)
    case keyNotFound(any CodingKey, DecodingError.Context)
    case dataCorrupted(DecodingError.Context)
    case decoderError(String)

    public var description: String {
        switch self {
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(context.codingPath): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Value not found for \(type) at \(context.codingPath): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "Key '\(key.stringValue)' not found at \(context.codingPath): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "Data corrupted at \(context.codingPath): \(context.debugDescription)"
        case .decoderError(let message):
            return "Decoder error: \(message)"
        }
    }
}

// MARK: - BONJSON Value (Intermediate Representation)

internal enum BONJSONValue {
    case null
    case bool(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case float(Double)
    case bigNumber(significand: UInt64, exponent: Int32, isNegative: Bool)
    case string(String)
    case binary(Data)
    case array([BONJSONValue])
    case object([(String, BONJSONValue)])

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - BONJSON Parser

// Reference-type containers to avoid copy-on-write during parsing
private final class ArrayContainer {
    var elements: [BONJSONValue] = []
}

private final class ObjectContainer {
    var pairs: [(String, BONJSONValue)] = []
    var pendingKey: String?
}

private final class BONJSONParser {
    private var stack: [StackFrame] = []
    private var result: BONJSONValue?
    private var currentStringChunks: [String] = []
    private var isExpectingObjectName = false

    private enum StackFrame {
        case array(ArrayContainer)
        case object(ObjectContainer)
    }

    func parse(_ data: Data) throws -> BONJSONValue {
        stack = []
        result = nil
        currentStringChunks = []
        isExpectingObjectName = false

        var callbacks = KSBONJSONDecodeCallbacks()
        callbacks.onBoolean = { value, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.addValue(.bool(value))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onSignedInteger = { value, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.addValue(.signedInteger(value))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onUnsignedInteger = { value, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.addValue(.unsignedInteger(value))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onFloat = { value, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.addValue(.float(value))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onBigNumber = { value, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.addValue(.bigNumber(
                significand: value.significand,
                exponent: value.exponent,
                isNegative: value.significandSign < 0
            ))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onNull = { userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.addValue(.null)
            return KSBONJSON_DECODE_OK
        }
        callbacks.onString = { value, length, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            let string = String(
                decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(value)), count: length),
                as: UTF8.self
            )
            parser.addValue(.string(string))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onBinaryData = { data, length, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            let binaryData = Data(bytes: data!, count: length)
            parser.addValue(.binary(binaryData))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onStringChunk = { value, length, isLastChunk, userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            let chunk = String(
                decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(value)), count: length),
                as: UTF8.self
            )
            parser.currentStringChunks.append(chunk)
            if isLastChunk {
                let fullString = parser.currentStringChunks.joined()
                parser.currentStringChunks.removeAll()
                parser.addValue(.string(fullString))
            }
            return KSBONJSON_DECODE_OK
        }
        callbacks.onBeginArray = { userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.stack.append(.array(ArrayContainer()))
            return KSBONJSON_DECODE_OK
        }
        callbacks.onBeginObject = { userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            parser.stack.append(.object(ObjectContainer()))
            parser.isExpectingObjectName = true
            return KSBONJSON_DECODE_OK
        }
        callbacks.onEndContainer = { userData in
            let parser = Unmanaged<BONJSONParser>.fromOpaque(userData!).takeUnretainedValue()
            guard let frame = parser.stack.popLast() else {
                return KSBONJSON_DECODE_UNBALANCED_CONTAINERS
            }

            let value: BONJSONValue
            switch frame {
            case .array(let container):
                value = .array(container.elements)
            case .object(let container):
                value = .object(container.pairs)
            }

            // Update isExpectingObjectName based on parent container
            if case .object = parser.stack.last {
                parser.isExpectingObjectName = false
            }

            parser.addValue(value)
            return KSBONJSON_DECODE_OK
        }
        callbacks.onEndData = { userData in
            return KSBONJSON_DECODE_OK
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var decodedOffset: Int = 0

        let status = data.withUnsafeBytes { buffer -> ksbonjson_decodeStatus in
            guard let baseAddress = buffer.baseAddress else {
                return KSBONJSON_DECODE_INVALID_DATA
            }
            return ksbonjson_decode(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                buffer.count,
                &callbacks,
                selfPtr,
                &decodedOffset
            )
        }

        guard status == KSBONJSON_DECODE_OK else {
            let description = String(cString: ksbonjson_describeDecodeStatus(status))
            throw BONJSONDecodingError.decoderError(description)
        }

        guard let value = result else {
            throw BONJSONDecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "No value decoded from BONJSON data"
            ))
        }

        return value
    }

    private func addValue(_ value: BONJSONValue) {
        if stack.isEmpty {
            result = value
            return
        }

        switch stack[stack.count - 1] {
        case .array(let container):
            // Direct mutation - no copy because container is a reference type
            container.elements.append(value)
        case .object(let container):
            if isExpectingObjectName {
                // This value should be a string key
                if case .string(let key) = value {
                    container.pendingKey = key
                    isExpectingObjectName = false
                }
            } else if let key = container.pendingKey {
                container.pairs.append((key, value))
                container.pendingKey = nil
                isExpectingObjectName = true
            }
        }
    }
}

// MARK: - Internal Decoder

private final class _BONJSONDecoder: Decoder {
    var codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { options.userInfo }

    let value: BONJSONValue
    let options: BONJSONDecoder._Options

    init(value: BONJSONValue, options: BONJSONDecoder._Options, codingPath: [any CodingKey] = []) {
        self.value = value
        self.options = options
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let pairs) = value else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                DecodingError.Context(codingPath: codingPath, debugDescription: "Expected object but found \(value)")
            )
        }
        let container = _BONJSONKeyedDecodingContainer<Key>(
            decoder: self,
            pairs: pairs,
            codingPath: codingPath
        )
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw DecodingError.typeMismatch(
                [Any].self,
                DecodingError.Context(codingPath: codingPath, debugDescription: "Expected array but found \(value)")
            )
        }
        return _BONJSONUnkeyedDecodingContainer(
            decoder: self,
            elements: elements,
            codingPath: codingPath
        )
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        return _BONJSONSingleValueDecodingContainer(
            decoder: self,
            value: value,
            codingPath: codingPath
        )
    }

    // MARK: - Value extraction helpers

    func unboxBool(_ value: BONJSONValue) throws -> Bool {
        guard case .bool(let bool) = value else {
            throw DecodingError.typeMismatch(Bool.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected Bool but found \(value)"
            ))
        }
        return bool
    }

    func unboxString(_ value: BONJSONValue) throws -> String {
        guard case .string(let string) = value else {
            throw DecodingError.typeMismatch(String.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected String but found \(value)"
            ))
        }
        return string
    }

    func unboxInt(_ value: BONJSONValue) throws -> Int {
        switch value {
        case .signedInteger(let int):
            guard let result = Int(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to Int"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = Int(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to Int"
                ))
            }
            return result
        case .float(let double):
            guard let result = Int(exactly: double) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(double) cannot be converted to Int"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(Int.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxInt8(_ value: BONJSONValue) throws -> Int8 {
        switch value {
        case .signedInteger(let int):
            guard let result = Int8(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to Int8"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = Int8(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to Int8"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(Int8.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxInt16(_ value: BONJSONValue) throws -> Int16 {
        switch value {
        case .signedInteger(let int):
            guard let result = Int16(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to Int16"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = Int16(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to Int16"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(Int16.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxInt32(_ value: BONJSONValue) throws -> Int32 {
        switch value {
        case .signedInteger(let int):
            guard let result = Int32(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to Int32"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = Int32(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to Int32"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(Int32.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxInt64(_ value: BONJSONValue) throws -> Int64 {
        switch value {
        case .signedInteger(let int):
            return int
        case .unsignedInteger(let uint):
            guard let result = Int64(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to Int64"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(Int64.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxUInt(_ value: BONJSONValue) throws -> UInt {
        switch value {
        case .signedInteger(let int):
            guard let result = UInt(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to UInt"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = UInt(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to UInt"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(UInt.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxUInt8(_ value: BONJSONValue) throws -> UInt8 {
        switch value {
        case .signedInteger(let int):
            guard let result = UInt8(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to UInt8"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = UInt8(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to UInt8"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(UInt8.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxUInt16(_ value: BONJSONValue) throws -> UInt16 {
        switch value {
        case .signedInteger(let int):
            guard let result = UInt16(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to UInt16"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = UInt16(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to UInt16"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(UInt16.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxUInt32(_ value: BONJSONValue) throws -> UInt32 {
        switch value {
        case .signedInteger(let int):
            guard let result = UInt32(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to UInt32"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            guard let result = UInt32(exactly: uint) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(uint) cannot be converted to UInt32"
                ))
            }
            return result
        default:
            throw DecodingError.typeMismatch(UInt32.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxUInt64(_ value: BONJSONValue) throws -> UInt64 {
        switch value {
        case .signedInteger(let int):
            guard let result = UInt64(exactly: int) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(int) cannot be converted to UInt64"
                ))
            }
            return result
        case .unsignedInteger(let uint):
            return uint
        default:
            throw DecodingError.typeMismatch(UInt64.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value)"
            ))
        }
    }

    func unboxFloat(_ value: BONJSONValue) throws -> Float {
        switch value {
        case .float(let double):
            return Float(double)
        case .signedInteger(let int):
            return Float(int)
        case .unsignedInteger(let uint):
            return Float(uint)
        case .string(let string):
            // Check for non-conforming float strings
            if case .convertFromString(let posInf, let negInf, let nan) = options.nonConformingFloatDecodingStrategy {
                if string == posInf { return .infinity }
                if string == negInf { return -.infinity }
                if string == nan { return .nan }
            }
            throw DecodingError.typeMismatch(Float.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected Float but found string '\(string)'"
            ))
        default:
            throw DecodingError.typeMismatch(Float.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected Float but found \(value)"
            ))
        }
    }

    func unboxDouble(_ value: BONJSONValue) throws -> Double {
        switch value {
        case .float(let double):
            return double
        case .signedInteger(let int):
            return Double(int)
        case .unsignedInteger(let uint):
            return Double(uint)
        case .bigNumber(let significand, let exponent, let isNegative):
            let sign: Double = isNegative ? -1 : 1
            return sign * Double(significand) * pow(10, Double(exponent))
        case .string(let string):
            // Check for non-conforming float strings
            if case .convertFromString(let posInf, let negInf, let nan) = options.nonConformingFloatDecodingStrategy {
                if string == posInf { return .infinity }
                if string == negInf { return -.infinity }
                if string == nan { return .nan }
            }
            throw DecodingError.typeMismatch(Double.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected Double but found string '\(string)'"
            ))
        default:
            throw DecodingError.typeMismatch(Double.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected Double but found \(value)"
            ))
        }
    }

    func unboxDate(_ value: BONJSONValue) throws -> Date {
        switch options.dateDecodingStrategy {
        case .secondsSince1970:
            let double = try unboxDouble(value)
            return Date(timeIntervalSince1970: double)
        case .millisecondsSince1970:
            let double = try unboxDouble(value)
            return Date(timeIntervalSince1970: double / 1000)
        case .iso8601:
            let string = try unboxString(value)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = .withInternetDateTime
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Invalid ISO8601 date string: \(string)"
                ))
            }
            return date
        case .formatted(let formatter):
            let string = try unboxString(value)
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Invalid date string: \(string)"
                ))
            }
            return date
        case .custom(let closure):
            let decoder = _BONJSONDecoder(value: value, options: options, codingPath: codingPath)
            return try closure(decoder)
        }
    }

    func unboxData(_ value: BONJSONValue) throws -> Data {
        guard case .binary(let data) = value else {
            throw DecodingError.typeMismatch(Data.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected binary data but found \(value)"
            ))
        }
        return data
    }

    func unboxURL(_ value: BONJSONValue) throws -> URL {
        let string = try unboxString(value)
        guard let url = URL(string: string) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Invalid URL string: \(string)"
            ))
        }
        return url
    }

    func unboxDecodable<T: Decodable>(_ value: BONJSONValue, as type: T.Type) throws -> T {
        if type == Date.self {
            return try unboxDate(value) as! T
        } else if type == Data.self {
            return try unboxData(value) as! T
        } else if type == URL.self {
            return try unboxURL(value) as! T
        }

        let decoder = _BONJSONDecoder(value: value, options: options, codingPath: codingPath)
        return try T(from: decoder)
    }
}

// MARK: - Keyed Decoding Container

private struct _BONJSONKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    private let decoder: _BONJSONDecoder
    private let pairs: [(String, BONJSONValue)]
    var codingPath: [any CodingKey]

    var allKeys: [Key] {
        pairs.compactMap { Key(stringValue: $0.0) }
    }

    init(decoder: _BONJSONDecoder, pairs: [(String, BONJSONValue)], codingPath: [any CodingKey]) {
        self.decoder = decoder
        self.pairs = pairs
        self.codingPath = codingPath
    }

    private func value(forKey key: Key) -> BONJSONValue? {
        for (k, v) in pairs {
            if k == key.stringValue {
                return v
            }
        }
        return nil
    }

    func contains(_ key: Key) -> Bool {
        value(forKey: key) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return v.isNull
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxBool(v)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxString(v)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxDouble(v)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxFloat(v)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxInt(v)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxInt8(v)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxInt16(v)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxInt32(v)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxInt64(v)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxUInt(v)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxUInt8(v)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxUInt16(v)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxUInt32(v)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxUInt64(v)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return try decoder.unboxDecodable(v, as: type)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        guard case .object(let pairs) = v else {
            throw DecodingError.typeMismatch([String: Any].self, DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected object but found \(v)"
            ))
        }
        let container = _BONJSONKeyedDecodingContainer<NestedKey>(
            decoder: decoder,
            pairs: pairs,
            codingPath: codingPath + [key]
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        guard case .array(let elements) = v else {
            throw DecodingError.typeMismatch([Any].self, DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected array but found \(v)"
            ))
        }
        return _BONJSONUnkeyedDecodingContainer(
            decoder: decoder,
            elements: elements,
            codingPath: codingPath + [key]
        )
    }

    func superDecoder() throws -> any Decoder {
        decoder
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        guard let v = value(forKey: key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return _BONJSONDecoder(value: v, options: decoder.options, codingPath: codingPath + [key])
    }
}

// MARK: - Unkeyed Decoding Container

private struct _BONJSONUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    private let decoder: _BONJSONDecoder
    private let elements: [BONJSONValue]
    var codingPath: [any CodingKey]
    var currentIndex: Int = 0

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    init(decoder: _BONJSONDecoder, elements: [BONJSONValue], codingPath: [any CodingKey]) {
        self.decoder = decoder
        self.elements = elements
        self.codingPath = codingPath
    }

    private mutating func nextValue() throws -> BONJSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Any.self, DecodingError.Context(
                codingPath: codingPath + [_BONJSONKey(index: currentIndex)],
                debugDescription: "Unkeyed container is at end"
            ))
        }
        let value = elements[currentIndex]
        currentIndex += 1
        return value
    }

    mutating func decodeNil() throws -> Bool {
        let value = try nextValue()
        if value.isNull {
            return true
        }
        currentIndex -= 1
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let value = try nextValue()
        return try decoder.unboxBool(value)
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let value = try nextValue()
        return try decoder.unboxString(value)
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let value = try nextValue()
        return try decoder.unboxDouble(value)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        let value = try nextValue()
        return try decoder.unboxFloat(value)
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        let value = try nextValue()
        return try decoder.unboxInt(value)
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        let value = try nextValue()
        return try decoder.unboxInt8(value)
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        let value = try nextValue()
        return try decoder.unboxInt16(value)
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        let value = try nextValue()
        return try decoder.unboxInt32(value)
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let value = try nextValue()
        return try decoder.unboxInt64(value)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        let value = try nextValue()
        return try decoder.unboxUInt(value)
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let value = try nextValue()
        return try decoder.unboxUInt8(value)
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let value = try nextValue()
        return try decoder.unboxUInt16(value)
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let value = try nextValue()
        return try decoder.unboxUInt32(value)
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let value = try nextValue()
        return try decoder.unboxUInt64(value)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let value = try nextValue()
        return try decoder.unboxDecodable(value, as: type)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let value = try nextValue()
        guard case .object(let pairs) = value else {
            throw DecodingError.typeMismatch([String: Any].self, DecodingError.Context(
                codingPath: codingPath + [_BONJSONKey(index: currentIndex - 1)],
                debugDescription: "Expected object but found \(value)"
            ))
        }
        let container = _BONJSONKeyedDecodingContainer<NestedKey>(
            decoder: decoder,
            pairs: pairs,
            codingPath: codingPath + [_BONJSONKey(index: currentIndex - 1)]
        )
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let value = try nextValue()
        guard case .array(let elements) = value else {
            throw DecodingError.typeMismatch([Any].self, DecodingError.Context(
                codingPath: codingPath + [_BONJSONKey(index: currentIndex - 1)],
                debugDescription: "Expected array but found \(value)"
            ))
        }
        return _BONJSONUnkeyedDecodingContainer(
            decoder: decoder,
            elements: elements,
            codingPath: codingPath + [_BONJSONKey(index: currentIndex - 1)]
        )
    }

    mutating func superDecoder() throws -> any Decoder {
        decoder
    }
}

// MARK: - Single Value Decoding Container

private struct _BONJSONSingleValueDecodingContainer: SingleValueDecodingContainer {
    private let decoder: _BONJSONDecoder
    private let value: BONJSONValue
    var codingPath: [any CodingKey]

    init(decoder: _BONJSONDecoder, value: BONJSONValue, codingPath: [any CodingKey]) {
        self.decoder = decoder
        self.value = value
        self.codingPath = codingPath
    }

    func decodeNil() -> Bool {
        value.isNull
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try decoder.unboxBool(value)
    }

    func decode(_ type: String.Type) throws -> String {
        try decoder.unboxString(value)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decoder.unboxDouble(value)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try decoder.unboxFloat(value)
    }

    func decode(_ type: Int.Type) throws -> Int {
        try decoder.unboxInt(value)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try decoder.unboxInt8(value)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try decoder.unboxInt16(value)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try decoder.unboxInt32(value)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try decoder.unboxInt64(value)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try decoder.unboxUInt(value)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try decoder.unboxUInt8(value)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try decoder.unboxUInt16(value)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try decoder.unboxUInt32(value)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decoder.unboxUInt64(value)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try decoder.unboxDecodable(value, as: type)
    }
}
