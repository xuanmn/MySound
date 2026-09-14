import Foundation

public final class StdioTransport: @unchecked Sendable {
    public static let shared = StdioTransport()

    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle
    private var readBuffer = Data()

    public init(
        inputHandle: FileHandle = .standardInput,
        outputHandle: FileHandle = .standardOutput,
        errorHandle: FileHandle = .standardError
    ) {
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
    }

    /// Reads a single line (delimited by \n) from standard input.
    public func readLine() -> String? {
        while true {
            // Check if buffer already contains a newline
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) { // '\n'
                let lineData = readBuffer.subdata(in: 0..<newlineIndex)
                readBuffer.removeSubrange(0...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    return line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Read more data from standard input
            let chunk = inputHandle.availableData
            if chunk.isEmpty {
                // EOF reached
                if !readBuffer.isEmpty {
                    let line = String(data: readBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    readBuffer.removeAll()
                    return (line?.isEmpty ?? true) ? nil : line
                }
                return nil
            }
            readBuffer.append(chunk)
        }
    }

    /// Writes a line to standard output followed by a newline character.
    public func writeLine(_ string: String) {
        if let data = (string + "\n").data(using: .utf8) {
            outputHandle.write(data)
        }
    }

    /// Logs diagnostic info strictly to standard error.
    public func log(_ message: String) {
        if let data = ("[coreaudio-mcp] " + message + "\n").data(using: .utf8) {
            errorHandle.write(data)
        }
    }
}
