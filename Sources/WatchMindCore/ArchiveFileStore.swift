import Foundation

/// Incremental, immutable JSON records with one atomic manifest commit. Audio is deliberately
/// outside this store. Access synchronously from one owner; a lock also serializes callers.
public final class ArchiveFileStore {
    public enum StoreError: Error, Equatable { case corruptArchive, unsafePath, notLoaded, unsupportedVersion }
    public enum FailurePoint: Equatable { case beforeBlobWrite, beforeManifestCommit, beforeOrphanRemoval }
    public struct Statistics {
        public var newBlobCount = 0
        public var newBlobBytes = 0
        public var reusedBlobCount = 0
        public init() {}
    }
    public let directory: URL
    public let file: URL
    public let blobsDirectory: URL
    public private(set) var lastStatistics = Statistics()
    private let lock = NSRecursiveLock()
    private let failureInjector: ((FailurePoint) throws -> Void)?
    private var loaded = false
    private var previous: JournalArchive?
    private var manifest: Manifest?
    private var componentData: [String: Data] = [:]
    private var episodeMetadata: [UUID: Data] = [:]
    private var reviewMetadata: [UUID: Data] = [:]

    private struct Manifest: Codable, Equatable {
        var format = "watchmind-sharded-json"
        var version = 1
        var archiveVersion = 1
        var episodes: [String]
        var heartChunks: [String]
        var reviews: [String]
        var components: [String: String]
        var references: Set<String> { Set(episodes + heartChunks + reviews + Array(components.values)) }
    }
    private static let componentNames: Set<String> = ["reports", "metrics", "markers", "journal", "pendingAudioDeletions"]

    public init(directory: URL, failureInjector: ((FailurePoint) throws -> Void)? = nil) throws {
        self.directory = directory.standardizedFileURL
        self.file = self.directory.appendingPathComponent("archive.json")
        self.blobsDirectory = self.directory.appendingPathComponent("archive-blobs", isDirectory: true)
        self.failureInjector = failureInjector
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try Self.rejectSymlink(self.directory)
        if FileManager.default.fileExists(atPath: blobsDirectory.path) { try Self.rejectSymlink(blobsDirectory) }
    }

    public func load() throws -> JournalArchive {
        lock.lock(); defer { lock.unlock() }
        loaded = false; previous = nil; manifest = nil
        componentData = [:]; episodeMetadata = [:]; reviewMetadata = [:]
        let data: Data
        do { try Self.rejectSymlink(file); data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try missingArchive()
        }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return try missingArchive()
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw StoreError.corruptArchive }
        let archive: JournalArchive
        if dictionary["format"] != nil {
            let index = try JSONDecoder().decode(Manifest.self, from: data)
            guard index.format == "watchmind-sharded-json", index.version == 1, index.archiveVersion == 1 else { throw StoreError.unsupportedVersion }
            guard Set(index.components.keys) == Self.componentNames,
                  index.references.count == index.episodes.count + index.heartChunks.count + index.reviews.count + index.components.count else { throw StoreError.corruptArchive }
            // Read every referenced record before trusting the manifest or allowing a write.
            var blobs: [String: Data] = [:]
            for name in index.references { blobs[name] = try Data(contentsOf: validatedBlobURL(name)) }
            let decoder = JSONDecoder()
            var next = JournalArchive()
            next.episodes = try index.episodes.map { try decoder.decode(Episode.self, from: blobs[$0]!) }
            guard Set(next.episodes.map(\.id)).count == next.episodes.count else { throw StoreError.corruptArchive }
            next.heartPoints = try index.heartChunks.flatMap { try decoder.decode([HeartPoint].self, from: blobs[$0]!) }
            next.reviews = try index.reviews.map { try decoder.decode(AIReviewRecord.self, from: blobs[$0]!) }
            guard Set(next.reviews.map(\.id)).count == next.reviews.count else { throw StoreError.corruptArchive }
            func component<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
                guard let reference = index.components[name], let content = blobs[reference] else { throw StoreError.corruptArchive }
                componentData[name] = content
                return try decoder.decode(type, from: content)
            }
            next.reports = try component("reports", [DailyReport].self)
            next.metrics = try component("metrics", [MetricReading].self)
            next.markers = try component("markers", [MomentMarker].self)
            next.journal = try component("journal", JournalCollection.self)
            next.pendingAudioDeletions = try component("pendingAudioDeletions", [String].self)
            archive = next; manifest = index
        } else {
            archive = try JSONDecoder().decode(JournalArchive.self, from: data)
            guard archive.version == 1 else { throw StoreError.unsupportedVersion }
            guard Set(archive.episodes.map(\.id)).count == archive.episodes.count,
                  Set(archive.reviews.map(\.id)).count == archive.reviews.count else { throw StoreError.corruptArchive }
        }
        for episode in archive.episodes { episodeMetadata[episode.id] = try Self.metadata(episode) }
        for review in archive.reviews { reviewMetadata[review.id] = try Self.metadata(review) }
        previous = archive; loaded = true
        return archive
    }

    public func save(_ archive: JournalArchive) throws {
        lock.lock(); defer { lock.unlock() }
        // Never overwrite unreadable existing content, including when a caller skipped load().
        guard loaded else { throw StoreError.notLoaded }
        guard archive.version == 1 else { throw StoreError.unsupportedVersion }
        guard Set(archive.episodes.map(\.id)).count == archive.episodes.count,
              Set(archive.reviews.map(\.id)).count == archive.reviews.count else { throw StoreError.corruptArchive }
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        try Self.rejectSymlink(blobsDirectory)
        // A process may have stopped after writing records but before committing its manifest.
        // Reclaim only unreferenced, validated records before allocating again, so a nearly-full
        // volume can recover instead of repeatedly duplicating a failed migration generation.
        try pruneUnreferenced(manifest?.references ?? [])
        lastStatistics = Statistics()
        let oldEpisodes = Dictionary((previous?.episodes ?? []).enumerated().map { ($0.element.id, ($0.offset, $0.element)) }, uniquingKeysWith: { a, _ in a })
        let oldReviews = Dictionary((previous?.reviews ?? []).enumerated().map { ($0.element.id, ($0.offset, $0.element)) }, uniquingKeysWith: { a, _ in a })
        var nextEpisodeMetadata: [UUID: Data] = [:], nextReviewMetadata: [UUID: Data] = [:]
        var next = Manifest(episodes: [], heartChunks: [], reviews: [], components: [:])
        for episode in archive.episodes {
            let metadata = try Self.metadata(episode); nextEpisodeMetadata[episode.id] = metadata
            if let old = oldEpisodes[episode.id], let index = manifest, old.0 < index.episodes.count,
               episodeMetadata[episode.id] == metadata, Self.sameLargeFields(old.1, episode) {
                next.episodes.append(index.episodes[old.0]); lastStatistics.reusedBlobCount += 1
            } else { next.episodes.append(try writeBlob(episode)) }
        }
        // Fixed-size pages preserve order and limit writes for typical append-only heart updates.
        let pageSize = 4096
        let oldHearts = previous?.heartPoints ?? []
        for start in stride(from: 0, to: archive.heartPoints.count, by: pageSize) {
            let end = min(start + pageSize, archive.heartPoints.count), page = start / pageSize
            let current = archive.heartPoints[start..<end]
            if let index = manifest, page < index.heartChunks.count, oldHearts.count >= end,
               min(start + pageSize, oldHearts.count) == end,
               Self.sameHearts(oldHearts[start..<end], current) {
                next.heartChunks.append(index.heartChunks[page]); lastStatistics.reusedBlobCount += 1
            } else { next.heartChunks.append(try writeBlob(Array(current))) }
        }
        for review in archive.reviews {
            let metadata = try Self.metadata(review); nextReviewMetadata[review.id] = metadata
            if let old = oldReviews[review.id], let index = manifest, old.0 < index.reviews.count,
               reviewMetadata[review.id] == metadata, Self.sameLargeFields(old.1, review) {
                next.reviews.append(index.reviews[old.0]); lastStatistics.reusedBlobCount += 1
            } else { next.reviews.append(try writeBlob(review)) }
        }
        var nextComponentData: [String: Data] = [:]
        func store<T: Encodable>(_ name: String, _ value: T) throws {
            let data = try Self.encode(value); nextComponentData[name] = data
            if componentData[name] == data, let prior = manifest?.components[name] {
                next.components[name] = prior; lastStatistics.reusedBlobCount += 1
            } else { next.components[name] = try writeBlob(data: data) }
        }
        try store("reports", archive.reports); try store("metrics", archive.metrics)
        try store("markers", archive.markers); try store("journal", archive.journal)
        try store("pendingAudioDeletions", archive.pendingAudioDeletions)
        // Reused cached records must still exist and be ordinary files before committing a
        // new generation. Never turn an unexpected missing record into a newly accepted index.
        for name in next.references {
            let path = try validatedBlobURL(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.unsafePath }
        }
        // New records are immutable and fully written before one atomic manifest replacement.
        if next != manifest {
            try failureInjector?(.beforeManifestCommit)
            try Self.write(try Self.encode(next), to: file)
        }
        // Once committed, cache only the durable new state. A prune failure must not roll back refs.
        manifest = next; previous = archive; componentData = nextComponentData
        episodeMetadata = nextEpisodeMetadata; reviewMetadata = nextReviewMetadata
        try pruneUnreferenced(next.references)
    }

    public func metadataByteCount() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var total: Int64 = 0
        if FileManager.default.fileExists(atPath: file.path) {
            total += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        if FileManager.default.fileExists(atPath: blobsDirectory.path) {
            try Self.rejectSymlink(blobsDirectory)
            for url in try FileManager.default.contentsOfDirectory(at: blobsDirectory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                try Self.rejectSymlink(url)
                total += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        }
        return total
    }

    private func missingArchive() throws -> JournalArchive {
        // Missing pointer + retained records can mean a removed/corrupt manifest, not a new
        // installation. Never accept an empty archive and prune potentially private history.
        // This also conservatively retains an interrupted first generation with no durable
        // pointer; recovery needs an explicit, reviewable action rather than guessing.
        if FileManager.default.fileExists(atPath: blobsDirectory.path) {
            try Self.rejectSymlink(blobsDirectory)
            guard try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path).isEmpty else { throw StoreError.corruptArchive }
        }
        loaded = true; previous = JournalArchive()
        return JournalArchive()
    }

    private func writeBlob<T: Encodable>(_ value: T) throws -> String { try writeBlob(data: Self.encode(value)) }
    private func writeBlob(data: Data) throws -> String {
        try failureInjector?(.beforeBlobWrite)
        let name = UUID().uuidString + ".json"
        try Self.write(data, to: blobsDirectory.appendingPathComponent(name))
        lastStatistics.newBlobCount += 1; lastStatistics.newBlobBytes += data.count
        return name
    }
    private func validatedBlobURL(_ name: String) throws -> URL {
        guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
              name == URL(fileURLWithPath: name).lastPathComponent else { throw StoreError.unsafePath }
        try Self.rejectSymlink(blobsDirectory)
        let url = blobsDirectory.appendingPathComponent(name)
        try Self.rejectSymlink(url)
        return url
    }
    private func pruneUnreferenced(_ references: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: blobsDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            try Self.rejectSymlink(url)
            guard url.pathExtension == "json", UUID(uuidString: String(url.lastPathComponent.dropLast(5))) != nil else {
                throw StoreError.unsafePath
            }
            if !references.contains(url.lastPathComponent) {
                try failureInjector?(.beforeOrphanRemoval)
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    private static func rejectSymlink(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw StoreError.unsafePath }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A missing ordinary path is handled by the caller; a dangling symlink is not missing.
            return
        }
    }
    private static func write(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func metadata(_ episode: Episode) throws -> Data {
        var metadata = episode; metadata.transcript = ""; metadata.segments = []; metadata.fileTranscripts = nil
        return try encode(metadata)
    }
    private static func sameLargeFields(_ a: Episode, _ b: Episode) -> Bool {
        guard a.transcript == b.transcript, a.segments == b.segments else { return false }
        switch (a.fileTranscripts, b.fileTranscripts) {
        case (nil, nil): return true
        case (let x?, let y?): return x.count == y.count && zip(x, y).allSatisfy { $0.audioName == $1.audioName && $0.text == $1.text && $0.segments == $1.segments }
        default: return false
        }
    }
    private static func metadata(_ review: AIReviewRecord) throws -> Data {
        var metadata = review; metadata.text = ""
        metadata.evidence.transcript = []; metadata.evidence.heartPoints = []
        // Metric and baseline arrays are small and intentionally remain in metadata so newly
        // added measurement metadata cannot silently be omitted from equality decisions.
        return try encode(metadata)
    }
    private static func sameLargeFields(_ a: AIReviewRecord, _ b: AIReviewRecord) -> Bool {
        a.text == b.text && a.evidence.transcript.count == b.evidence.transcript.count
            && zip(a.evidence.transcript, b.evidence.transcript).allSatisfy { $0.text == $1.text && $0.start == $1.start && $0.end == $1.end }
            && sameHearts(a.evidence.heartPoints[...], b.evidence.heartPoints[...])
    }
    private static func sameHearts(_ a: ArraySlice<HeartPoint>, _ b: ArraySlice<HeartPoint>) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.sample == $1.sample && $0.baseline == $1.baseline && $0.isDemo == $1.isDemo }
    }
}
