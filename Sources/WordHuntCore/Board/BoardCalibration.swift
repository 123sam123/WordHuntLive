import CoreGraphics
import Foundation

/// A saved board location inside a capture source.
/// `geometry.boardRect` is normalized to the captured frame (0…1, origin top-left),
/// so it survives window resizes as long as the aspect ratio holds.
public struct BoardCalibration: Codable, Equatable, Sendable {
    /// Stable identifier of the capture target (see `CaptureTarget.id`).
    public var sourceID: String
    public var sourceName: String
    public var geometry: BoardGeometry
    public var createdAt: Date

    public init(sourceID: String, sourceName: String, geometry: BoardGeometry, createdAt: Date = Date()) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.geometry = geometry
        self.createdAt = createdAt
    }

    /// Builds a calibration from a rectangle the user drew, clamped to the frame.
    public static func fromSelection(_ rect: CGRect, sourceID: String, sourceName: String,
                                     rows: Int = 4, columns: Int = 4, tileInset: Double = 0.08) -> BoardCalibration {
        let clamped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return BoardCalibration(sourceID: sourceID, sourceName: sourceName,
                                geometry: BoardGeometry(rows: rows, columns: columns, boardRect: clamped, tileInset: tileInset))
    }
}

/// Persists calibrations (one per capture source) as JSON in Application Support.
public struct CalibrationStore: Sendable {
    public let directory: URL

    public init(directory: URL = CalibrationStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WordHuntLive", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("calibrations.json") }

    public func loadAll() -> [String: BoardCalibration] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: BoardCalibration].self, from: data)) ?? [:]
    }

    public func load(sourceID: String) -> BoardCalibration? { loadAll()[sourceID] }

    /// Most recently saved calibration regardless of source.
    public func latest() -> BoardCalibration? { loadAll().values.max { $0.createdAt < $1.createdAt } }

    public func save(_ calibration: BoardCalibration) throws {
        var all = loadAll()
        all[calibration.sourceID] = calibration
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: fileURL, options: .atomic)
    }
}
