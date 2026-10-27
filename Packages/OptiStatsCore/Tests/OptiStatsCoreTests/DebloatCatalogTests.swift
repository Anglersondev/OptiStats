import XCTest
@testable import OptiStatsCore

final class DebloatCatalogTests: XCTestCase {
    static let sample = """
    # header comment
    # === Spotlight / app launcher ===
    # explanatory comment
    com.apple.campo                  # Cmd-Space

    # === Siri [balanced] ===
    com.apple.assistantd [sip-off]   # Siri core
    com.apple.Siri.agent             # Siri agent

    # === Telemetry [telemetry] ===
    com.apple.analyticsd [sip-off]   # diagnostics

    # === Spotlight KeepAlive (x) [macos>=27] ===
    com.apple.metadata.mds           # server

    # === iCloud ===
    com.apple.cloudd [sip-off]       # iCloud sync core
    bad label with spaces
    com.apple.bad;rm                 # injection
    com.apple.Siri.agent             # duplicate
    """

    func testParseSectionsAndItems() {
        let c = UpstreamCatalog.parse(Self.sample)
        XCTAssertEqual(c.sections.map { $0.title }, ["Spotlight / app launcher", "Siri", "Telemetry", "Spotlight KeepAlive (x)", "iCloud"])
        XCTAssertEqual(c.sections[0].preset, .none)
        XCTAssertEqual(c.sections[1].preset, .balanced)
        XCTAssertEqual(c.sections[2].preset, .telemetry)
        XCTAssertEqual(c.sections[3].minMacOS, 27)
        let a = c.item("com.apple.assistantd")!
        XCTAssertTrue(a.sipOff); XCTAssertEqual(a.comment, "Siri core"); XCTAssertEqual(a.sectionTitle, "Siri")
        XCTAssertFalse(c.item("com.apple.Siri.agent")!.sipOff)
        XCTAssertNil(c.item("com.apple.bad;rm"))
        XCTAssertEqual(c.items.filter { $0.label == "com.apple.Siri.agent" }.count, 1)
        XCTAssertEqual(c.items.count, 7)
    }

    func testPresets() {
        let c = UpstreamCatalog.parse(Self.sample)
        XCTAssertEqual(Set(c.presetItems(.telemetry).map { $0.label }), ["com.apple.analyticsd"])
        XCTAssertEqual(Set(c.presetItems(.balanced).map { $0.label }),
                       ["com.apple.analyticsd", "com.apple.assistantd", "com.apple.Siri.agent"])
        XCTAssertEqual(c.presetItems(.all).count, c.items.count)
    }

    func testRiskAndWarnings() {
        let c = UpstreamCatalog.parse(Self.sample)
        XCTAssertEqual(c.item("com.apple.analyticsd")!.risk, .low)
        XCTAssertEqual(c.item("com.apple.assistantd")!.risk, .medium)
        XCTAssertEqual(c.item("com.apple.campo")!.risk, .high)
        XCTAssertEqual(c.item("com.apple.cloudd")!.warnings, [.icloud])
        XCTAssertEqual(c.item("com.apple.cloudd")!.risk, .high)
        let w = UpstreamItem(label: "com.apple.AirPlayXPCHelper", comment: "", sipOff: false, sectionTitle: "x", sectionPreset: .balanced)
        XCTAssertEqual(w.warnings, [.airplay]); XCTAssertEqual(w.risk, .high)
    }

    func testDiff() {
        let old = UpstreamCatalog.parse("# === A ===\ncom.apple.a\ncom.apple.b\n")
        let new = UpstreamCatalog.parse("# === A ===\ncom.apple.b\ncom.apple.c\ncom.apple.d\n")
        let d = UpstreamCatalog.diff(old: old, new: new)
        XCTAssertEqual(d.added, ["com.apple.c", "com.apple.d"]); XCTAssertEqual(d.removed, ["com.apple.a"])
        XCTAssertTrue(UpstreamCatalog.diff(old: old, new: old).isEmpty)
    }

    func testExtractEmbeddedLabels() {
        let script = """
        #!/usr/bin/env python3
        import os
        EMBEDDED_LABELS = \"\"\"\\
        # === Siri [balanced] ===
        com.apple.Siri.agent   # agent
        \"\"\"
        def main(): pass
        """
        let block = UpstreamCatalog.extractEmbeddedLabels(fromScript: script)
        XCTAssertNotNil(block)
        XCTAssertEqual(UpstreamCatalog.parse(block!).items.map { $0.label }, ["com.apple.Siri.agent"])
        XCTAssertNil(UpstreamCatalog.extractEmbeddedLabels(fromScript: "print('hi')"))
        XCTAssertNil(UpstreamCatalog.extractEmbeddedLabels(fromScript: "EMBEDDED_LABELS = \"\"\"\n# nothing\n\"\"\""))
    }

    func testDomainFromPlistPath() {
        XCTAssertEqual(ServiceDomain.forPlist(atPath: "/System/Library/LaunchDaemons/com.apple.x.plist"), .system)
        XCTAssertEqual(ServiceDomain.forPlist(atPath: "/System/Library/LaunchAgents/com.apple.x.plist"), .user)
        XCTAssertNil(ServiceDomain.forPlist(atPath: "/tmp/x.plist"))
    }

    func testPlannerUpstreamGuarantees() {
        let c = UpstreamCatalog.parse(Self.sample)
        let p = DebloatPlanner(uid: 501)
        let a = c.item("com.apple.assistantd")!
        XCTAssertEqual(p.disableCommand(a, domain: .user, in: c, level: .user)!, ["launchctl", "disable", "gui/501/com.apple.assistantd"])
        XCTAssertEqual(p.enableCommand(a, domain: .user, in: c, level: .user)!, ["launchctl", "enable", "gui/501/com.apple.assistantd"])
        XCTAssertNil(p.disableCommand(a, domain: .user, in: c, level: .auditOnly))
        XCTAssertNil(p.disableCommand(a, domain: .system, in: c, level: .user))
        XCTAssertEqual(p.disableCommand(a, domain: .system, in: c, level: .system)!, ["launchctl", "disable", "system/com.apple.assistantd"])
        // fora do catálogo carregado
        let other = UpstreamItem(label: "com.apple.mDNSResponder", comment: "", sipOff: false, sectionTitle: "x", sectionPreset: .none)
        XCTAssertNil(p.disableCommand(other, domain: .user, in: c, level: .system))
        // label com caractere inválido, mesmo que "esteja" no catálogo construído à mão
        let evil = UpstreamItem(label: "a b;rm", comment: "", sipOff: false, sectionTitle: "x", sectionPreset: .none)
        let evilCat = UpstreamCatalog(sections: [UpstreamSection(title: "x", preset: .none, minMacOS: nil, items: [evil])])
        XCTAssertNil(p.disableCommand(evil, domain: .user, in: evilCat, level: .system))
        XCTAssertEqual(p.manualCommand(a, domain: .system, disable: true), "sudo launchctl disable system/com.apple.assistantd")
    }

    func testBundledCatalogParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/OptiStats/Resources/debloat-catalog.txt").standardized
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("catálogo não encontrado") }
        let c = UpstreamCatalog.parse(text)
        XCTAssertGreaterThan(c.items.count, 250)
        XCTAssertFalse(c.presetItems(.telemetry).isEmpty)
        XCTAssertLessThan(c.presetItems(.balanced).count, c.items.count)
    }
}
