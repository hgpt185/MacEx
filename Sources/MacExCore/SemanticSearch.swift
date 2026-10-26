import Foundation
import NaturalLanguage

public struct SemanticMatch: Sendable {
    public var document: IndexedDocument
    public var score: Double
}
public struct SemanticResult: Sendable {
    public var matches: [SemanticMatch]
    public var evaluated: Int
    public var seconds: Double
    public var dimension: Int
    public var limited: Bool
    public var cost: ResearchCost
}

/// Experimental, explicit invocation only. Uses the OS sentence embedding if installed;
/// never calls an asset-download API and never persists vectors.
public enum SemanticSearch {
    public static func rank(_ query: String, documents: [IndexedDocument], optedIn: Bool, language: String = "en",
                            control: JobControl = JobControl()) throws -> SemanticResult {
        guard optedIn else { throw FileFailure.message("Enable the related-text experiment explicitly first.") }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw FileFailure.message("Enter up to 500 characters for related-text search.") }
        let costStart = ResearchCost.snapshot()
        guard let embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: language)),
              let vector = embedding.vector(for: query) else {
            throw FileFailure.message("The system sentence embedding is unavailable for this language. MacEx will not download a model. Use literal text search.")
        }
        let start = Date()
        var matches: [SemanticMatch] = []; var evaluated = 0
        for document in documents.prefix(1000) {
            try control.checkCancellation()
            if Date().timeIntervalSince(start) > 30 { break }
            guard let text = document.candidate.content, !text.isEmpty,
                  let candidate = embedding.vector(for: String(text.prefix(4096))) else { continue }
            let score = cosine(vector, candidate)
            evaluated += 1
            if score.isFinite { matches.append(SemanticMatch(document: document, score: score)) }
        }
        matches.sort { $0.score == $1.score ? $0.document.path < $1.document.path : $0.score > $1.score }
        return SemanticResult(matches: Array(matches.prefix(50)), evaluated: evaluated, seconds: Date().timeIntervalSince(start), dimension: vector.count,
                              limited: evaluated < documents.count || documents.count >= 1000, cost: ResearchCost.measure(since: costStart))
    }
    public static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return .nan }
        var dot = 0.0; var a = 0.0; var b = 0.0
        for (x, y) in zip(lhs, rhs) { dot += x * y; a += x * x; b += y * y }
        guard a > 0, b > 0 else { return .nan }
        return dot / (a.squareRoot() * b.squareRoot())
    }
}
