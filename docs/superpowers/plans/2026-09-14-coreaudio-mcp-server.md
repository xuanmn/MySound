# CoreAudio MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test a self-contained, native Apple Silicon Swift CLI implementing the Model Context Protocol (stdio JSON-RPC 2.0) that exposes macOS CoreAudio API documentation, private SPIs (`CATapDescription`), production-ready code patterns, and real-time audio thread safety audits.

**Architecture:** Standalone Swift command-line executable (`Tools/coreaudio-mcp/bin/coreaudio-mcp`) compiling via `swiftc` with zero external dependencies. Documentation, recipes, and safety rules are compiled as static Swift data models. Standard I/O processes newline-delimited JSON-RPC 2.0 messages, responding to `initialize`, `tools/list`, and `tools/call`.

**Tech Stack:** Swift 5.9+ targeting `arm64-apple-macos14.2+`, Apple `Foundation` framework, standard stdio streams (`FileHandle.standardInput`, `FileHandle.standardOutput`, `FileHandle.standardError`).

**Spec:** [`docs/superpowers/specs/2026-09-14-coreaudio-mcp-server-design.md`](file:///Users/xuanmn/Developer/MySound/docs/superpowers/specs/2026-09-14-coreaudio-mcp-server-design.md)

## Global Constraints

- Platform target: macOS 14.2+ Sonoma (`arm64-apple-macos14.2`).
- Zero external package dependencies: standard Swift library & `Foundation` only.
- Strict stdio separation: `stdout` strictly JSON-RPC payloads; `stderr` strictly diagnostics/logs.
- All knowledge bases and recipes are embedded in the compiled binary (fully portable single executable).

---

### Task 1: Scaffolding, Data Models, & Build Script

**Files:**
- Create: `Tools/coreaudio-mcp/Sources/Models/AudioApiEntity.swift`
- Create: `Tools/coreaudio-mcp/Sources/Models/CodeRecipe.swift`
- Create: `Tools/coreaudio-mcp/Sources/Models/SafetyRule.swift`
- Create: `Tools/coreaudio-mcp/build.sh`

**Interfaces:**
- Produces:
  - `AudioApiEntity`: Struct containing `symbol`, `kind`, `framework`, `header`, `availability`, `isPrivateSPI`, `signature`, `summary`, `parameters`, `returnInfo`, `requiredEntitlements`, `realTimeSafety`, `commonPitfalls`, `relatedSymbols`.
  - `CodeRecipe`: Struct containing `id`, `title`, `category`, `summary`, `code`, `keyTakeaways`.
  - `SafetyRule`: Struct containing `id`, `name`, `severity`, `patterns`, `explanation`, `remedy`.
  - `build.sh`: Compiles all `.swift` files under `Tools/coreaudio-mcp/Sources/` into `Tools/coreaudio-mcp/bin/coreaudio-mcp`.

- [ ] **Step 1: Create the directory tree and write model files**

Write `Tools/coreaudio-mcp/Sources/Models/AudioApiEntity.swift`:
```swift
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
```

Write `Tools/coreaudio-mcp/Sources/Models/CodeRecipe.swift`:
```swift
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
```

Write `Tools/coreaudio-mcp/Sources/Models/SafetyRule.swift`:
```swift
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
```

- [ ] **Step 2: Create minimal placeholder entry point and build script**

Write `Tools/coreaudio-mcp/Sources/main.swift`:
```swift
import Foundation

FileHandle.standardError.write(Data("coreaudio-mcp bootstrap v1.0.0\n".utf8))
```

Write `Tools/coreaudio-mcp/build.sh`:
```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
mkdir -p "${BIN_DIR}"

SWIFT_FILES=$(find "${SCRIPT_DIR}/Sources" -type f -name "*.swift")

swiftc -O \
  -target arm64-apple-macos14.2 \
  -framework Foundation \
  ${SWIFT_FILES} \
  -o "${BIN_DIR}/coreaudio-mcp"

chmod +x "${BIN_DIR}/coreaudio-mcp"
echo "Successfully compiled: ${BIN_DIR}/coreaudio-mcp"
```
Make executable: `chmod +x Tools/coreaudio-mcp/build.sh`

- [ ] **Step 3: Run build script and verify binary executes**

Run: `Tools/coreaudio-mcp/build.sh && Tools/coreaudio-mcp/bin/coreaudio-mcp`
Expected Output:
```
Successfully compiled: .../Tools/coreaudio-mcp/bin/coreaudio-mcp
coreaudio-mcp bootstrap v1.0.0
```

- [ ] **Step 4: Commit**

```bash
git add Tools/coreaudio-mcp/
git commit -m "feat(mcp): scaffold coreaudio-mcp models, entry point, and build script"
```

---

### Task 2: Embedded Knowledge Registries

**Files:**
- Create: `Tools/coreaudio-mcp/Sources/Knowledge/CoreAudioRegistry.swift`
- Create: `Tools/coreaudio-mcp/Sources/Knowledge/RecipesRegistry.swift`
- Create: `Tools/coreaudio-mcp/Sources/Knowledge/SafetyRegistry.swift`

**Interfaces:**
- Consumes: `AudioApiEntity`, `CodeRecipe`, `SafetyRule`
- Produces:
  - `CoreAudioRegistry.allEntities: [AudioApiEntity]`
  - `RecipesRegistry.allRecipes: [CodeRecipe]`
  - `SafetyRegistry.allRules: [SafetyRule]`

- [ ] **Step 1: Write CoreAudioRegistry with curated SPIs, HAL properties, and functions**

Write `Tools/coreaudio-mcp/Sources/Knowledge/CoreAudioRegistry.swift` with complete entries for:
- `CATapDescription` (Private SPI, macOS 14.2+)
- `AudioHardwareCreateProcessTap` (Private SPI, macOS 14.2+)
- `AudioHardwareDestroyProcessTap` (Private SPI, macOS 14.2+)
- `AudioHardwareCreateAggregateDevice`
- `AudioHardwareDestroyAggregateDevice`
- `AudioObjectGetPropertyData`
- `AudioObjectSetPropertyData`
- `AudioObjectAddPropertyListener`
- `AudioObjectRemovePropertyListener`
- `kAudioHardwarePropertyDefaultOutputDevice`
- `kAudioHardwarePropertyDevices`
- `kAudioDevicePropertyMute`
- `kAudioDevicePropertyVolumeScalar`
- `vDSP_vsmul`

- [ ] **Step 2: Write RecipesRegistry with working Swift code templates**

Write `Tools/coreaudio-mcp/Sources/Knowledge/RecipesRegistry.swift` with complete recipes for:
- `process_tap_setup`: Demonstrates configuring `CATapDescription(processes:)`, setting mono/mixdown, acquiring tap `AudioObjectID`.
- `aggregate_device_routing`: Demonstrates building aggregate dictionary with `kAudioAggregateDeviceMainSubDeviceKey` and `kAudioAggregateDeviceSubDeviceListKey`.
- `vdsp_gain_scaling`: In-place scalar float multiplication on raw PCM buffers (`vDSP_vsmul`) inside `AudioBufferList`.
- `lock_free_volume_store`: Audio-thread safe volume lookup pattern utilizing `os_unfair_lock` with zero heap allocations.

- [ ] **Step 3: Write SafetyRegistry with real-time audio callback safety rules**

Write `Tools/coreaudio-mcp/Sources/Knowledge/SafetyRegistry.swift` with detection patterns:
- `heap_allocation`: Detects `malloc`, `calloc`, `free`, `Array(`, `String(`, `Dictionary(`, `Data(`.
- `swift_concurrency`: Detects `Task {`, `Task.detached`, `await`, `actor`.
- `blocking_locks`: Detects `DispatchQueue.sync`, `pthread_mutex_lock`, `NSLock`, `semaphore.wait`.
- `objc_dispatch`: Detects `@objc`, `objc_msgSend`, `NSObject`.

- [ ] **Step 4: Recompile and verify syntax**

Run: `Tools/coreaudio-mcp/build.sh`
Expected: Build succeeds with code 0.

- [ ] **Step 5: Commit**

```bash
git add Tools/coreaudio-mcp/Sources/Knowledge/
git commit -m "feat(mcp): add embedded registries for CoreAudio SPIs, recipes, and safety rules"
```

---

### Task 3: JSON-RPC 2.0 & Stdio Transport Protocol

**Files:**
- Create: `Tools/coreaudio-mcp/Sources/Protocol/JsonRpc.swift`
- Create: `Tools/coreaudio-mcp/Sources/Protocol/McpTypes.swift`
- Create: `Tools/coreaudio-mcp/Sources/Protocol/StdioTransport.swift`

**Interfaces:**
- Produces:
  - `JsonRpcRequest`, `JsonRpcResponse`, `JsonRpcError`, `JsonRpcId`
  - MCP schema types: `InitializeRequest`, `InitializeResult`, `ToolsListResult`, `ToolDefinition`, `ToolCallParams`, `ToolCallResult`
  - `StdioTransport`: Reads lines from `FileHandle.standardInput`, writes encoded JSON strings followed by newline to `FileHandle.standardOutput`.

- [ ] **Step 1: Write JSON-RPC 2.0 models**

Write `Tools/coreaudio-mcp/Sources/Protocol/JsonRpc.swift` implementing:
```swift
import Foundation

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
        case .string(let str): try container.encode(str)
        case .int(let num): try container.encode(num)
        }
    }
}

public struct JsonRpcRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JsonRpcId?
    public let method: String
    public let params: [String: AnyCodable]?
}

public struct JsonRpcResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JsonRpcId?
    public let result: AnyCodable?
    public let error: JsonRpcError?
}

public struct JsonRpcError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?
}
```
*(Include a lightweight `AnyCodable` wrapper to handle arbitrary JSON payloads without third-party libraries).*

- [ ] **Step 2: Write MCP Protocol types**

Write `Tools/coreaudio-mcp/Sources/Protocol/McpTypes.swift`:
```swift
import Foundation

public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: AnyCodable
}

public struct TextContent: Codable, Sendable {
    public let type: String = "text"
    public let text: String
}

public struct CallToolResult: Codable, Sendable {
    public let content: [TextContent]
    public let isError: Bool?
}
```

- [ ] **Step 3: Write StdioTransport**

Write `Tools/coreaudio-mcp/Sources/Protocol/StdioTransport.swift`:
```swift
import Foundation

public final class StdioTransport: Sendable {
    public static let shared = StdioTransport()

    public func readLine() -> String? {
        var buffer = Data()
        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 1)
            if chunk.isEmpty {
                return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
            }
            if chunk[0] == 0x0A { // \n
                return String(data: buffer, encoding: .utf8)
            }
            if chunk[0] != 0x0D { // skip \r
                buffer.append(chunk)
            }
        }
    }

    public func writeLine(_ string: String) {
        if let data = (string + "\n").data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    public func log(_ message: String) {
        if let data = ("[coreaudio-mcp] " + message + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
```

- [ ] **Step 4: Recompile and verify**

Run: `Tools/coreaudio-mcp/build.sh`
Expected: Success.

- [ ] **Step 5: Commit**

```bash
git add Tools/coreaudio-mcp/Sources/Protocol/
git commit -m "feat(mcp): implement JSON-RPC 2.0 and stdio transport models"
```

---

### Task 4: MCP Server Engine & Tool Handlers

**Files:**
- Create: `Tools/coreaudio-mcp/Sources/Server/ToolHandlers.swift`
- Create: `Tools/coreaudio-mcp/Sources/Server/McpServer.swift`
- Modify: `Tools/coreaudio-mcp/Sources/main.swift`

**Interfaces:**
- Consumes: Protocol types, Registries, Transport
- Produces: Complete working MCP stdio server handling:
  - `initialize`
  - `notifications/initialized`
  - `ping`
  - `tools/list`
  - `tools/call` for:
    - `search_apis(query, framework, only_spi)`
    - `get_api_details(symbol)`
    - `get_code_recipe(recipe_id)`
    - `check_realtime_safety(code)`

- [ ] **Step 1: Write ToolHandlers with business logic**

Write `Tools/coreaudio-mcp/Sources/Server/ToolHandlers.swift`:
- `handleSearchApis(args: [String: AnyCodable]) -> CallToolResult`: Performs case-insensitive matching against `symbol`, `summary`, and `relatedSymbols`. Filters by `framework` and `only_spi` when provided. Returns formatted Markdown.
- `handleGetApiDetails(args: [String: AnyCodable]) -> CallToolResult`: Finds exact or best match in `CoreAudioRegistry`. Formats full signature, parameters, return codes, required entitlements, real-time safety rules, and pitfalls into clean Markdown.
- `handleGetCodeRecipe(args: [String: AnyCodable]) -> CallToolResult`: Returns the requested recipe by `recipe_id`, or returns the full list of available recipes if empty.
- `handleCheckRealtimeSafety(args: [String: AnyCodable]) -> CallToolResult`: Scans line-by-line against `SafetyRegistry.allRules`, collects violation lines and severity, and outputs a structured Markdown audit table with recommended remedies.

- [ ] **Step 2: Write McpServer dispatcher loop**

Write `Tools/coreaudio-mcp/Sources/Server/McpServer.swift`:
- Implements `func start()` loop reading JSON-RPC requests via `StdioTransport`.
- Dispatches `initialize` responding with protocol `"2024-11-05"`, `name: "coreaudio-mcp"`, `version: "1.0.0"`.
- Dispatches `tools/list` returning the 4 tool definitions with complete JSON schemas.
- Dispatches `tools/call` routing to `ToolHandlers`.
- Encodes and writes responses to `stdout`.

- [ ] **Step 3: Wire up main.swift**

Modify `Tools/coreaudio-mcp/Sources/main.swift` to invoke `McpServer().start()`.

- [ ] **Step 4: Recompile**

Run: `Tools/coreaudio-mcp/build.sh`
Expected: Success.

- [ ] **Step 5: Commit**

```bash
git add Tools/coreaudio-mcp/Sources/Server/ Tools/coreaudio-mcp/Sources/main.swift
git commit -m "feat(mcp): implement MCP server request dispatcher and tool handlers"
```

---

### Task 5: Automated Smoke Test Suite & Integration Verification

**Files:**
- Create: `Tools/coreaudio-mcp/test.sh`
- Create: `Tools/coreaudio-mcp/README.md`

**Interfaces:**
- Produces:
  - `test.sh`: End-to-end automated test suite verifying all 4 tools and MCP lifecycle over stdio pipes.
  - `README.md`: Clear documentation with installation instructions, tool list, and client configuration snippets.

- [ ] **Step 1: Write automated smoke test script**

Write `Tools/coreaudio-mcp/test.sh`:
```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${SCRIPT_DIR}/bin/coreaudio-mcp"

if [ ! -f "${BIN}" ]; then
  "${SCRIPT_DIR}/build.sh"
fi

echo "=== Running coreaudio-mcp Automated Smoke Tests ==="

send_request() {
  local req="$1"
  echo "$req" | "${BIN}" 2>/dev/null
}

echo "Test 1: initialize handshake..."
RESP1=$(send_request '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0"}}}')
echo "$RESP1" | grep -q '"protocolVersion":"2024-11-05"'
echo "$RESP1" | grep -q '"name":"coreaudio-mcp"'
echo "  Passed."

echo "Test 2: tools/list..."
RESP2=$(send_request '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
echo "$RESP2" | grep -q '"name":"search_apis"'
echo "$RESP2" | grep -q '"name":"get_api_details"'
echo "$RESP2" | grep -q '"name":"get_code_recipe"'
echo "$RESP2" | grep -q '"name":"check_realtime_safety"'
echo "  Passed."

echo "Test 3: tools/call search_apis..."
RESP3=$(send_request '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_apis","arguments":{"query":"tap"}}}')
echo "$RESP3" | grep -q "CATapDescription"
echo "  Passed."

echo "Test 4: tools/call get_api_details..."
RESP4=$(send_request '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_api_details","arguments":{"symbol":"CATapDescription"}}}')
echo "$RESP4" | grep -q "CATapDescription"
echo "$RESP4" | grep -q "System Audio Recording"
echo "  Passed."

echo "Test 5: tools/call get_code_recipe..."
RESP5=$(send_request '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_code_recipe","arguments":{"recipe_id":"process_tap_setup"}}}')
echo "$RESP5" | grep -q "AudioHardwareCreateProcessTap"
echo "  Passed."

echo "Test 6: tools/call check_realtime_safety (detect unsafe malloc and Task)..."
UNSAFE_CODE='func render() { malloc(1024); Task { await doWork() } }'
RESP6=$(send_request "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"check_realtime_safety\",\"arguments\":{\"code\":\"$UNSAFE_CODE\"}}}")
echo "$RESP6" | grep -q "heap_allocation" || echo "$RESP6" | grep -q "Heap Allocation"
echo "  Passed."

echo "=== All 6 Smoke Tests Passed Successfully! ==="
```
Make executable: `chmod +x Tools/coreaudio-mcp/test.sh`

- [ ] **Step 2: Run test.sh and verify all 6 tests pass**

Run: `Tools/coreaudio-mcp/test.sh`
Expected Output:
```
=== Running coreaudio-mcp Automated Smoke Tests ===
Test 1: initialize handshake...
  Passed.
Test 2: tools/list...
  Passed.
Test 3: tools/call search_apis...
  Passed.
Test 4: tools/call get_api_details...
  Passed.
Test 5: tools/call get_code_recipe...
  Passed.
Test 6: tools/call check_realtime_safety...
  Passed.
=== All 6 Smoke Tests Passed Successfully! ===
```

- [ ] **Step 3: Write README.md with configuration guides**

Write `Tools/coreaudio-mcp/README.md` including instructions for Claude Desktop, Antigravity, and Cursor.

- [ ] **Step 4: Commit**

```bash
git add Tools/coreaudio-mcp/test.sh Tools/coreaudio-mcp/README.md
git commit -m "feat(mcp): add automated test suite and documentation for coreaudio-mcp"
```
