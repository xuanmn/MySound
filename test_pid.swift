import Foundation
import AppKit

@_silgen_name("proc_listchildpids")
func proc_listchildpids(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

func getChildren(of pid: pid_t) -> [pid_t] {
    let maxPIDs = 1024
    var pids = [pid_t](repeating: 0, count: maxPIDs)
    let bytes = proc_listchildpids(pid, &pids, Int32(maxPIDs * MemoryLayout<pid_t>.stride))
    let count = Int(bytes) / MemoryLayout<pid_t>.stride
    if count > 0 {
        return Array(pids[0..<count])
    }
    return []
}

let runningApps = NSWorkspace.shared.runningApplications
if let chrome = runningApps.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
    let pid = chrome.processIdentifier
    let children = getChildren(of: pid)
    print("Chrome PID: \(pid), Children: \(children)")
} else {
    print("Chrome not running")
}
