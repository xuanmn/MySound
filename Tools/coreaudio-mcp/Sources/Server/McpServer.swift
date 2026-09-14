import Foundation

public final class McpServer: @unchecked Sendable {
    private let transport: StdioTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(transport: StdioTransport = .shared) {
        self.transport = transport
    }

    public func start() {
        transport.log("coreaudio-mcp server started, awaiting JSON-RPC messages on stdin...")

        while let line = transport.readLine() {
            if line.isEmpty { continue }

            guard let lineData = line.data(using: .utf8) else {
                sendError(id: nil, error: .parseError)
                continue
            }

            do {
                let request = try decoder.decode(JsonRpcRequest.self, from: lineData)
                handleRequest(request)
            } catch {
                transport.log("Failed to parse JSON-RPC request: \(error.localizedDescription)")
                sendError(id: nil, error: .parseError)
            }
        }

        transport.log("Standard input closed, shutting down coreaudio-mcp.")
    }

    private func handleRequest(_ request: JsonRpcRequest) {
        switch request.method {
        case "initialize":
            let serverInfo = ServerInfo(name: "coreaudio-mcp", version: "1.0.0")
            let initResult = InitializeResult(
                protocolVersion: "2024-11-05",
                capabilities: ServerCapabilities(tools: ToolsCapability(listChanged: false)),
                serverInfo: serverInfo
            )
            sendResult(id: request.id, result: initResult)

        case "notifications/initialized":
            // Notification; no response needed per JSON-RPC / MCP specs
            transport.log("Client completed initialization handshake.")

        case "ping":
            sendResult(id: request.id, result: [String: String]())

        case "tools/list":
            let tools = getToolDefinitions()
            sendResult(id: request.id, result: ToolsListResult(tools: tools))

        case "tools/call":
            handleToolCall(request)

        default:
            transport.log("Unhandled method: \(request.method)")
            sendError(id: request.id, error: .methodNotFound)
        }
    }

    private func handleToolCall(_ request: JsonRpcRequest) {
        guard let params = request.params,
              let nameVal = params["name"]?.value as? String else {
            sendError(id: request.id, error: .invalidParams)
            return
        }

        let arguments = (params["arguments"]?.value as? [String: Any]) ?? [:]
        let result: CallToolResult

        switch nameVal {
        case "search_apis":
            result = ToolHandlers.handleSearchApis(arguments: arguments)
        case "get_api_details":
            result = ToolHandlers.handleGetApiDetails(arguments: arguments)
        case "get_code_recipe":
            result = ToolHandlers.handleGetCodeRecipe(arguments: arguments)
        case "check_realtime_safety":
            result = ToolHandlers.handleCheckRealtimeSafety(arguments: arguments)
        default:
            sendError(id: request.id, error: JsonRpcError(code: -32601, message: "Unknown tool: \(nameVal)"))
            return
        }

        sendResult(id: request.id, result: result)
    }

    private func getToolDefinitions() -> [ToolDefinition] {
        return [
            ToolDefinition(
                name: "search_apis",
                description: "Search across macOS CoreAudio APIs, private SPIs (CATapDescription), HAL properties, and Accelerate vDSP functions.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Keyword to search (e.g. 'tap', 'aggregate', 'vDSP', 'kAudioHardwareProperty')"
                        ],
                        "framework": [
                            "type": "string",
                            "description": "Optional framework filter: 'CoreAudio', 'vDSP', or 'AudioToolbox'"
                        ],
                        "only_spi": [
                            "type": "boolean",
                            "description": "If true, restricts results to private / undocumented macOS SPIs"
                        ]
                    ],
                    "required": ["query"]
                ])
            ),

            ToolDefinition(
                name: "get_api_details",
                description: "Retrieve comprehensive documentation, exact Swift/C signature, parameters, entitlements, real-time safety assessment, and common pitfalls for a CoreAudio API or private SPI.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "symbol": [
                            "type": "string",
                            "description": "The exact or partial symbol name (e.g. 'CATapDescription', 'AudioHardwareCreateProcessTap', 'vDSP_vsmul')"
                        ]
                    ],
                    "required": ["symbol"]
                ])
            ),

            ToolDefinition(
                name: "get_code_recipe",
                description: "Retrieve production-ready, zero-dependency Swift implementation recipes for CoreAudio (process tap interception, aggregate routing, vDSP gain scaling, lock-free volume store).",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "recipe_id": [
                            "type": "string",
                            "description": "Optional recipe ID ('process_tap_setup', 'aggregate_device_routing', 'vdsp_gain_scaling', 'lock_free_volume_store'). If omitted, lists all available recipes."
                        ]
                    ]
                ])
            ),

            ToolDefinition(
                name: "check_realtime_safety",
                description: "Static heuristic audit of Swift or C audio callback code. Checks for fatal real-time audio anti-patterns: heap allocations, Swift concurrency actor hops, blocking mutexes, and dynamic Obj-C messaging.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "code": [
                            "type": "string",
                            "description": "The Swift or C/C++ audio callback code snippet to audit"
                        ]
                    ],
                    "required": ["code"]
                ])
            )
        ]
    }

    private func sendResult<T: Encodable>(id: JsonRpcId?, result: T) {
        do {
            let resultData = try encoder.encode(result)
            let anyCodableResult = try decoder.decode(AnyCodable.self, from: resultData)
            let response = JsonRpcResponse(jsonrpc: "2.0", id: id, result: anyCodableResult, error: nil)
            let responseData = try encoder.encode(response)
            if let str = String(data: responseData, encoding: .utf8) {
                transport.writeLine(str)
            }
        } catch {
            transport.log("Failed to encode JSON-RPC result: \(error.localizedDescription)")
            sendError(id: id, error: .internalError)
        }
    }

    private func sendError(id: JsonRpcId?, error: JsonRpcError) {
        do {
            let response = JsonRpcResponse(jsonrpc: "2.0", id: id, result: nil, error: error)
            let responseData = try encoder.encode(response)
            if let str = String(data: responseData, encoding: .utf8) {
                transport.writeLine(str)
            }
        } catch {
            transport.log("Failed to encode JSON-RPC error: \(error.localizedDescription)")
        }
    }
}
