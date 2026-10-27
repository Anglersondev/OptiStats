import XCTest
@testable import OptiStatsCore

final class FakeFS: FileSystemProviding {
    var tree: [String: [String]] = [:]; var sizes: [String: UInt64] = [:]; var links: Set<String> = []
    func children(of path: String) -> [String] { tree[path] ?? [] }
    func allocatedBytes(at path: String) -> UInt64 { sizes[path] ?? 0 }
    func isSymbolicLink(_ path: String) -> Bool { links.contains(path) }
}

final class CleanupTests: XCTestCase {
    let home = "/Users/a"
    func policy() -> CleanupPolicy { CleanupPolicy(home: home) }

    func testOnlyChildrenOfRootsAreDeletable() {
        let fs = FakeFS(); let p = policy()
        XCTAssertTrue(p.canDelete("/Users/a/Library/Caches/com.foo", category: .appCaches, fs: fs))
        XCTAssertFalse(p.canDelete("/Users/a/Library/Caches", category: .appCaches, fs: fs))          // a própria raiz
        XCTAssertFalse(p.canDelete("/Users/a/Documents/x", category: .appCaches, fs: fs))
        XCTAssertFalse(p.canDelete("/Library/Caches/com.foo", category: .appCaches, fs: fs))          // fora do home
        XCTAssertFalse(p.canDelete("/Users/a/Library/Caches/../Documents", category: .appCaches, fs: fs))
        XCTAssertFalse(p.canDelete("/Users/a/Library/Logs/x", category: .appCaches, fs: fs))          // categoria errada
    }

    func testReportOnlyAndSymlinksAndProtectedNames() {
        let fs = FakeFS(); let p = policy()
        XCTAssertFalse(p.canDelete("/Users/a/Downloads/big.iso", category: .largeDownloads, fs: fs))
        fs.links.insert("/Users/a/Library/Caches/link")
        XCTAssertFalse(p.canDelete("/Users/a/Library/Caches/link", category: .appCaches, fs: fs))
        XCTAssertFalse(p.canDelete("/Users/a/Library/Caches/CloudKit", category: .appCaches, fs: fs))
    }

    func testScanSortsAndFilters() {
        let fs = FakeFS()
        fs.tree["/Users/a/Library/Caches"] = ["/Users/a/Library/Caches/small", "/Users/a/Library/Caches/big", "/Users/a/Library/Caches/CloudKit"]
        fs.sizes["/Users/a/Library/Caches/small"] = 10; fs.sizes["/Users/a/Library/Caches/big"] = 500
        fs.sizes["/Users/a/Library/Caches/CloudKit"] = 9999
        fs.tree["/Users/a/Downloads"] = ["/Users/a/Downloads/x.iso"]; fs.sizes["/Users/a/Downloads/x.iso"] = 7000
        let items = CleanupScanner(policy: policy(), fs: fs).scan()
        XCTAssertEqual(items.map(\.path), ["/Users/a/Downloads/x.iso", "/Users/a/Library/Caches/big", "/Users/a/Library/Caches/small"])
        XCTAssertEqual(CleanupScanner.total(items, category: .appCaches), 510)
    }

    func testExecutorRevalidatesAndReports() {
        let fs = FakeFS(); var trashed: [String] = []
        let ex = CleanupExecutor(policy: policy(), fs: fs) { path in
            if path.hasSuffix("fails") { throw NSError(domain: "x", code: 1) }
            trashed.append(path)
        }
        let items = [
            CleanupItem(path: "/Users/a/Library/Caches/ok", category: .appCaches, bytes: 5),
            CleanupItem(path: "/Users/a/Library/Caches/fails", category: .appCaches, bytes: 6),
            CleanupItem(path: "/Users/a/Documents/evil", category: .appCaches, bytes: 7),
            CleanupItem(path: "/Users/a/Downloads/a.iso", category: .largeDownloads, bytes: 8)
        ]
        let r = ex.run(items)
        XCTAssertEqual(trashed, ["/Users/a/Library/Caches/ok"])
        XCTAssertEqual(r.movedBytes, 5); XCTAssertEqual(r.skipped.count, 2); XCTAssertEqual(r.failed.count, 1)
    }
}
