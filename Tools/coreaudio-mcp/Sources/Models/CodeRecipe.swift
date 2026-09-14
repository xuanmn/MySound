import Foundation

public struct CodeRecipe: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let category: String
    public let summary: String
    public let code: String
    public let keyTakeaways: [String]

    public init(
        id: String,
        title: String,
        category: String,
        summary: String,
        code: String,
        keyTakeaways: [String]
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.summary = summary
        self.code = code
        self.keyTakeaways = keyTakeaways
    }
}
