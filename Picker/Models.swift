import Foundation

struct Photo: Identifiable, Codable, Hashable {
    let id: String
    let date: Date
    let modified: Date?
    let width: Int
    let height: Int
    let favorite: Bool
    let live: Bool
    let score: Float
    var megapixels: Double { Double(width) * Double(height) / 1_000_000 }
}

struct SimilarGroup: Identifiable, Codable, Hashable {
    let photos: [Photo]
    // Exact membership keys prevent decisions leaking into changed groups.
    var id: String { photos.map(\.id).sorted().joined(separator: "|") }
    var suggestedID: String {
        photos.max {
            let lhs = Double($0.score) + ($0.favorite ? 0.15 : 0) + min($0.megapixels / 1000, 0.03)
            let rhs = Double($1.score) + ($1.favorite ? 0.15 : 0) + min($1.megapixels / 1000, 0.03)
            return lhs < rhs
        }?.id ?? ""
    }
    var date: Date { photos.first?.date ?? .distantPast }
}

struct Decision: Codable, Equatable {
    var keepers: Set<String> = []
    var skipped = false
}

enum ReviewRules {
    static func unchanged(_ before: SimilarGroup?, _ after: SimilarGroup) -> Bool {
        guard let before, before.id == after.id else { return false }
        return before.photos.sorted { $0.id < $1.id } == after.photos.sorted { $0.id < $1.id }
    }
    static func deletions(in group: SimilarGroup, decision: Decision?) -> [Photo] {
        guard let decision, !decision.skipped, !decision.keepers.isEmpty,
              decision.keepers.isSubset(of: Set(group.photos.map(\.id))) else { return [] }
        return group.photos.filter { !decision.keepers.contains($0.id) }
    }
    static func reconciled(_ decisions: [String: Decision], old: [SimilarGroup], new: [SimilarGroup]) -> [String: Decision] {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let updated = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        return decisions.filter { key, _ in
            guard let group = updated[key], let before = previous[key] else { return false }
            return unchanged(before, group)
        }
    }
}

struct AnalysisRecord: Codable {
    let photo: Photo
    let feature: Data
}

struct SavedLibrary: Codable {
    var version = 1
    var records: [String: AnalysisRecord] = [:]
    var groups: [SimilarGroup] = []
    var sessions: [String: CachedSession]? = nil
}

enum LocalStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Picker", isDirectory: true)
    }()
    static func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

struct ProcessedGroup: Codable, Identifiable {
    let group: SimilarGroup
    var decision: Decision
    let processedAt: Date
    var deletedAt: Date? = nil
    var invalidated = false
    var id: String { group.id }
}
