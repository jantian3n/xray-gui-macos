import Foundation

public enum JSONCoding {
    public static func decodeObject(from raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw NodeImportError.invalidJSONObject
        }
        return object
    }

    public static func prettyPrintedString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    public static func deepCopy(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let value = try JSONSerialization.jsonObject(with: data)
        guard let result = value as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return result
    }
}
