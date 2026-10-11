import Foundation
import CArkiv

private final class ZIPAdditionProgress {
    let callback: @Sendable (ArchiveProgress) -> Void
    init(_ callback: @escaping @Sendable (ArchiveProgress) -> Void) { self.callback = callback }
}

/// Adds distinct root items without rewriting existing compressed data or entry metadata.
/// ZIP64, encrypted, multipart, and ambiguous metadata/layouts remain read-only.
public struct ArchiveZIPUpdater: Sendable {
    public init() {}
    private func canonical(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        #if os(macOS)
        if url.path.hasPrefix("/var/") || url.path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + url.path)
        }
        #endif
        return url
    }
    public func canAdd(to snapshot: ArchiveSnapshot) -> Bool {
        guard snapshot.unlocked == nil, snapshot.entries.allSatisfy({ $0.kind == .file || $0.kind == .directory }), (try? SourceStamp(snapshot.url)) == snapshot.stamp else { return false }
        var error = [CChar](repeating: 0, count: 256)
        guard let transaction = arkiv_zip_begin(canonical(snapshot.url).path, &error, error.count) else { return false }
        arkiv_zip_end(transaction)
        return true
    }
    @discardableResult
    public func add(sources: [URL], to snapshot: ArchiveSnapshot, cancellation: ArchiveCancellation,
                    progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) throws -> URL {
        guard snapshot.unlocked == nil, snapshot.entries.allSatisfy({ $0.kind == .file || $0.kind == .directory }), try SourceStamp(snapshot.url) == snapshot.stamp else {
            throw ArchiveFailure.message("Archive changed since it was opened. Reopen it.")
        }
        let archive = canonical(snapshot.url)
        var error = [CChar](repeating: 0, count: 256)
        guard let transaction = arkiv_zip_begin(archive.path, &error, error.count) else {
            throw ArchiveFailure.message(String(cString: error))
        }
        defer { arkiv_zip_end(transaction) }
        // Recheck after pinning the source descriptor, before any source work.
        guard try SourceStamp(snapshot.url) == snapshot.stamp else {
            throw ArchiveFailure.message("Archive changed since it was opened. Reopen it.")
        }
        func key(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        var roots = Set(snapshot.entries.compactMap { $0.path.split(separator: "/").first.map { key(String($0)) } })
        for sourceURL in sources {
            let source = canonical(sourceURL)
            guard roots.insert(key(source.lastPathComponent)).inserted else {
                throw ArchiveFailure.message("An item named ‘\(source.lastPathComponent)’ already exists at the archive root. Rename the source item before adding it.")
            }
            guard canonical(source) != archive, (try? SourceStamp(source).inode) != snapshot.stamp.inode else {
                throw ArchiveFailure.message("An archive cannot be added to itself.")
            }
        }
        let manager = FileManager.default
        let stage = archive.deletingLastPathComponent().appendingPathComponent(".arkiv-add-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let additions = try ArchiveCreator().create(ArchiveCreationRequest(sources: sources, destination: stage, name: "additions"),
                                                    cancellation: cancellation, progress: progress)
        let receiver = ZIPAdditionProgress(progress)
        let retained = Unmanaged.passRetained(receiver)
        defer { retained.release() }
        let result = arkiv_zip_prepare(transaction, additions.path, stage.path, cancellation.pointer, { context, files, bytes in
            guard let context else { return }
            Unmanaged<ZIPAdditionProgress>.fromOpaque(context).takeUnretainedValue().callback(ArchiveProgress(files: files, bytes: bytes))
        }, retained.toOpaque(), &error, error.count)
        func check(_ result: Int32) throws {
            if result == 2 { throw ArchiveFailure.cancelled }
            if result != 0 { throw ArchiveFailure.message(String(cString: error)) }
        }
        try check(result)
        #if os(macOS)
        var coordinationError: NSError?
        var commitResult: Int32 = 1
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: archive, options: .forReplacing, error: &coordinationError) { coordinated in
            guard canonical(coordinated) == archive else { return }
            commitResult = arkiv_zip_commit(transaction, cancellation.pointer, &error, error.count)
        }
        // Once rename succeeds, late cancellation/coordination errors cannot undo success.
        if commitResult != 0 {
            if let coordinationError { throw coordinationError }
            try check(commitResult)
        }
        #else
        try check(arkiv_zip_commit(transaction, cancellation.pointer, &error, error.count))
        #endif
        return snapshot.url
    }
}
