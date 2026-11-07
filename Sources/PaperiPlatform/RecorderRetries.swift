import Foundation

/// Owns bounded startup work independently of AX observer creation success.
@MainActor final class RecorderRetries {
    private struct Entry: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var entries: [pid_t: Entry] = [:]
    private let sleep: @MainActor (Duration) async throws -> Void
    var pendingCount: Int { entries.count }

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    @discardableResult
    func schedule(_ pid: pid_t, attempt: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        guard entries[pid] == nil else { return nil }
        let token = UUID()
        let sleep = self.sleep
        let task = Task { @MainActor [weak self] in
            defer { self?.finish(pid, token: token) }
            for delay in [1, 2, 4] {
                do { try await sleep(.seconds(delay)) }
                catch { return }
                // A cancelled sleeper may still resume. Never run stale work or
                // let its cleanup discard a replacement schedule for this PID.
                guard !Task.isCancelled, self?.entries[pid]?.token == token else { return }
                guard attempt() else { return }
            }
        }
        entries[pid] = Entry(token: token, task: task)
        return task
    }

    private func finish(_ pid: pid_t, token: UUID) {
        if entries[pid]?.token == token { entries.removeValue(forKey: pid) }
    }

    func cancel(_ pid: pid_t) { entries.removeValue(forKey: pid)?.task.cancel() }

    func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }

    deinit {
        for entry in entries.values { entry.task.cancel() }
    }
}
