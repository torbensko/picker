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
    // Omitted by older saves, which expressed removals as the complement of the keepers.
    var discards: Set<String>? = nil
}

enum ReviewRules {
    static func unchanged(_ before: SimilarGroup?, _ after: SimilarGroup) -> Bool {
        guard let before, before.id == after.id else { return false }
        return before.photos.sorted { $0.id < $1.id } == after.photos.sorted { $0.id < $1.id }
    }
    static func valid(_ decision: Decision, in group: SimilarGroup) -> Bool {
        let ids = Set(group.photos.map(\.id))
        let discards = decision.discards ?? []
        return !decision.skipped && !ids.isEmpty && decision.keepers.isSubset(of: ids)
            && discards.isSubset(of: ids) && discards.isDisjoint(with: decision.keepers)
    }

    static func deletions(in group: SimilarGroup, decision: Decision?) -> [Photo] {
        guard let decision, valid(decision, in: group) else { return [] }
        if let discards = decision.discards { return group.photos.filter { discards.contains($0.id) } }
        guard !decision.keepers.isEmpty else { return [] }
        return group.photos.filter { !decision.keepers.contains($0.id) }
    }

    static func summary(in group: SimilarGroup, decision: Decision?) -> String {
        guard let decision, valid(decision, in: group) else { return "\(group.photos.count) photos · choose your keepers" }
        let marked = deletions(in: group, decision: decision).count
        let undecided = group.photos.count - marked - decision.keepers.count
        return "\(decision.keepers.count) kept · \(marked) pending" + (undecided > 0 ? " · \(undecided) undecided" : "")
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
    var manual: Bool? = nil
    var id: String { manual == true ? "cleanup|" + group.id : group.id }
    var removals: [Photo] { ReviewRules.deletions(in: group, decision: decision) }
    var deletionSummary: String {
        let deleted = removals.count
        let undecided = group.photos.count - decision.keepers.count - deleted
        if manual == true { return "\(deleted) deleted" }
        return "\(decision.keepers.count) kept · \(deleted) deleted" + (undecided > 0 ? " · \(undecided) left in Photos" : "")
    }
}

struct CleanupPhoto: Identifiable, Equatable {
    let photo: Photo
    let screenshot: Bool
    var id: String { photo.id }
}
