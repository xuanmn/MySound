# CoreAudio MCP Server Specification (macOS API Documentation & Code Patterns)

## 1. Overview & Goals

This specification defines **`coreaudio-mcp`**, a native Apple Silicon macOS CLI server implementing the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) over standard input/output (stdio JSON-RPC 2.0). 

The server provides specialized documentation, private SPI references, production-tested Swift implementation recipes, and real-time audio thread safety audits for macOS CoreAudio, Audio HAL, and Process Tap APIs (`CATapDescription`).

### Target Use Cases
1. **AI Assistant Integration**: Connects seamlessly with Claude Desktop, Cursor, Antigravity, and Zed to provide authoritative answers on private/undocumented CoreAudio SPIs introduced in macOS 14.2 Sonoma and macOS 15 Sequoia.
2. **Real-Time Safety Audits**: Automatically analyzes audio callback code to detect common fatal anti-patterns (heap allocations, Swift concurrency actor hops, blocking locks, Objective-C dynamic calls).
3. **Curated Recipe Library**: Serves drop-in, zero-dependency Swift implementation templates extracted and abstracted from production utilities like MySound.

---

## 2. System Architecture & Components

```
Tools/coreaudio-mcp/
├── Sources/
│   ├── main.swift                   # CLI entry point, stdio event loop, signal handling
│   ├── Protocol/
│   │   ├── JsonRpc.swift            # JSON-RPC 2.0 parsing and serialization (Request, Response, Error)
│   │   ├── McpTypes.swift           # MCP protocol models (Initialize, ToolsList, ToolsCall)
│   │   └── StdioTransport.swift     # Buffered stdin reader and thread-safe stdout writer
│   ├── Models/
│   │   ├── AudioApiEntity.swift     # Structured API symbol documentation model
│   │   ├── CodeRecipe.swift         # Reusable Swift implementation pattern model
│   │   └── SafetyRule.swift         # Real-time audio callback safety rule model
│   ├── Knowledge/
│   │   ├── CoreAudioRegistry.swift  # Embedded registry of CoreAudio SPIs, HAL properties, and functions
│   │   ├── RecipesRegistry.swift    # Embedded repository of production-tested code recipes
│   │   └── SafetyRegistry.swift     # Embedded static audit rules for audio callback safety
│   └── Server/
│       ├── McpServer.swift          # Protocol request dispatcher and lifecycle coordinator
│       └── ToolHandlers.swift       # Business logic implementations for exposed MCP tools
├── build.sh                         # 1-line swiftc compilation script to standalone binary
└── test.sh                          # Automated stdio JSON-RPC smoke test suite
```

### 2.1 Technology Stack & Invariants
* **Language & Runtime**: Swift 5.9+ targeting `arm64-apple-macos14.2+`.
* **Zero External Dependencies**: Standard Swift runtime and Apple `Foundation` framework only.
* **Self-Contained Executable**: All documentation, code templates, and safety rules are embedded as compiled Swift data structures. No external `.json` or `.md` files are required at runtime.
* **Clean Stdio Separation**:
  * Standard Output (`stdout`): Exclusively reserved for JSON-RPC 2.0 responses.
  * Standard Error (`stderr`): Dedicated to diagnostics, debugging, and audit logs.

---

## 3. Data Models

### 3.1 `AudioApiEntity`
```swift
struct AudioApiEntity: Codable, Sendable {
    enum SymbolKind: String, Codable, Sendable {
        case function
        case spiClass
        case halProperty
        case constant
        case structType
    }

    let symbol: String
    let kind: SymbolKind
    let framework: String
    let header: String
    let availability: String
    let isPrivateSPI: Bool
    let signature: String
    let summary: String
    let parameters: [ParameterDoc]
    let returnInfo: String
    let requiredEntitlements: [String]
    let realTimeSafety: String
    let commonPitfalls: [String]
    let relatedSymbols: [String]
}

struct ParameterDoc: Codable, Sendable {
    let name: String
    let type: String
    let description: String
}
```

### 3.2 `CodeRecipe`
```swift
struct CodeRecipe: Codable, Sendable {
    let id: String
    let title: String
    let category: String
    let summary: String
    let code: String
    let keyTakeaways: [String]
}
```

### 3.3 `SafetyRule`
```swift
struct SafetyRule: Codable, Sendable {
    enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    let id: String
    let name: String
    let severity: Severity
    let patterns: [String]
    let explanation: String
    let remedy: String
}
```

---

## 4. MCP Protocol & Tools Specification

### 4.1 Protocol Handshake
* **`initialize`**: Responds with:
  * Protocol Version: `"2024-11-05"`
  * Server Info: `{ "name": "coreaudio-mcp", "version": "1.0.0" }`
  * Capabilities: `{ "tools": { "listChanged": false } }`
* **`notifications/initialized`**: Acknowledged silently.
* **`ping`**: Responds with empty object `{}`.

### 4.2 Tool 1: `search_apis`
* **Purpose**: Fuzzy search across CoreAudio APIs, private SPIs, HAL properties, and types.
* **Parameters**:
  * `query` (string, required): Search term (e.g., `"tap"`, `"aggregate"`, `"vDSP"`, `"kAudioHardwareProperty"`).
  * `framework` (string, optional): Filter by framework (`"CoreAudio"`, `"vDSP"`, `"AudioToolbox"`).
  * `only_spi` (boolean, optional): If `true`, returns only undocumented/private SPIs.
* **Response Format**: Markdown-formatted list of matching symbols with availability, header origin, and summary.

### 4.3 Tool 2: `get_api_details`
* **Purpose**: Return comprehensive specifications for a symbol, including private SPIs and entitlements.
* **Parameters**:
  * `symbol` (string, required): Exact or partial symbol name (e.g., `"CATapDescription"`, `"AudioHardwareCreateProcessTap"`).
* **Response Format**: Detailed Markdown specification:
  * Full Swift / C signature
  * macOS availability & header location
  * Required entitlements & TCC permissions
  * Parameter breakdown & return codes (`OSStatus`)
  * Real-time audio callback safety assessment
  * Common pitfalls, crashes, and undocumented behaviors

### 4.4 Tool 3: `get_code_recipe`
* **Purpose**: Provide production-ready Swift recipes for complex CoreAudio tasks.
* **Parameters**:
  * `recipe_id` (string, optional): ID of recipe (e.g., `"process_tap_setup"`, `"vdsp_gain_scaling"`, `"aggregate_routing"`, `"lock_free_volume"`). If omitted, returns list of all available recipes.
* **Response Format**: Working Swift code block annotated with invariants, error handling, and memory safety rules.

### 4.5 Tool 4: `check_realtime_safety`
* **Purpose**: Static audit of Swift/C code meant for real-time audio IO callbacks (`AudioDeviceIOProc`, `AURenderCallback`).
* **Parameters**:
  * `code` (string, required): Audio callback code snippet to audit.
* **Audit Rules**:
  1. **Heap Allocations**: Detects `malloc`, `calloc`, `Array(`, `String(`, `Dictionary(`, object initializers.
  2. **Swift Concurrency**: Detects `Task {`, `Task.detached`, `await`, actor method invocations.
  3. **Blocking Synchronization**: Detects `DispatchQueue.sync`, `pthread_mutex_lock`, `NSLock`, semaphore waits.
  4. **Dynamic Objective-C Dispatch**: Detects `@objc` methods, dynamic selectors, `NSObject` message sends.
* **Response Format**: Diagnostic checklist detailing pass/fail status per category, flagged lines, and recommended safe alternatives (e.g., ring buffers, `os_unfair_lock` outside the callback).

---

## 5. Curated Knowledge Base Content

### 5.1 CoreAudio Symbols Included at Launch
1. **Private Process Tap SPIs (macOS 14.2+)**:
   * `CATapDescription`
   * `AudioHardwareCreateProcessTap`
   * `AudioHardwareDestroyProcessTap`
2. **Audio Hardware & Device Management**:
   * `AudioHardwareCreateAggregateDevice`
   * `AudioHardwareDestroyAggregateDevice`
   * `AudioObjectGetPropertyData`
   * `AudioObjectSetPropertyData`
   * `AudioObjectAddPropertyListener`
   * `AudioObjectRemovePropertyListener`
   * `kAudioHardwarePropertyDefaultOutputDevice`
   * `kAudioHardwarePropertyDevices`
   * `kAudioDevicePropertyMute`
   * `kAudioDevicePropertyVolumeScalar`
3. **vDSP Buffer Operations**:
   * `vDSP_vsmul` (Vector scalar float multiplication)
   * `vDSP_maxv` (Peak amplitude calculation)

### 5.2 Curated Code Recipes
1. `process_tap_setup`: Creating `CATapDescription` by PID and acquiring tap `AudioObjectID`.
2. `aggregate_device_routing`: Combining a process tap subdevice with a physical output subdevice into an aggregate device.
3. `vdsp_gain_scaling`: In-place SIMD audio volume gain scaling across non-interleaved `AudioBufferList` streams.
4. `lock_free_volume_store`: High-speed microsecond volume lookup using `os_unfair_lock` safe for audio callbacks.

---

## 6. Build, Test & Deployment

### 6.1 Build Script (`Tools/coreaudio-mcp/build.sh`)
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -target arm64-apple-macos14.2 -framework Foundation Sources/**/*.swift Sources/*.swift -o bin/coreaudio-mcp
echo "Built bin/coreaudio-mcp successfully."
```

### 6.2 Test Script (`Tools/coreaudio-mcp/test.sh`)
* Executes `bin/coreaudio-mcp` with automated JSON-RPC standard input sequences:
  1. `initialize`
  2. `tools/list`
  3. `tools/call` for `search_apis`
  4. `tools/call` for `get_api_details`
  5. `tools/call` for `get_code_recipe`
  6. `tools/call` for `check_realtime_safety`
* Asserts non-zero output and valid JSON-RPC responses.

---

## 7. Client Configuration

### Claude Desktop / Cursor / Antigravity Config
```json
{
  "mcpServers": {
    "coreaudio-docs": {
      "command": "/Users/xuanmn/Developer/MySound/Tools/coreaudio-mcp/bin/coreaudio-mcp"
    }
  }
}
```
