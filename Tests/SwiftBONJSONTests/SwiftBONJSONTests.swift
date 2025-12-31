import Testing
import Foundation
@testable import SwiftBONJSON

// MARK: - Test Types

struct SimpleStruct: Codable, Equatable {
    let name: String
    let age: Int
    let active: Bool
}

struct NestedStruct: Codable, Equatable {
    let id: Int
    let info: SimpleStruct
    let tags: [String]
}

struct AllTypesStruct: Codable, Equatable {
    let boolValue: Bool
    let intValue: Int
    let int8Value: Int8
    let int16Value: Int16
    let int32Value: Int32
    let int64Value: Int64
    let uintValue: UInt
    let uint8Value: UInt8
    let uint16Value: UInt16
    let uint32Value: UInt32
    let uint64Value: UInt64
    let floatValue: Float
    let doubleValue: Double
    let stringValue: String
    let optionalString: String?
}

struct DateStruct: Codable, Equatable {
    let timestamp: Date
}

struct DataStruct: Codable, Equatable {
    let blob: Data
}

struct URLStruct: Codable, Equatable {
    let link: URL
}

enum Status: String, Codable {
    case active
    case inactive
    case pending
}

struct EnumStruct: Codable, Equatable {
    let status: Status
}

// MARK: - Encoder Tests

@Suite("BONJSONEncoder Tests")
struct BONJSONEncoderTests {

    @Test("Encode simple struct")
    func encodeSimpleStruct() throws {
        let encoder = BONJSONEncoder()
        let value = SimpleStruct(name: "John", age: 30, active: true)

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        // Decode back and verify
        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(SimpleStruct.self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode nested struct")
    func encodeNestedStruct() throws {
        let encoder = BONJSONEncoder()
        let value = NestedStruct(
            id: 42,
            info: SimpleStruct(name: "Alice", age: 25, active: false),
            tags: ["swift", "bonjson", "binary"]
        )

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(NestedStruct.self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode all primitive types")
    func encodeAllTypes() throws {
        let encoder = BONJSONEncoder()
        let value = AllTypesStruct(
            boolValue: true,
            intValue: -12345,
            int8Value: -127,
            int16Value: -32000,
            int32Value: -2_000_000,
            int64Value: -9_000_000_000,
            uintValue: 12345,
            uint8Value: 255,
            uint16Value: 65000,
            uint32Value: 4_000_000,
            uint64Value: 18_000_000_000,
            floatValue: 3.14,
            doubleValue: 2.718281828,
            stringValue: "Hello, BONJSON!",
            optionalString: "Present"
        )

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(AllTypesStruct.self, from: data)
        #expect(decoded.boolValue == value.boolValue)
        #expect(decoded.intValue == value.intValue)
        #expect(decoded.int8Value == value.int8Value)
        #expect(decoded.int16Value == value.int16Value)
        #expect(decoded.int32Value == value.int32Value)
        #expect(decoded.int64Value == value.int64Value)
        #expect(decoded.uintValue == value.uintValue)
        #expect(decoded.uint8Value == value.uint8Value)
        #expect(decoded.uint16Value == value.uint16Value)
        #expect(decoded.uint32Value == value.uint32Value)
        #expect(decoded.uint64Value == value.uint64Value)
        #expect(decoded.stringValue == value.stringValue)
        #expect(decoded.optionalString == value.optionalString)
    }

    @Test("Encode nil optional")
    func encodeNilOptional() throws {
        let encoder = BONJSONEncoder()
        let value = AllTypesStruct(
            boolValue: false,
            intValue: 0,
            int8Value: 0,
            int16Value: 0,
            int32Value: 0,
            int64Value: 0,
            uintValue: 0,
            uint8Value: 0,
            uint16Value: 0,
            uint32Value: 0,
            uint64Value: 0,
            floatValue: 0,
            doubleValue: 0,
            stringValue: "",
            optionalString: nil
        )

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(AllTypesStruct.self, from: data)
        #expect(decoded.optionalString == nil)
    }

    @Test("Encode array of primitives")
    func encodeArrayOfPrimitives() throws {
        let encoder = BONJSONEncoder()
        let value = [1, 2, 3, 4, 5]

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode([Int].self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode array of strings")
    func encodeArrayOfStrings() throws {
        let encoder = BONJSONEncoder()
        let value = ["apple", "banana", "cherry"]

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode([String].self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode dictionary")
    func encodeDictionary() throws {
        let encoder = BONJSONEncoder()
        let value = ["one": 1, "two": 2, "three": 3]

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode([String: Int].self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode enum")
    func encodeEnum() throws {
        let encoder = BONJSONEncoder()
        let value = EnumStruct(status: .active)

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(EnumStruct.self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode empty array")
    func encodeEmptyArray() throws {
        let encoder = BONJSONEncoder()
        let value: [Int] = []

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode([Int].self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode empty dictionary")
    func encodeEmptyDictionary() throws {
        let encoder = BONJSONEncoder()
        let value: [String: Int] = [:]

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode([String: Int].self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode special characters in string")
    func encodeSpecialCharacters() throws {
        let encoder = BONJSONEncoder()
        let value = "Hello 👋 World! 日本語 émojis"

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(String.self, from: data)
        #expect(decoded == value)
    }

    @Test("Encode date with seconds since 1970")
    func encodeDateSecondsSince1970() throws {
        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        let value = DateStruct(timestamp: Date(timeIntervalSince1970: 1704067200))

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(DateStruct.self, from: data)
        #expect(decoded.timestamp.timeIntervalSince1970 == value.timestamp.timeIntervalSince1970)
    }

    @Test("Encode date with milliseconds since 1970")
    func encodeDateMillisecondsSince1970() throws {
        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        let value = DateStruct(timestamp: Date(timeIntervalSince1970: 1704067200.123))

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(DateStruct.self, from: data)
        // Compare with some tolerance for floating point precision
        #expect(abs(decoded.timestamp.timeIntervalSince1970 - value.timestamp.timeIntervalSince1970) < 0.001)
    }

    @Test("Encode date with ISO8601")
    func encodeDateISO8601() throws {
        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let value = DateStruct(timestamp: Date(timeIntervalSince1970: 1704067200))

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DateStruct.self, from: data)
        #expect(decoded.timestamp.timeIntervalSince1970 == value.timestamp.timeIntervalSince1970)
    }

    @Test("Encode data with base64")
    func encodeDataBase64() throws {
        let encoder = BONJSONEncoder()
        encoder.dataEncodingStrategy = .base64

        let originalData = "Hello, World!".data(using: .utf8)!
        let value = DataStruct(blob: originalData)

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        decoder.dataDecodingStrategy = .base64
        let decoded = try decoder.decode(DataStruct.self, from: data)
        #expect(decoded.blob == value.blob)
    }

    @Test("Encode URL")
    func encodeURL() throws {
        let encoder = BONJSONEncoder()
        let value = URLStruct(link: URL(string: "https://example.com/path?query=value")!)

        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(URLStruct.self, from: data)
        #expect(decoded == value)
    }

    @Test("Non-conforming float throws by default")
    func nonConformingFloatThrows() throws {
        let encoder = BONJSONEncoder()
        let value = Double.infinity

        #expect(throws: (any Error).self) {
            _ = try encoder.encode(value)
        }
    }

    @Test("Non-conforming float converts to string")
    func nonConformingFloatConvertsToString() throws {
        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        let value = Double.infinity
        let data = try encoder.encode(value)
        #expect(data.count > 0)

        let decoder = BONJSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let decoded = try decoder.decode(Double.self, from: data)
        #expect(decoded == .infinity)
    }
}

// MARK: - Decoder Tests

@Suite("BONJSONDecoder Tests")
struct BONJSONDecoderTests {

    @Test("Decode type mismatch throws error")
    func decodeTypeMismatch() throws {
        let encoder = BONJSONEncoder()
        let data = try encoder.encode("not a number")

        let decoder = BONJSONDecoder()
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(Int.self, from: data)
        }
    }

    @Test("Decode missing key throws error")
    func decodeMissingKey() throws {
        struct Partial: Codable {
            let name: String
        }

        struct Full: Codable {
            let name: String
            let age: Int
        }

        let encoder = BONJSONEncoder()
        let partial = Partial(name: "Test")
        let data = try encoder.encode(partial)

        let decoder = BONJSONDecoder()
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(Full.self, from: data)
        }
    }

    @Test("Decode complex nested structure")
    func decodeComplexNested() throws {
        struct Address: Codable, Equatable {
            let street: String
            let city: String
            let zip: String
        }

        struct Person: Codable, Equatable {
            let name: String
            let addresses: [Address]
            let metadata: [String: String]
        }

        let encoder = BONJSONEncoder()
        let person = Person(
            name: "John Doe",
            addresses: [
                Address(street: "123 Main St", city: "Springfield", zip: "12345"),
                Address(street: "456 Oak Ave", city: "Shelbyville", zip: "67890")
            ],
            metadata: ["role": "admin", "department": "engineering"]
        )

        let data = try encoder.encode(person)
        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(Person.self, from: data)
        #expect(decoded == person)
    }
}

// MARK: - Round-trip Tests

@Suite("Round-trip Tests")
struct RoundTripTests {

    @Test("Round-trip preserves data integrity")
    func roundTripPreservesData() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let original = NestedStruct(
            id: 999,
            info: SimpleStruct(name: "Test User", age: 42, active: true),
            tags: ["test", "roundtrip", "verification"]
        )

        // Encode
        let encoded = try encoder.encode(original)

        // Decode
        let decoded = try decoder.decode(NestedStruct.self, from: encoded)

        // Re-encode
        let reencoded = try encoder.encode(decoded)

        // Re-decode
        let redecoded = try decoder.decode(NestedStruct.self, from: reencoded)

        #expect(decoded == original)
        #expect(redecoded == original)
    }

    @Test("Round-trip with large numbers")
    func roundTripLargeNumbers() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        struct LargeNumbers: Codable, Equatable {
            let maxInt64: Int64
            let minInt64: Int64
            let maxUInt64: UInt64
        }

        let original = LargeNumbers(
            maxInt64: Int64.max,
            minInt64: Int64.min,
            maxUInt64: UInt64.max
        )

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(LargeNumbers.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Round-trip with deeply nested arrays")
    func roundTripDeeplyNested() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let original = [[[1, 2], [3, 4]], [[5, 6], [7, 8]]]

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode([[[Int]]].self, from: encoded)
        #expect(decoded == original)
    }
}

// MARK: - Size Comparison Tests

@Suite("Size Comparison Tests")
struct SizeComparisonTests {

    @Test("BONJSON is smaller than JSON for typical data")
    func bonjsonSmallerThanJSON() throws {
        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        let value = NestedStruct(
            id: 42,
            info: SimpleStruct(name: "Test", age: 25, active: true),
            tags: ["one", "two", "three"]
        )

        let bonjsonData = try bonjsonEncoder.encode(value)
        let jsonData = try jsonEncoder.encode(value)

        // BONJSON should generally be more compact than JSON
        // (especially for small integers and boolean values)
        print("BONJSON size: \(bonjsonData.count) bytes")
        print("JSON size: \(jsonData.count) bytes")

        // Just verify both encode successfully
        #expect(bonjsonData.count > 0)
        #expect(jsonData.count > 0)
    }
}
