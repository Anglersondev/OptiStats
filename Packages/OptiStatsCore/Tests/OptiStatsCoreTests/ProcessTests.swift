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

final class ProcessHelperGroupingTests: XCTestCase {
    func testWebKitStyleOrphanJoinsAppByResponsiblePID() {
        let safari = "/Applications/Safari.app"
        var web = process(20, "com.apple.WebKit.WebContent", path: "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc/Contents/MacOS/WebContent", footprint: 700 * MiB)
        web.responsiblePID = 10
        let groups = ProcessGrouper.group([
            process(10, "Safari", path: safari + "/Contents/MacOS/Safari", bundle: "com.apple.Safari", footprint: 300 * MiB), web])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].processCount, 2)
        XCTAssertEqual(groups[0].footprintBytes, 1000 * MiB)
    }

    func testBundlePrefixJoinsHelperWithoutAppPath() {
        let groups = ProcessGrouper.group([
            process(1, "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundle: "com.google.Chrome", footprint: 200 * MiB),
            process(2, "chrome_crashpad", path: "/tmp/x/crashpad", bundle: "com.google.Chrome.helper", footprint: 50 * MiB),
            process(3, "other", path: "/usr/bin/other", bundle: "com.google.Other", footprint: 10 * MiB)])
        XCTAssertEqual(groups.first { $0.displayName == "Google Chrome" }?.processCount, 2)
        XCTAssertEqual(groups.count, 2)
    }

    func testUnrelatedProcessesNeverMerged() {
        let groups = ProcessGrouper.group([
            process(1, "A", path: "/Applications/A.app/Contents/MacOS/A", bundle: "com.a.app", footprint: MiB),
            process(2, "daemon", path: "/usr/sbin/daemon", bundle: "com.apple.daemon", footprint: MiB)])
        XCTAssertEqual(groups.count, 2)
    }

    func testRolesAndHeaviestMembers() {
        let g = appGroup("Brave", footprint: 0)
        var members = [process(1, "Brave", footprint: 100 * MiB), process(2, "Brave Helper (Renderer)", footprint: 900 * MiB),
                       process(3, "Brave Helper (GPU)", footprint: 300 * MiB), process(4, "Brave Helper", footprint: 10 * MiB)]
        members[0].name = "Brave"
        var group = g; group.members = members
        let top = ProcessGrouper.heaviestMembers(of: group, limit: 2)
        XCTAssertEqual(top.map(\.identity.pid), [2, 3])
        XCTAssertEqual(ProcessGrouper.childRole(of: members[1]), .renderer)
        XCTAssertEqual(ProcessGrouper.childRole(of: members[2]), .gpu)
        XCTAssertEqual(ProcessGrouper.childRole(of: members[3]), .helper)
        XCTAssertEqual(ProcessGrouper.childRole(of: members[0]), .main)
    }
}
