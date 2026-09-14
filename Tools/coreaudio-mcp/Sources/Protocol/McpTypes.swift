import Foundation

// =============================================================================
// MARK: - MCP Initialization Types
// =============================================================================

public struct ServerInfo: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ToolsCapability: Codable, Sendable {
    public let listChanged: Bool

    public init(listChanged: Bool = false) {
        self.listChanged = listChanged
    }
}

public struct ServerCapabilities: Codable, Sendable {
    public let tools: ToolsCapability

    public init(tools: ToolsCapability = ToolsCapability()) {
        self.tools = tools
    }
}

public struct InitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: ServerCapabilities
    public let serverInfo: ServerInfo

    public init(protocolVersion: String = "2024-11-05", capabilities: ServerCapabilities = ServerCapabilities(), serverInfo: ServerInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

// =============================================================================
// MARK: - MCP Tools Types
// =============================================================================

public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: AnyCodable

    public init(name: String, description: String, inputSchema: AnyCodable) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolsListResult: Codable, Sendable {
    public let tools: [ToolDefinition]

    public init(tools: [ToolDefinition]) {
        self.tools = tools
    }
}

public struct TextContent: Codable, Sendable {
    public let type: String
    public let text: String

    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

public struct CallToolResult: Codable, Sendable {
    public let content: [TextContent]
    public let isError: Bool?

    public init(content: [TextContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String, isError: Bool = false) -> CallToolResult {
        return CallToolResult(content: [TextContent(text: text)], isError: isError ? true : nil)
    }
}
