# `coreaudio-mcp` — macOS CoreAudio & Process Tap MCP Server

A standalone, native Apple Silicon Model Context Protocol (MCP) server providing authoritative documentation, private SPI references, production-tested Swift implementation recipes, and real-time audio thread safety audits for macOS CoreAudio, Audio HAL, and Process Taps (`CATapDescription`).

---

## ✨ Features & Tools Exposed

`coreaudio-mcp` operates over standard input/output (`stdio`) implementing JSON-RPC 2.0 and MCP protocol version `2024-11-05`.

| Tool | Description |
| :--- | :--- |
| **`search_apis`** | Search across macOS CoreAudio APIs, private SPIs (`CATapDescription`), HAL properties, and Accelerate `vDSP` functions with optional framework and SPI filters. |
| **`get_api_details`** | Retrieve in-depth specifications, exact Swift/C signatures, parameters, required entitlements (`Entitlements.plist`), real-time safety rules, and known pitfalls for a symbol. |
| **`get_code_recipe`** | Access production-tested, zero-dependency Swift implementation templates (process tap lifecycle, aggregate device routing, in-place `vDSP` gain scaling, lock-free volume stores). |
| **`check_realtime_safety`** | Run a static heuristic audit on Swift or C audio callback code (`AudioDeviceIOProc`, `AURenderCallback`) to detect heap allocations, Swift Concurrency hops, blocking mutexes, and dynamic Objective-C messaging. |

---

## 🚀 Quick Start & Build

### 1. Prerequisites
- macOS 14.2+ (Sonoma) or macOS 15.0+ (Sequoia)
- Apple Silicon Mac (`arm64`)
- Xcode Command Line Tools (`xcode-select --install`)

### 2. Build from Source
Compile the zero-dependency executable using `swiftc`:
```bash
./Tools/coreaudio-mcp/build.sh
```
The binary will be compiled to `Tools/coreaudio-mcp/bin/coreaudio-mcp`.

### 3. Run Automated Tests
```bash
./Tools/coreaudio-mcp/test.sh
```

---

## 🔌 Connecting to MCP Clients

### 1. Antigravity IDE / CLI
Add to your project's `.agents/mcp_config.json` or global `~/.gemini/config/mcp_config.json`:
```json
{
  "mcpServers": {
    "coreaudio-docs": {
      "command": "/Users/xuanmn/Developer/MySound/Tools/coreaudio-mcp/bin/coreaudio-mcp"
    }
  }
}
```

### 2. Claude Desktop
Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "coreaudio-docs": {
      "command": "/Users/xuanmn/Developer/MySound/Tools/coreaudio-mcp/bin/coreaudio-mcp"
    }
  }
}
```

### 3. Cursor
Add to Cursor Settings -> Features -> MCP Servers:
- **Name**: `coreaudio-docs`
- **Type**: `command`
- **Command**: `/Users/xuanmn/Developer/MySound/Tools/coreaudio-mcp/bin/coreaudio-mcp`

---

## 🛡️ Real-Time Safety Rules Monitored

Audio IO callbacks run on real-time, non-preemptible threads with microsecond deadlines. `check_realtime_safety` audits for:
1. **Heap Allocations**: `malloc`, `free`, `Array`, `String`, `Data`, `Dictionary` (causes non-deterministic page faults and allocator mutex locks).
2. **Swift Concurrency**: `Task { }`, `await`, actor method calls (causes async thread hops off the real-time core).
3. **Blocking Locks**: `DispatchQueue.sync`, `NSLock`, `pthread_mutex_lock`, semaphores (causes priority inversion).
4. **Objective-C Runtime**: `@objc`, `objc_msgSend`, `NSClassFromString` (involves method cache misses and runtime locks).
