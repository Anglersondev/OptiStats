import XCTest
@testable import OptiStatsCore

final class ProcessGroupingTests: XCTestCase {
    func testOutermostAppBundle() {
        XCTAssertEqual(ProcessGrouper.outermostAppBundlePath(from:
            "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"),
            "/Applications/Brave Browser.app")
        XCTAssertEqual(ProcessGrouper.outermostAppBundlePath(from: "/Applications/Codex.app/Contents/MacOS/Codex"), "/Applications/Codex.app")
        XCTAssertNil(ProcessGrouper.outermostAppBundlePath(from: "/usr/sbin/WindowServer"))
        XCTAssertNil(ProcessGrouper.outermostAppBundlePath(from: nil))
        XCTAssertEqual(ProcessGrouper.appName(fromBundlePath: "/Applications/Brave Browser.app"), "Brave Browser")
    }

    func testGroupsHelpersUnderTheirAppAndSortsByFootprint() {
        let brave = "/Applications/Brave Browser.app"
        let samples = [
            process(1, "Brave Browser", path: brave + "/Contents/MacOS/Brave Browser", bundle: "com.brave.Browser", footprint: 600 * MiB),
            process(2, "Brave Browser Helper (Renderer)", path: brave + "/Contents/Frameworks/X.app/Contents/MacOS/H", footprint: 900 * MiB),
            process(3, "Brave Browser Helper (GPU)", path: brave + "/Contents/Frameworks/X.app/Contents/MacOS/H2", footprint: 300 * MiB),
            process(4, "Codex", path: "/Applications/Codex.app/Contents/MacOS/Codex", footprint: 400 * MiB),
            process(5, "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", uid: 88, footprint: 500 * MiB)
        ]
        let groups = ProcessGrouper.group(samples)
        XCTAssertEqual(groups.map(\.displayName), ["Brave Browser", "WindowServer", "Codex"])
        XCTAssertEqual(groups[0].processCount, 3)
        XCTAssertEqual(groups[0].footprintBytes, 1800 * MiB)
        XCTAssertEqual(groups[0].leader?.pid, 1)               // líder = executável direto em Contents/MacOS
        XCTAssertEqual(groups[0].bundleIdentifier, "com.brave.Browser")
        XCTAssertTrue(groups[1].isSystemOwned)
    }

    func testMissingFootprintCountsAsZeroNotCrash() {
        let g = ProcessGrouper.group([process(1, "x", path: "/Applications/X.app/Contents/MacOS/x", footprint: 0)])
        XCTAssertEqual(g[0].footprintBytes, 0)
    }

    func testSystemApplicationsAreNotSystemPaths() {
        XCTAssertFalse(ProcessGrouper.isSystemPath("/System/Applications/Mail.app/Contents/MacOS/Mail"))
        XCTAssertTrue(ProcessGrouper.isSystemPath("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
        XCTAssertTrue(ProcessGrouper.isSystemPath("/usr/libexec/trustd"))
    }
}

final class ProtectionPolicyTests: XCTestCase {
    let policy = ProtectionPolicy()

    func testBrowsersAndEditorsAreSoftProtectedByDefault() {
        let brave = appGroup("Brave Browser", bundle: "com.brave.Browser", footprint: 2 * GiB)
        let v = policy.verdict(for: brave, context: AppRuntimeContext())
        XCTAssertTrue(v.isSoftProtected); XCTAssertFalse(v.isHardBlocked)
        XCTAssertTrue(v.reasons.contains(.category(.browser)))
        let codex = appGroup("Codex", footprint: GiB)               // sem bundle ID: reconhecido pelo nome
        XCTAssertTrue(policy.verdict(for: codex, context: AppRuntimeContext()).reasons.contains(.category(.editorOrIDE)))
    }

    func testUserCanUnprotectADefaultCategoryButNotSystemApps() {
        var p = policy
        p.userUnprotectedBundleIDs = ["com.brave.Browser"]
        let brave = appGroup("Brave Browser", bundle: "com.brave.Browser", footprint: GiB)
        XCTAssertFalse(p.verdict(for: brave, context: AppRuntimeContext()).isProtected)
        let sys = appGroup("Finder", bundle: "com.apple.finder", footprint: GiB, path: "/System/Library/CoreServices/Finder.app", system: true)
        p.userUnprotectedBundleIDs.insert("com.apple.finder")
        XCTAssertTrue(p.verdict(for: sys, context: AppRuntimeContext()).isHardBlocked)
    }

    func testFrontmostAndUserProtected() {
        let notes = appGroup("Notes", bundle: "com.apple.Notes", footprint: GiB)
        XCTAssertFalse(policy.verdict(for: notes, context: AppRuntimeContext()).isProtected)
        XCTAssertTrue(policy.verdict(for: notes, context: AppRuntimeContext(isFrontmost: true)).reasons.contains(.frontmost))
        var p = policy; p.userProtectedBundleIDs = ["com.apple.Notes"]
        XCTAssertTrue(p.verdict(for: notes, context: AppRuntimeContext()).reasons.contains(.userProtected))
    }

    func testHardBlocks() {
        let ownApp = appGroup("OptiStats", bundle: policy.ownBundleIdentifier, footprint: 100 * MiB)
        XCTAssertTrue(policy.verdict(for: ownApp, context: AppRuntimeContext()).reasons.contains(.thisApp))
        let ws = appGroup("WindowServer", bundle: nil, footprint: GiB)
        XCTAssertTrue(policy.verdict(for: ws, context: AppRuntimeContext()).reasons.contains(.essentialProcess))
        let bare = AppGroup(id: "proc:foo", displayName: "foo", bundlePath: nil, bundleIdentifier: nil, leader: nil,
                            members: [process(9, "foo", footprint: GiB)], isSystemOwned: false)
        XCTAssertTrue(policy.verdict(for: bare, context: AppRuntimeContext()).reasons.contains(.noIdentity))
        let rootOwned = AppGroup(id: "app:/Applications/R.app", displayName: "R", bundlePath: "/Applications/R.app", bundleIdentifier: "x.r",
                                 leader: nil, members: [process(9, "r", uid: 0, footprint: GiB)], isSystemOwned: false)
        XCTAssertTrue(policy.verdict(for: rootOwned, context: AppRuntimeContext()).isHardBlocked)
    }

    func testAppleAppsInSystemApplicationsCanBeOfferedWhenNotProtectedCategory() {
        let mail = appGroup("Mail", bundle: "com.apple.mail", footprint: GiB, path: "/System/Applications/Mail.app")
        XCTAssertFalse(policy.verdict(for: mail, context: AppRuntimeContext()).isProtected)
        let safari = appGroup("Safari", bundle: "com.apple.Safari", footprint: GiB, path: "/System/Applications/Safari.app")
        XCTAssertTrue(policy.verdict(for: safari, context: AppRuntimeContext()).isSoftProtected)
    }
}
