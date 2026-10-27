import XCTest
@testable import OptiStatsCore

/// Árvore falsa: caminhos de diretório -> entradas.
final class FakeTree: FileTreeProviding, FileSystemProviding {
    var dirs: [String: [FileEntry]] = [:]
    var denied: Set<String> = []
    var fileSet: Set<String> = []
    var links: Set<String> = []

    func listing(of path: String) -> DirectoryListing {
        DirectoryListing(entries: dirs[path] ?? [], permissionDenied: denied.contains(path))
    }
    func children(of path: String) -> [String] { (dirs[path] ?? []).map(\.path) }
    func allocatedBytes(at path: String) -> UInt64 { 0 }
    func isSymbolicLink(_ path: String) -> Bool { links.contains(path) }
    func isDirectory(_ path: String) -> Bool { !fileSet.contains(path) }

    func dir(_ path: String) -> FileEntry { FileEntry(path: path, isDirectory: true) }
    func file(_ path: String, _ bytes: UInt64, mod: Date? = nil, acc: Date? = nil, id: UInt64? = nil) -> FileEntry {
        fileSet.insert(path)
        return FileEntry(path: path, allocatedBytes: bytes, modified: mod, accessed: acc, fileID: id)
    }
}

final class StorageAnalysisTests: XCTestCase {
    let home = "/Users/a"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let MB: UInt64 = 1 << 20

    func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    func makeTree() -> FakeTree {
        let t = FakeTree()
        t.dirs[home] = [t.dir(home + "/Movies"), t.dir(home + "/Documents"), t.dir(home + "/Library"),
                        t.dir(home + "/.cache"), t.file(home + "/loose.zip", 5 * MB),
                        FileEntry(path: home + "/linkdir", isDirectory: true, isSymlink: true)]
        t.dirs[home + "/linkdir"] = [t.file(home + "/linkdir/never.bin", 999 * MB)]
        t.dirs[home + "/Movies"] = [t.file(home + "/Movies/a.mov", 300 * MB, mod: day(400), acc: day(10)),
                                    t.file(home + "/Movies/b.MP4", 100 * MB, mod: day(500), acc: day(450)),
                                    t.dir(home + "/Movies/Sub")]
        t.dirs[home + "/Movies/Sub"] = [t.file(home + "/Movies/Sub/c.mkv", 50 * MB, mod: day(1))]
        t.dirs[home + "/Documents"] = [t.file(home + "/Documents/x.pdf", 2 * MB, mod: day(800)),
                                       t.file(home + "/Documents/copy1.bin", 10 * MB, id: 1),
                                       t.file(home + "/Documents/copy2.bin", 10 * MB, id: 2),
                                       t.file(home + "/Documents/hard.bin", 10 * MB, id: 1),
                                       t.file(home + "/Documents/small.txt", 100, mod: day(900)),
                                       t.dir(home + "/Documents/Pack.app")]
        t.dirs[home + "/Documents/Pack.app"] = [t.file(home + "/Documents/Pack.app/bin", 20 * MB)]
        t.dirs[home + "/Library"] = [t.dir(home + "/Library/Caches"), t.dir(home + "/Library/Application Support"),
                                     t.dir(home + "/Library/Containers"), t.dir(home + "/Library/Logs"),
                                     t.dir(home + "/Library/Developer")]
        t.dirs[home + "/Library/Caches"] = [t.dir(home + "/Library/Caches/com.slack")]
        t.dirs[home + "/Library/Caches/com.slack"] = [t.file(home + "/Library/Caches/com.slack/c", 7 * MB)]
        t.dirs[home + "/Library/Application Support"] = [t.dir(home + "/Library/Application Support/Slack")]
        t.dirs[home + "/Library/Application Support/Slack"] = [t.file(home + "/Library/Application Support/Slack/d", 3 * MB)]
        t.dirs[home + "/Library/Containers"] = [t.dir(home + "/Library/Containers/com.docker.docker")]
        t.dirs[home + "/Library/Containers/com.docker.docker"] = [t.file(home + "/Library/Containers/com.docker.docker/img", 40 * MB)]
        t.dirs[home + "/Library/Developer"] = [t.dir(home + "/Library/Developer/CoreSimulator"), t.dir(home + "/Library/Developer/Xcode")]
        t.dirs[home + "/Library/Developer/CoreSimulator"] = [t.file(home + "/Library/Developer/CoreSimulator/s", 30 * MB)]
        t.dirs[home + "/Library/Developer/Xcode"] = [t.dir(home + "/Library/Developer/Xcode/DerivedData")]
        t.dirs[home + "/Library/Developer/Xcode/DerivedData"] = [t.file(home + "/Library/Developer/Xcode/DerivedData/o", 12 * MB)]
        t.dirs[home + "/.cache"] = [t.file(home + "/.cache/blob", 6 * MB)]
        t.denied.insert(home + "/Library/Logs")
        return t
    }

    func analyze(_ t: FakeTree, _ o: StorageScanOptions = StorageScanOptions()) -> StorageAnalysis {
        StorageAnalyzer(policy: CleanupPolicy(home: home), tree: t, options: o).analyze()
    }

    // MARK: Tipos

    func testExtensionTable() {
        let cases: [(String, FileKind)] = [("MOV", .video), ("mp4", .video), ("jpg", .image), ("HEIC", .image),
            ("flac", .audio), ("pdf", .document), ("dmg", .archive), ("zip", .archive), ("iso", .archive),
            ("swift", .code), ("ts", .code), ("app", .app), ("xyz", .other), ("", .other)]
        for (e, k) in cases { XCTAssertEqual(FileKind.kind(forExtension: e), k, e) }
        XCTAssertEqual(FileEntry(path: "/a/.bashrc").fileExtension, "")
        XCTAssertEqual(FileEntry(path: "/a/b.TAR").fileExtension, "tar")
    }

    // MARK: Pastas, tipos, links, permissões

    func testFoldersLevel1And2AndTotals() {
        let a = analyze(makeTree())
        let movies = a.folders.first { $0.name == "Movies" }!
        XCTAssertEqual(movies.bytes, 450 * MB)
        XCTAssertEqual(movies.children.map(\.name), ["Sub"])
        XCTAssertEqual(movies.children[0].bytes, 50 * MB)
        XCTAssertEqual(a.folders.first?.name, "Movies")                       // maior primeiro
        XCTAssertEqual(a.folders.map(\.bytes), a.folders.map(\.bytes).sorted(by: >))
        XCTAssertEqual(a.folders.reduce(0) { $0 + $1.bytes }, a.totalBytes)
        XCTAssertEqual(a.folders.reduce(0.0) { $0 + $1.fraction }, 1.0, accuracy: 1e-9)
        XCTAssertFalse(a.folders.first { $0.name == "loose.zip" }!.isDirectory)
        XCTAssertNil(a.folders.first { $0.name == "linkdir" })                // link não é seguido
        XCTAssertEqual(a.deniedCount, 1)
    }

    func testTypeDistribution() {
        let a = analyze(makeTree())
        let video = a.types.first { $0.kind == .video }!
        XCTAssertEqual(video.bytes, 450 * MB)
        XCTAssertEqual(video.fileCount, 3)
        XCTAssertEqual(a.types.first { $0.kind == .app }!.bytes, 20 * MB)      // conteúdo de .app
        XCTAssertEqual(a.types.first { $0.kind == .archive }!.bytes, 5 * MB)
        XCTAssertEqual(a.types.map(\.bytes), a.types.map(\.bytes).sorted(by: >))
    }

    // MARK: Maiores e antigos

    func testLargestAndOldExcludeLibraryAndBundlesAndDotDirs() {
        let a = analyze(makeTree())
        let paths = a.largestFiles(limit: 3).map(\.path)
        XCTAssertEqual(paths, [home + "/Movies/a.mov", home + "/Movies/b.MP4", home + "/Movies/Sub/c.mkv"])
        XCTAssertFalse(a.records.contains { $0.path.contains("/Library/") || $0.path.contains(".cache") || $0.path.contains("Pack.app") })
        let old = a.oldFiles(olderThanDays: 365, minBytes: 1 * MB, now: now)
        XCTAssertEqual(old.map(\.path), [home + "/Movies/b.MP4", home + "/Documents/x.pdf"])   // a.mov foi acessado há 10 dias
        XCTAssertTrue(a.oldFiles(olderThanDays: 365, minBytes: 200 * MB, now: now).isEmpty)
        XCTAssertEqual(a.oldFiles(olderThanDays: 5000, minBytes: 1, now: now), [])
    }

    func testFileWithoutDatesIsNeverOld() {
        let t = FakeTree()
        t.dirs[home] = [t.file(home + "/nodate.bin", 5 * MB)]
        XCTAssertTrue(analyze(t).oldFiles(olderThanDays: 1, minBytes: 1, now: now).isEmpty)
    }

    // MARK: Duplicados

    func testDuplicateStagesAndHardlinks() {
        let t = makeTree()
        // mesmo tamanho, conteúdo diferente
        t.dirs[home + "/Documents"]! += [t.file(home + "/Documents/other.bin", 10 * MB, id: 9)]
        let a = analyze(t)
        let g10 = a.duplicateCandidates.first { $0.size == 10 * MB }!
        // hard.bin e copy1.bin são o mesmo arquivo (id 1): colapsam
        XCTAssertEqual(g10.paths, [home + "/Documents/copy1.bin", home + "/Documents/copy2.bin", home + "/Documents/other.bin"])
        let hashes = [home + "/Documents/copy1.bin": "H", home + "/Documents/copy2.bin": "H", home + "/Documents/other.bin": "Z"]
        let groups = DuplicateFinder.find(sizeGroups: a.duplicateCandidates) { hashes[$0] }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].paths, [home + "/Documents/copy1.bin", home + "/Documents/copy2.bin"])
        XCTAssertEqual(groups[0].reclaimableBytes, 10 * MB)                  // total − 1 cópia
        XCTAssertEqual(groups[0].keep, home + "/Documents/copy1.bin")
        XCTAssertEqual(groups[0].extraCopies, [home + "/Documents/copy2.bin"])
        XCTAssertEqual(DuplicateFinder.totalReclaimable(groups), 10 * MB)
        // hash ilegível tira do grupo
        XCTAssertTrue(DuplicateFinder.find(sizeGroups: a.duplicateCandidates) { $0.hasSuffix("copy2.bin") ? nil : "H" }
            .allSatisfy { $0.paths.count >= 2 })
    }

    func testNeverSuggestDeletingAllCopies() {
        let g = DuplicateGroup(size: 10, hash: "H", paths: ["/a", "/b", "/c"])
        XCTAssertFalse(g.isValidTrashSelection([]))
        XCTAssertFalse(g.isValidTrashSelection(["/a", "/b", "/c"]))
        XCTAssertFalse(g.isValidTrashSelection(["/zzz"]))
        XCTAssertTrue(g.isValidTrashSelection(["/b", "/c"]))
        XCTAssertTrue(g.isValidTrashSelection(["/a"]))
    }

    // MARK: Apps e desenvolvedor

    func testAppUsageJoinsByAlias() {
        var o = StorageScanOptions()
        o.appAliases = ["slack": "com.slack"]
        o.appDisplayNames = ["com.slack": "Slack"]
        let a = analyze(makeTree(), o)
        let slack = a.apps.first { $0.key == "com.slack" }!
        XCTAssertEqual(slack.displayName, "Slack")
        XCTAssertEqual(slack.caches, 7 * MB)
        XCTAssertEqual(slack.applicationSupport, 3 * MB)
        XCTAssertEqual(slack.total, 10 * MB)
        XCTAssertEqual(a.apps.first?.key, "com.docker.docker")                // 40 MB, maior primeiro
        // sem alias não junta
        XCTAssertEqual(analyze(makeTree()).apps.filter { $0.key == "slack" || $0.key == "com.slack" }.count, 2)
    }

    func testDeveloperCategories() {
        let a = analyze(makeTree())
        let byKind = Dictionary(uniqueKeysWithValues: a.developer.map { ($0.kind, $0) })
        XCTAssertEqual(byKind[.xcodeDerivedData]?.bytes, 12 * MB)
        XCTAssertEqual(byKind[.dotCache]?.bytes, 6 * MB)
        XCTAssertEqual(byKind[.simulators]?.bytes, 30 * MB)
        XCTAssertEqual(byKind[.docker]?.bytes, 40 * MB)
        XCTAssertNil(byKind[.npmCache])
        XCTAssertTrue(byKind[.simulators]!.isReportOnly)
        XCTAssertTrue(byKind[.docker]!.isReportOnly)
        XCTAssertFalse(byKind[.xcodeDerivedData]!.isReportOnly)
        XCTAssertEqual(DeveloperKind.dotCache.cleanupCategory, .packageCaches)
    }

    // MARK: Determinismo, cancelamento, progresso

    func testDeterministicAndCancel() {
        XCTAssertEqual(analyze(makeTree()), analyze(makeTree()))
        var calls = 0
        let r = StorageAnalyzer(policy: CleanupPolicy(home: home), tree: makeTree()).analyze(isCancelled: { calls += 1; return calls > 2 })
        XCTAssertTrue(r.wasCancelled)
    }

    func testExcludedPrefixes() {
        let t = FakeTree()
        t.dirs[home] = [t.dir("/System/x"), t.file(home + "/ok.bin", 1)]
        t.dirs["/System/x"] = [t.file("/System/x/a", 100)]
        XCTAssertEqual(analyze(t).totalBytes, 1)
    }

    func testProgressCallback() {
        let t = FakeTree()
        t.dirs[home] = (0..<1100).map { t.file(home + "/f\($0)", 1) }
        var n = 0
        _ = StorageAnalyzer(policy: CleanupPolicy(home: home), tree: t).analyze(progress: { _ in n += 1 })
        XCTAssertEqual(n, 2)
    }

    // MARK: CleanupPolicy.userSelected

    func testUserSelectedRules() {
        let t = FakeTree(); let p = CleanupPolicy(home: home)
        func ok(_ path: String) -> Bool { t.fileSet.insert(path); return p.canDelete(path, category: .userSelected, fs: t) }
        XCTAssertTrue(ok(home + "/Movies/a.mov"))
        XCTAssertTrue(ok(home + "/Downloads/x.iso"))
        XCTAssertTrue(ok(home + "/Library/Caches/com.x/file"))
        XCTAssertTrue(ok(home + "/Library/Logs/x.log"))
        XCTAssertFalse(ok(home + "/Library/Application Support/x/db"))
        XCTAssertFalse(ok(home + "/Library/Mobile Documents/com~apple~CloudDocs/doc.pdf"))
        XCTAssertFalse(ok(home + "/library/mobile documents/doc.pdf"))                       // caixa
        XCTAssertFalse(ok(home + "/LIBRARY/Preferences/a.plist"))                            // caixa
        XCTAssertFalse(ok("/Applications/Foo.app/Contents/MacOS/Foo"))
        XCTAssertFalse(ok("/Users/other/file.txt"))
        XCTAssertFalse(ok(home + "/Documents/Pack.app/Contents/x"))                          // dentro de pacote
        XCTAssertFalse(ok(home + "/Pictures/Photos Library.photoslibrary/originals/a.heic"))
        XCTAssertFalse(ok(home + "/.Trash/old.txt"))
        XCTAssertFalse(ok(home))
        XCTAssertFalse(ok(home + "/Documents/../Library/Preferences/a"))
        XCTAssertFalse(ok(home + "/Documents/"))
        // diretórios nunca
        XCTAssertFalse(p.canDelete(home + "/Documents/Folder", category: .userSelected, fs: t))
        XCTAssertFalse(p.canDelete(home + "/Documents", category: .userSelected, fs: t))
        // links nunca
        t.fileSet.insert(home + "/Documents/ln"); t.links.insert(home + "/Documents/ln")
        XCTAssertFalse(p.canDelete(home + "/Documents/ln", category: .userSelected, fs: t))
        // outras categorias seguem iguais (relatório-somente continua sem apagar)
        XCTAssertFalse(p.canDelete(home + "/Downloads/a.iso", category: .largeDownloads, fs: t))
        // FS sem informação de diretório: padrão conservador
        final class Plain: FileSystemProviding {
            func children(of path: String) -> [String] { [] }
            func allocatedBytes(at path: String) -> UInt64 { 0 }
            func isSymbolicLink(_ path: String) -> Bool { false }
        }
        XCTAssertFalse(p.canDelete(home + "/Documents/a.txt", category: .userSelected, fs: Plain()))
    }

    func testExecutorTrashesUserSelectedOnlyWhenAllowed() {
        let t = FakeTree(); var trashed: [String] = []
        t.fileSet.insert(home + "/Movies/a.mov")
        let ex = CleanupExecutor(policy: CleanupPolicy(home: home), fs: t) { trashed.append($0) }
        let r = ex.run([CleanupItem(path: home + "/Movies/a.mov", category: .userSelected, bytes: 1),
                        CleanupItem(path: home + "/Library/Preferences/x", category: .userSelected, bytes: 1),
                        CleanupItem(path: home + "/Movies", category: .userSelected, bytes: 1)])
        XCTAssertEqual(trashed, [home + "/Movies/a.mov"])
        XCTAssertEqual(r.skipped.count, 2)
        // o scanner nunca produz itens userSelected
        XCTAssertTrue(CleanupScanner(policy: CleanupPolicy(home: home), fs: t).scan().allSatisfy { $0.category != .userSelected })
    }

    // MARK: Snapshots e CSV

    func testLocalSnapshotParser() {
        let out = """
        Snapshots for disk /:
        com.apple.TimeMachine.2024-05-02-090000.local
        com.apple.TimeMachine.2024-05-01-120000.local

        """
        let s = LocalSnapshotParser.parse(out)
        XCTAssertEqual(s.map(\.stamp), ["2024-05-01-120000", "2024-05-02-090000"])
        XCTAssertTrue(LocalSnapshotParser.parse("").isEmpty)
    }

    func testCSVEscaping() {
        XCTAssertEqual(StorageReport.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(StorageReport.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(StorageReport.csvField("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(StorageReport.csvField("plain"), "plain")
        let csv = StorageReport.csv(analysis: analyze(makeTree()), duplicates: [], oldFiles: [])
        XCTAssertTrue(csv.hasPrefix("section,path,bytes,detail\n"))
        XCTAssertTrue(csv.contains("developer,"))
    }
}

final class DuplicateGroupTests: XCTestCase {
    func testRemovingKeepsAtLeastTwoOrDisappears() {
        let g = DuplicateGroup(size: 5, hash: "h", paths: ["/c", "/a", "/b"])
        XCTAssertEqual(g.paths, ["/a", "/b", "/c"])
        XCTAssertEqual(g.removing("/a")?.paths, ["/b", "/c"])
        XCTAssertNil(g.removing("/a")?.removing("/b"))
    }
}
