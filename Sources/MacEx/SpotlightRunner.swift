import Foundation
import MacExCore

@MainActor
final class SpotlightRunner: NSObject {
    private var filterQuery: NSMetadataQuery?
    private var probeQuery: NSMetadataQuery?
    private var token: UUID?
    private var scope = ""
    private var filtered: [URL]?
    private var probeCount: Int?
    private var probeFinished = false
    private var onResult: ((UUID, SearchCoverage, [URL]) -> Void)?

    private var timeout: Task<Void, Never>?

    func start(_ request: SearchRequest, token: UUID, onResult: @escaping (UUID, SearchCoverage, [URL]) -> Void) {
        cancel()
        self.token = token
        self.scope = request.scope
        self.onResult = onResult
        filterQuery = makeQuery(SpotlightPredicate.filter(for: request), token: token)
        probeQuery = makeQuery(SpotlightPredicate.probe(), token: token)
        guard filterQuery?.start() == true, probeQuery?.start() == true else { finishUnverified(); return }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.finishUnverified()
        }
    }

    func cancel() {
        timeout?.cancel(); timeout = nil
        NotificationCenter.default.removeObserver(self)
        filterQuery?.stop(); probeQuery?.stop()
        filterQuery = nil; probeQuery = nil
        token = nil; filtered = nil; probeCount = nil; probeFinished = false; onResult = nil
    }

    private func finishUnverified() {
        guard let token, let callback = onResult else { return }
        cancel()
        callback(token, .indexUnverified, [])
    }

    private func makeQuery(_ predicate: NSPredicate, token: UUID) -> NSMetadataQuery {
        let query = NSMetadataQuery()
        query.searchScopes = [URL(fileURLWithPath: scope, isDirectory: true)]
        query.predicate = predicate
        NotificationCenter.default.addObserver(self, selector: #selector(gather(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        _ = token
        return query
    }

    @objc private func gather(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        guard query === filterQuery || query === probeQuery else { return }
        query.disableUpdates()
        if query === filterQuery {
            var urls: [URL] = []
            for index in 0..<query.resultCount {
                guard let item = query.result(at: index) as? NSMetadataItem else { continue }
                let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
                    ?? (item.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
                if let url, SearchScope.contains(itemPath: url.path, scopePath: scope) { urls.append(url) }
            }
            filtered = urls
        } else {
            probeFinished = true
            probeCount = query.resultCount
        }
        query.stop()
        publish()
    }

    private func publish() {
        guard let token, let filtered, let probeCount, probeFinished, let onResult else { return }
        let coverage = filtered.isEmpty
            ? SpotlightCoverage.interpret(filteredCount: 0, probeCount: probeCount, probeFinished: true)
            : SearchCoverage.indexedResults
        let callback = onResult
        cancel()
        callback(token, coverage, coverage == .indexUnverified ? [] : filtered)
    }
}
