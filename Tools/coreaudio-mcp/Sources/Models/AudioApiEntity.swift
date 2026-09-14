import Foundation

public struct ParameterDoc: Codable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let description: String

    public init(name: String, type: String, description: String) {
        self.name = name
        self.type = type
        self.description = description
    }
}

public struct AudioApiEntity: Codable, Sendable, Equatable {
    public enum SymbolKind: String, Codable, Sendable {
        case function
        case spiClass
        case halProperty
        case constant
        case structType
    }

    public let symbol: String
    public let kind: SymbolKind
    public let framework: String
    public let header: String
    public let availability: String
    public let isPrivateSPI: Bool
    public let signature: String
    public let summary: String
    public let parameters: [ParameterDoc]
    public let returnInfo: String
    public let requiredEntitlements: [String]
    public let realTimeSafety: String
    public let commonPitfalls: [String]
    public let relatedSymbols: [String]

    public init(
        symbol: String,
        kind: SymbolKind,
        framework: String,
        header: String,
        availability: String,
        isPrivateSPI: Bool,
        signature: String,
        summary: String,
        parameters: [ParameterDoc],
        returnInfo: String,
        requiredEntitlements: [String],
        realTimeSafety: String,
        commonPitfalls: [String],
        relatedSymbols: [String]
    ) {
        self.symbol = symbol
        self.kind = kind
        self.framework = framework
        self.header = header
        self.availability = availability
        self.isPrivateSPI = isPrivateSPI
        self.signature = signature
        self.summary = summary
        self.parameters = parameters
        self.returnInfo = returnInfo
        self.requiredEntitlements = requiredEntitlements
        self.realTimeSafety = realTimeSafety
        self.commonPitfalls = commonPitfalls
        self.relatedSymbols = relatedSymbols
    }
}
