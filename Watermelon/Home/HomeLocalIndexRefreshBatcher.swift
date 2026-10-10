import Foundation

@MainActor
final class HomeLocalIndexRefreshBatcher {
    private let interval: Duration
    private let refresh: (Set<String>) async -> Void
    private var pendingIDs = Set<String>()
    private var timer: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?

    init(interval: Duration = .milliseconds(200), refresh: @escaping (Set<String>) async -> Void) {
        self.interval = interval
        self.refresh = refresh
    }

    deinit { timer?.cancel() }

    func enqueue(_ assetID: String) {
        pendingIDs.insert(assetID)
        schedule()
    }

    func flush() async {
        timer?.cancel()
        timer = nil
        while true {
            if let refreshing {
                await refreshing.value
            } else if !pendingIDs.isEmpty {
                startRefresh()
            } else {
                return
            }
        }
    }

    private func schedule() {
        guard !pendingIDs.isEmpty, timer == nil, refreshing == nil else { return }
        let interval = interval
        timer = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled else { return }
            self?.timer = nil
            self?.startRefresh()
        }
    }

    private func startRefresh() {
        timer?.cancel()
        timer = nil
        guard refreshing == nil, !pendingIDs.isEmpty else { return }
        let ids = pendingIDs
        pendingIDs.removeAll()
        refreshing = Task {
            await refresh(ids)
            refreshing = nil
            schedule()
        }
    }
}
