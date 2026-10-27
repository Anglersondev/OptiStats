import XCTest
@testable import OptiStatsCore

final class DebloatTests: XCTestCase {
    func testParseDisabledTable() {
        let out = """
        disabled services = {
            "com.apple.Siri.agent" => disabled
            "com.apple.gamed" => enabled
            "com.apple.foo" => true
            "com.apple.bar" => false
        }
        """
        let t = DisabledTable.parse(out)
        XCTAssertEqual(t["com.apple.Siri.agent"], true); XCTAssertEqual(t["com.apple.gamed"], false)
        XCTAssertEqual(t["com.apple.foo"], true); XCTAssertEqual(t["com.apple.bar"], false)
    }
    func testCommandsOnlyForCatalogUserServices() {
        let p = DebloatPlanner(uid: 501)
        let siri = ServiceCatalog.service("com.apple.Siri.agent")!
        XCTAssertEqual(p.disableCommand(siri)!, ["launchctl", "disable", "gui/501/com.apple.Siri.agent"])
        XCTAssertEqual(p.enableCommand(siri)!, ["launchctl", "enable", "gui/501/com.apple.Siri.agent"])
        let fake = CatalogService(label: "com.apple.mDNSResponder", titleKey: "x", domain: .user, risk: .low)
        XCTAssertNil(p.disableCommand(fake))                       // fora do catálogo → nunca
        let sys = CatalogService(label: "com.apple.siri.sys", titleKey: "x", domain: .system, risk: .low)
        XCTAssertNil(p.disableCommand(sys))
        XCTAssertEqual(p.manualCommand(sys, disable: true), "sudo launchctl disable system/com.apple.siri.sys")
    }
    func testCatalogExcludesCriticalAreas() {
        for s in ServiceCatalog.all {
            for bad in ["icloud", "appstore", "softwareupdate", "mDNS", "securityd", "WindowServer", "coreaudio", "Finder", "Dock", "bird", "cloudd"] {
                XCTAssertFalse(s.label.lowercased().contains(bad.lowercased()), s.label)
            }
        }
    }
    func testSnapshotRestoreSkipsAlreadyDisabled() {
        let s = DebloatSnapshot(date: Date(), previouslyDisabled: ["a"], changed: ["a", "b"])
        XCTAssertEqual(s.toRestore, ["b"])
    }
}
