import XCTest
@testable import OptiStatsCore

final class ManualQuitReviewTests: XCTestCase {
    func testExplicitReviewIncludesSmallAppsWithoutMemoryHistoryOrIdleTime() {
        let tiny = appGroup("SmallApp", bundle: "dev.test.SmallApp", footprint: 20 * MiB)
        let review = OptimizationAdvisor().quitReview(groups: [tiny], frontmostBundleID: nil)

        XCTAssertEqual(review.assessment, .insufficientData)
        XCTAssertEqual(review.candidates.map(\.group.id), [tiny.id])
        XCTAssertEqual(review.candidates.first?.estimatedReclaimBytes, tiny.footprintBytes)
        XCTAssertTrue(review.candidates.first?.risks.contains(.mayLoseUnsavedWork) == true)
    }

    func testManualReviewStillExcludesProtectedFrontmostOwnAndSystemApps() {
        let ordinary = appGroup("Ordinary", bundle: "dev.test.Ordinary", footprint: 40 * MiB)
        let browser = appGroup("Brave Browser", bundle: "com.brave.Browser", footprint: 30 * MiB)
        let own = appGroup("OptiStats", bundle: "app.optistats.OptiStats", footprint: 80 * MiB)
        let frontmost = appGroup("ActiveApp", bundle: "dev.test.ActiveApp", footprint: 50 * MiB)
        let system = appGroup("SystemApp", bundle: "dev.test.SystemApp", footprint: 10 * MiB, system: true)
        let review = OptimizationAdvisor().quitReview(groups: [ordinary, browser, own, frontmost, system],
                                                       frontmostBundleID: "dev.test.ActiveApp")

        XCTAssertEqual(review.candidates.map(\.group.id), [ordinary.id])
        XCTAssertEqual(Set(review.protectedTop.map(\.group.id)), Set([browser.id, own.id, frontmost.id, system.id]))
        XCTAssertTrue(review.protectedTop.allSatisfy { $0.verdict.isProtected })
        XCTAssertTrue(review.protectedTop.first { $0.group.id == browser.id }?.verdict.reasons.contains(.category(.browser)) == true)
        XCTAssertTrue(review.protectedTop.first { $0.group.id == frontmost.id }?.verdict.reasons.contains(.frontmost) == true)
    }

    func testManualReviewRequiresAnIdentifiableAppAndLeader() {
        let eligible = appGroup("Eligible", bundle: "dev.test.Eligible", footprint: 80 * MiB)
        var noLeader = appGroup("NoLeader", bundle: "dev.test.NoLeader", footprint: 90 * MiB)
        noLeader.leader = nil
        var noBundlePath = appGroup("NoBundlePath", bundle: "dev.test.NoBundlePath", footprint: 90 * MiB)
        noBundlePath.bundlePath = nil
        var noBundleID = appGroup("NoBundleID", bundle: "dev.test.NoBundleID", footprint: 90 * MiB)
        noBundleID.bundleIdentifier = nil
        let review = OptimizationAdvisor().quitReview(groups: [noLeader, noBundlePath, noBundleID, eligible],
                                                       frontmostBundleID: nil)

        XCTAssertEqual(review.candidates.map(\.group.id), [eligible.id])
    }

    func testManualReviewShowsAllEligibleAppsSortedByFootprint() {
        let groups = (1...9).map { i in
            appGroup("App\(i)", bundle: "dev.test.App\(i)", footprint: UInt64(i) * MiB, pid: Int32(100 + i))
        }
        var config = AdvisorConfig()
        config.maxCandidates = 2
        let review = OptimizationAdvisor(config: config).quitReview(groups: groups, frontmostBundleID: nil)

        XCTAssertEqual(review.candidates.count, 9)
        XCTAssertEqual(review.candidates.map(\.group.id), groups.reversed().map(\.id))
    }
}
