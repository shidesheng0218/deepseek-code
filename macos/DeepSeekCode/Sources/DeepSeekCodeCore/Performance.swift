import Foundation
import Observation

@MainActor
@Observable
public final class TranscriptBuffer {
    public private(set) var text = ""
    private var pending = ""
    private var flushTask: Task<Void, Never>?
    private let flushDelayNanoseconds: UInt64

    public init(flushDelayNanoseconds: UInt64 = 75_000_000) {
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    public func append(_ delta: String) {
        pending.append(delta)
        guard flushTask == nil else { return }
        let delay = flushDelayNanoseconds
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    public func flush() {
        guard !pending.isEmpty else {
            flushTask = nil
            return
        }
        text.append(pending)
        pending = ""
        flushTask?.cancel()
        flushTask = nil
    }

    public func reset() {
        flushTask?.cancel()
        flushTask = nil
        pending = ""
        text = ""
    }
}

public actor EventBatcher {
    private let store: EventStore
    private let flushDelayNanoseconds: UInt64
    private var pending: [(String, SessionEvent)] = []
    private var scheduled = false

    public init(store: EventStore, flushDelayNanoseconds: UInt64 = 250_000_000) {
        self.store = store
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    public func append(sessionID: String, event: SessionEvent) {
        pending.append((sessionID, event))
        guard !scheduled else { return }
        scheduled = true
        let delay = flushDelayNanoseconds
        Task {
            try? await Task.sleep(nanoseconds: delay)
            flush()
        }
    }

    public func flush() {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        for (sessionID, event) in batch {
            try? store.append(sessionID: sessionID, event: event)
        }
    }
}
