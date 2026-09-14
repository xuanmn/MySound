import Foundation

public struct SafetyRule: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    public let id: String
    public let name: String
    public let severity: Severity
    public let patterns: [String]
    public let explanation: String
    public let remedy: String

    public init(
        id: String,
        name: String,
        severity: Severity,
        patterns: [String],
        explanation: String,
        remedy: String
    ) {
        self.id = id
        self.name = name
        self.severity = severity
        self.patterns = patterns
        self.explanation = explanation
        self.remedy = remedy
    }
}
