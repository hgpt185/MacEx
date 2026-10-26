import Foundation
import Vision

public struct SimilarPhotoGroup: Identifiable, Sendable { public let id: Int; public let items: [LibraryFile] }
public enum SimilarPhotos {
    public static func scan(_ items: [LibraryFile], threshold: Float = 0.22, control: JobControl) throws -> [SimilarPhotoGroup] {
        guard (0.01...0.5).contains(threshold) else { throw FileFailure.message("Choose a similarity distance from 0.01 to 0.5.") }
        let start = Date()
        var prints: [(LibraryFile, VNFeaturePrintObservation)] = []
        for item in items.filter({ $0.kind == .images && !$0.onlineOnly }).prefix(100) {
            try control.checkCancellation(); if Date().timeIntervalSince(start) > 30 { break }
            if let feature = try? autoreleasepool(invoking: { try item.revalidate(); return try ImageSimilarity.featurePrint(item.url, control: control) }) { prints.append((item, feature)) }
        }
        var used = Set<Int>(); var groups: [SimilarPhotoGroup] = []
        for i in prints.indices where !used.contains(i) {
            var members = [prints[i].0]
            for j in prints.indices where j > i && !used.contains(j) {
                try control.checkCancellation(); var distance: Float = 0
                try prints[i].1.computeDistance(&distance, to: prints[j].1)
                if distance <= threshold { members.append(prints[j].0); used.insert(j) }
            }
            if members.count > 1 { groups.append(SimilarPhotoGroup(id: i, items: members)) }
        }
        return groups
    }
}
