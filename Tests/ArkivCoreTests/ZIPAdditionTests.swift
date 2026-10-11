import XCTest
#if os(Linux)
import Glibc
#endif
@testable import ArkivCore

final class ZIPAdditionTests: XCTestCase {
    private func fixture(_ body: (URL, URL, ArchiveSnapshot) throws -> Void) throws {
        #if os(Linux)
        setlocale(LC_CTYPE, "C.UTF-8")
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.txt")
        try Data("original payload".utf8).write(to: existing)
        let archive = try ArchiveCreator().create(.init(sources: [existing], destination: root, name: "Original"), cancellation: ArchiveCancellation(), progress: { _ in })
        let snapshot = try LibArchiveEngine().inspect(archive, cancellation: ArchiveCancellation())
        try body(root, archive, snapshot)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".arkiv-") })
    }
    func testSingleAndMultipleRootItemsPreserveExistingBytes() throws {
        try fixture { root, archive, snapshot in
            XCTAssertTrue(ArchiveZIPUpdater().canAdd(to: snapshot))
            let before = try Data(contentsOf: archive)
            let file = root.appendingPathComponent("first.txt")
            try Data("first".utf8).write(to: file)
            try ArchiveZIPUpdater().add(sources: [file], to: snapshot, cancellation: ArchiveCancellation())
            let after = try Data(contentsOf: archive)
            let directorySignature = Data([0x50,0x4b,1,2])
            let offset = try XCTUnwrap(before.range(of: directorySignature)?.lowerBound)
            XCTAssertEqual(before.prefix(offset), after.prefix(offset))
            let folder = root.appendingPathComponent("資料 🐈")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
            try Data("unicode".utf8).write(to: folder.appendingPathComponent("nested/é.txt"))
            let second = root.appendingPathComponent("second.txt")
            try Data("second".utf8).write(to: second)
            let third = root.appendingPathComponent("third.txt")
            try Data("third".utf8).write(to: third)
            let fresh = try LibArchiveEngine().inspect(archive, cancellation: ArchiveCancellation())
            try ArchiveZIPUpdater().add(sources: [folder, second, third], to: fresh, cancellation: ArchiveCancellation())
            let final = try LibArchiveEngine().inspect(archive, cancellation: ArchiveCancellation())
            XCTAssertEqual(final.entries.count, 8)
            let extracted = try LibArchiveEngine().extract(final, ids: nil, into: root, cancellation: ArchiveCancellation(), progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("existing.txt")), Data("original payload".utf8))
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("資料 🐈/nested/é.txt")), Data("unicode".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("資料 🐈/nested/empty").path))
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("second.txt")), Data("second".utf8))
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("third.txt")), Data("third".utf8))
        }
    }
    func testCollisionCancellationAndFailureLeaveOriginalIdentical() throws {
        try fixture { root, archive, snapshot in
            let original = try Data(contentsOf: archive)
            let collision = root.appendingPathComponent("EXISTING.TXT")
            try Data("collision".utf8).write(to: collision)
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [collision], to: snapshot, cancellation: ArchiveCancellation()))
            let alias = URL(fileURLWithPath: root.path + "/unused/../existing.txt")
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [alias], to: snapshot, cancellation: ArchiveCancellation()))
            let file = root.appendingPathComponent("new")
            try Data(repeating: 7, count: 1_000_000).write(to: file)
            let token = ArchiveCancellation()
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [file], to: snapshot, cancellation: token, progress: { _ in token.cancel() }))
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [root.appendingPathComponent("missing")], to: snapshot, cancellation: ArchiveCancellation()))
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [root], to: snapshot, cancellation: ArchiveCancellation()))
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [archive], to: snapshot, cancellation: ArchiveCancellation()))
            XCTAssertEqual(try Data(contentsOf: archive), original)
        }
    }
    func testChangedOriginalDuringAdditionIsNeverReplaced() throws {
        try fixture { root, archive, snapshot in
            let file = root.appendingPathComponent("new")
            try Data(repeating: 7, count: 1_000_000).write(to: file)
            let changed = Data("another writer".utf8)
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [file], to: snapshot, cancellation: ArchiveCancellation(), progress: { _ in
                try? changed.write(to: archive, options: .atomic)
            }))
            XCTAssertEqual(try Data(contentsOf: archive), changed)
        }
    }
    func testImplicitDirectoryAndCanonicalUnicodeConflicts() throws {
        try fixture { root, archive, snapshot in
            let folder = root.appendingPathComponent("Café")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("existing".utf8).write(to: folder.appendingPathComponent("child"))
            try ArchiveZIPUpdater().add(sources: [folder], to: snapshot, cancellation: ArchiveCancellation())
            let fresh = try LibArchiveEngine().inspect(archive, cancellation: ArchiveCancellation())
            let before = try Data(contentsOf: archive)
            let otherParent = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: otherParent, withIntermediateDirectories: false)
            let collision = otherParent.appendingPathComponent("CAFE\u{301}")
            try Data("collision".utf8).write(to: collision)
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [collision], to: fresh, cancellation: ArchiveCancellation()))
            XCTAssertEqual(try Data(contentsOf: archive), before)
        }
    }
    func testCancellationDuringReplacementVerificationLeavesOriginal() throws {
        try fixture { root, archive, snapshot in
            let file = root.appendingPathComponent("new")
            try Data("new".utf8).write(to: file)
            let before = try Data(contentsOf: archive)
            let token = ArchiveCancellation()
            XCTAssertThrowsError(try ArchiveZIPUpdater().add(sources: [file], to: snapshot, cancellation: token, progress: { value in
                if value.files >= 2 { token.cancel() }
            }))
            XCTAssertEqual(try Data(contentsOf: archive), before)
        }
    }

}
