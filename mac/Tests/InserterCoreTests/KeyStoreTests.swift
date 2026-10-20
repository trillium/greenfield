import XCTest
@testable import InserterCore

final class KeyStoreTests: XCTestCase {
    var dir: URL!
    var store: FileKeyStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inserter-test-\(UUID().uuidString)")
        store = FileKeyStore(paths: InserterPaths(directory: dir))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testNotConfiguredUntilCreated() {
        XCTAssertFalse(store.isConfigured)
        XCTAssertEqual(store.verify("anything"), .notConfigured)
    }

    func testCreatedKeyVerifiesAndOthersDoNot() throws {
        let key = try store.create(force: false)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(store.verify(key), .ok)
        XCTAssertEqual(store.verify(key + "a"), .mismatch)
        XCTAssertEqual(store.verify(nil), .mismatch)
        XCTAssertEqual(store.verify(""), .mismatch)
    }

    func testHumanFormattingIsTolerated() throws {
        let key = try store.create(force: false)
        let grouped = stride(from: 0, to: key.count, by: 4).map { i -> String in
            let s = key.index(key.startIndex, offsetBy: i); return String(key[s..<key.index(s, offsetBy: 4)])
        }.joined(separator: "-").uppercased()
        XCTAssertEqual(store.verify(" \(grouped)\n"), .ok)
    }

    func testFileIsPrivateAndHoldsOnlyAHash() throws {
        let key = try store.create(force: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.paths.keyFile.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let contents = try String(contentsOf: store.paths.keyFile, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("sha256:"))
        XCTAssertFalse(contents.contains(key))
    }

    func testCreateRefusesToOverwriteWithoutForce() throws {
        let first = try store.create(force: false)
        XCTAssertThrowsError(try store.create(force: false))
        XCTAssertEqual(store.verify(first), .ok)
    }

    func testForceRotatesAndOldKeyStopsWorking() throws {
        let first = try store.create(force: false)
        let second = try store.create(force: true)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.verify(first), .mismatch)
        XCTAssertEqual(store.verify(second), .ok)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.paths.keyFile.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptKeyFileIsTreatedAsNotConfigured() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "garbage".write(to: store.paths.keyFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.verify("garbage"), .notConfigured)
    }

    func testNameDefaultsToHostnameAndCanBeSet() throws {
        let name = MacName(paths: InserterPaths(directory: dir))
        XCTAssertFalse(name.current().isEmpty)
        try name.set("  Studio Mac ")
        XCTAssertEqual(name.current(), "Studio Mac")
        name.clear()
        XCTAssertNotEqual(name.current(), "Studio Mac")
        XCTAssertThrowsError(try name.set("   "))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(constantTimeEqual([1, 2], [1, 2]))
        XCTAssertFalse(constantTimeEqual([1, 2], [1, 3]))
        XCTAssertFalse(constantTimeEqual([1], [1, 2]))
    }
}
