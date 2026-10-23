import Foundation
import CryptoKit

struct AssetStamp: Codable, Equatable {
    let id: String
    let date: Date
    let modified: Date?
    let width: Int
    let height: Int
    let favorite: Bool
    let live: Bool

    func photo(score: Float) -> Photo {
        Photo(id: id, date: date, modified: modified, width: width, height: height,
              favorite: favorite, live: live, score: score)
    }
    func canReuseFeature(_ record: AnalysisRecord) -> Bool {
        record.photo.modified == modified && record.photo.width == width && record.photo.height == height
    }
}

struct CachedSession: Codable {
    let groups: [SimilarGroup]
    let unavailable: Int
    let count: Int
}

struct ScanSession {
    let assets: [AssetStamp]
    var key: String {
        // Include grouping settings so algorithm changes cannot reuse incompatible groups.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try! encoder.encode(assets)
        return "window600-distance0.32-vision2-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ScanPlanner {
    static let window: TimeInterval = 600
    static func sessions(_ assets: [AssetStamp]) -> [ScanSession] {
        let sorted = assets.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        var result: [ScanSession] = []
        var current: [AssetStamp] = []
        for asset in sorted {
            if let last = current.last,
               last.date == .distantPast || asset.date == .distantPast || asset.date.timeIntervalSince(last.date) > window {
                result.append(ScanSession(assets: current))
                current = []
            }
            current.append(asset)
        }
        if !current.isEmpty { result.append(ScanSession(assets: current)) }
        return result
    }
    static func isClosed(representative: Date, next: Date) -> Bool {
        next.timeIntervalSince(representative) > window
    }
}

struct ScanProgress {
    var checked = 0
    var total = 0
    var cached = 0
    var analyzed = 0
    var unavailable = 0
}

enum ScanUpdate {
    case prepared(previous: [SimilarGroup], ready: [SimilarGroup], progress: ScanProgress)
    case completedGroups([SimilarGroup])
    case progress(ScanProgress)
}
