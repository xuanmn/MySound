import Foundation

public struct SafetyRegistry: Sendable {
    public static let allRules: [SafetyRule] = [
        SafetyRule(
            id: "heap_allocation",
            name: "Heap Allocation in Real-Time Callback",
            severity: .error,
            patterns: [
                "malloc(",
                "calloc(",
                "realloc(",
                "free(",
                "Array(",
                "String(",
                "Dictionary(",
                "Data(",
                "Set(",
                "append(",
                "insert("
            ],
            explanation: "Dynamic memory allocation causes non-deterministic thread latency due to kernel heap locks, leading directly to buffer under-runs (audio pops, clicks, or dropouts).",
            remedy: "Pre-allocate all buffers, arrays, and structs during setup before starting the audio IO proc. Use fixed-size stack buffers or pre-sized memory pools."
        ),

        SafetyRule(
            id: "swift_concurrency",
            name: "Swift Concurrency / Async Context Hop",
            severity: .error,
            patterns: [
                "Task {",
                "Task.detached",
                "await ",
                "async ",
                "@MainActor"
            ],
            explanation: "The real-time audio thread must run synchronously with bounded latency. Yielding control via async/await or dispatching Swift Tasks causes thread hops onto cooperative thread pools, violating real-time audio deadlines.",
            remedy: "Keep audio callbacks purely synchronous. Communicate with async actors or UI layers using lock-free single-producer single-consumer (SPSC) ring buffers or atomic flags."
        ),

        SafetyRule(
            id: "blocking_locks",
            name: "Coarse / Blocking Mutex Synchronization",
            severity: .error,
            patterns: [
                "DispatchQueue.main.sync",
                "DispatchQueue.global().sync",
                ".sync {",
                "pthread_mutex_lock",
                "NSLock",
                "NSRecursiveLock",
                "semaphore.wait",
                "DispatchSemaphore"
            ],
            explanation: "Blocking locks or synchronization with other dispatch queues causes priority inversion. If the audio thread blocks waiting on a low-priority UI queue, the system audio buffer window expires.",
            remedy: "Use atomic variables (ManagedAtomic), lockless ring buffers, or microsecond os_unfair_lock exclusively for scalar lookups."
        ),

        SafetyRule(
            id: "objc_dispatch",
            name: "Dynamic Objective-C Message Dispatch",
            severity: .warning,
            patterns: [
                "@objc",
                "objc_msgSend",
                "NSClassFromString",
                "performSelector",
                "NotificationCenter.default"
            ],
            explanation: "Dynamic Objective-C messaging involves method cache misses, class table locks, and ARC retain/release runtime overhead that can introduce unbounded jitter.",
            remedy: "Use pure Swift structs or static C-function pointers inside the audio callback loop."
        )
    ]
}
