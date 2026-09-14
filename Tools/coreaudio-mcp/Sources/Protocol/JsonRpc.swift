import Foundation

// =============================================================================
// MARK: - AnyCodable Lightweight Helper
// =============================================================================

public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let boolVal = try? container.decode(Bool.self) {
            self.value = boolVal
        } else if let intVal = try? container.decode(Int.self) {
            self.value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = doubleVal
        } else if let strVal = try? container.decode(String.self) {
            self.value = strVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            self.value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            self.value = dictVal.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodable value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self.value {
        case is NSNull:
            try container.encodeNil()
        case let boolVal as Bool:
            try container.encode(boolVal)
        case let intVal as Int:
            try container.encode(intVal)
        case let doubleVal as Double:
            try container.encode(doubleVal)
        case let strVal as String:
            try container.encode(strVal)
        case let arrayVal as [Any]:
            try container.encode(arrayVal.map { AnyCodable($0) })
        case let dictVal as [String: Any]:
            try container.encode(dictVal.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode value of type \(type(of: self.value))")
            throw EncodingError.invalidValue(self.value, context)
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (is NSNull, is NSNull):
            return true
        case (let l as Bool, let r as Bool):
            return l == r
        case (let l as Int, let r as Int):
            return l == r
        case (let l as Double, let r as Double):
            return l == r
        case (let l as String, let r as String):
            return l == r
        default:
            return false
        }
    }
}

// =============================================================================
// MARK: - JSON-RPC 2.0 Types
// =============================================================================

public enum JsonRpcId: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC ID")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .int(let num):
            try container.encode(num)
        }
    }
}

public struct JsonRpcRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JsonRpcId?
    public let method: String
    public let params: [String: AnyCodable]?

    public init(jsonrpc: String = "2.0", id: JsonRpcId? = nil, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JsonRpcResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JsonRpcId?
    public let result: AnyCodable?
    public let error: JsonRpcError?

    public init(jsonrpc: String = "2.0", id: JsonRpcId?, result: AnyCodable? = nil, error: JsonRpcError? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct JsonRpcError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = JsonRpcError(code: -32700, message: "Parse error")
    public static let invalidRequest = JsonRpcError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JsonRpcError(code: -32601, message: "Method not found")
    public static let invalidParams = JsonRpcError(code: -32602, message: "Invalid params")
    public static let internalError = JsonRpcError(code: -32603, message: "Internal error")
}
