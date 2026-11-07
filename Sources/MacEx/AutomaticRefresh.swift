import Foundation

/// Coalesces automatic refreshes, suspends their timer while inactive and catches up once on return.
@MainActor final class AutomaticRefresh {
    private var active = true
    private var onBattery = false
    private var needed = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let sleep: @Sendable (Duration) async throws -> Void
    private let refresh: () -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, refresh: @escaping () -> Void) {
        self.sleep = sleep; self.refresh = refresh
    }
    func request() {
        needed = true
        stopTimer()
        guard active else { return }
        let delay: Duration = .seconds(onBattery ? 30 : 3), token = generation
        task = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token, self.active, self.needed else { return }
            self.task = nil; self.needed = false; self.refresh()
        }
    }
    func setActivity(active: Bool, onBattery: Bool, catchUp: Bool = true) {
        let resumed = active && !self.active, batteryChanged = self.onBattery != onBattery
        guard self.active != active || batteryChanged else { return }
        self.active = active; self.onBattery = onBattery
        if !active {
            if catchUp { needed = true }
            stopTimer()
        } else if resumed && needed {
            stopTimer(); needed = false; refresh()
        } else if batteryChanged && needed { request() }
    }
    func cancel() { stopTimer(); needed = false }
    private func stopTimer() { generation = UUID(); task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
