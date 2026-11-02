import Foundation
import OptiStatsCore

// No real SMC writes and no administrator privileges: every driver call uses this fake.
enum HelperLog { static func write(_ message: String) {} }
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAIL: \(message)") }
}

final class FakeSMC: SMCFanIO {
    var lastError: String?
    var values: [String: SMCFanValue] = [:]
    var writes: [(String, [UInt8])] = []
    var ignoreDirectMode = false
    var failTargetWrite = false
    var failTargetReset = false
    var failModeReset = false
    var missingModeOnRestore = false
    init() {
        byte("FNum", 2); byte("F0Md", 0); byte("F1Md", 0); byte("Ftst", 0)
        for i in 0..<2 {
            number("F\(i)Mn", 1200); number("F\(i)Mx", i == 0 ? 6000 : 6500)
            number("F\(i)Tg", 1500); number("F\(i)Ac", 1500)
        }
    }
    func byte(_ key: String, _ value: UInt8) { values[key] = SMCFanValue(key: key, type: "ui8 ", size: 1, bytes: [value]) }
    func number(_ key: String, _ value: Double) {
        values[key] = SMCFanValue(key: key, type: "flt ", size: 4,
                                  bytes: SMCFanTargetEncoding.encode(type: "flt ", rpm: value, size: 4)!)
    }
    func open() -> Bool { true }
    func read(_ key: String) -> SMCFanValue? {
        if missingModeOnRestore && key == "F0Md" { return nil }
        return values[key]
    }
    func write(_ key: String, bytes: [UInt8], size: Int) -> Bool {
        writes.append((key, bytes))
        if failTargetWrite && key.hasSuffix("Tg") && bytes.contains(where: { $0 != 0 }) { return false }
        if failModeReset && key.hasSuffix("Md") && bytes.first == 0 { return false }
        if failTargetReset && key.hasSuffix("Tg") && bytes.allSatisfy({ $0 == 0 }) { return false }
        if ignoreDirectMode && key.hasSuffix("Md") && bytes.first == 1 && values["Ftst"]?.bytes.first != 1 { return true }
        guard var value = values[key], size == value.size, bytes.count == size else { return false }
        value.bytes = bytes; values[key] = value
        return true
    }
}
func succeeds(_ result: Result<Void, SMCFanDriver.Failure>) -> Bool {
    if case .success = result { return true }; return false
}
func driver(_ smc: FakeSMC, abort: @escaping () -> Bool = { false }) -> SMCFanDriver {
    SMCFanDriver(smc: smc, delay: { _ in }, shouldAbort: abort)
}

do {
    let smc = FakeSMC(); smc.ignoreDirectMode = true
    let d = driver(smc)
    expect(succeeds(d.setTarget(fan: 0, rpm: 6000)), "100% acquired from a cold automatic fan")
    expect(smc.values["Ftst"]?.bytes.first == 1, "accepted but ineffective direct mode falls back to Ftst")
    expect(smc.values["F0Md"]?.bytes.first == 1, "manual mode applied after unlock")
    expect(smc.values["F0Tg"]?.number == 6000, "correct maximum target written")
    expect(succeeds(d.setTarget(fan: 1, rpm: 6500)), "second fan uses its own maximum")
    expect(d.restoreAutomatic(), "automatic restoration confirmed")
    expect(smc.values["Ftst"]?.bytes.first == 0, "unlock released")
    expect(smc.values["F0Tg"]?.number == 0 && smc.values["F1Tg"]?.number == 0, "all owned targets reset")
    expect(!d.isManualActive, "ownership released only after confirmation")
}
do {
    let smc = FakeSMC(); let d = driver(smc)
    expect(succeeds(d.setTarget(fan: 0, rpm: 4000)), "manual setup")
    smc.byte("F0Md", 3)
    expect(d.restoreAutomatic(), "restore handles firmware mode 3")
    expect(smc.values["F0Md"]?.bytes.first == 0, "mode 3 is explicitly reset")
    expect(!smc.writes.contains(where: { $0.0 == "F1Md" }), "restore does not touch an unowned fan")
}
do {
    let smc = FakeSMC(); let d = driver(smc)
    _ = d.setTarget(fan: 0, rpm: 4000); smc.failTargetReset = true; smc.failModeReset = true
    expect(!d.restoreAutomatic() && d.restorePending, "remaining in manual mode cannot report success")
    smc.failTargetReset = false; smc.failModeReset = false
    expect(d.restoreAutomatic() && !d.restorePending, "pending restoration recovers")
}
do {
    let smc = FakeSMC(); let d = driver(smc)
    _ = d.setTarget(fan: 0, rpm: 4000); smc.missingModeOnRestore = true
    expect(!d.restoreAutomatic(), "missing readback is not proof of automatic mode")
    smc.missingModeOnRestore = false
    expect(d.restoreAutomatic(), "restore can retry a transient missing mode")
}
do {
    let smc = FakeSMC(); let d = driver(smc)
    expect(!succeeds(d.setTarget(fan: 0, rpm: 9999)), "out-of-range RPM rejected")
    expect(smc.writes.isEmpty, "invalid requests cause no hardware writes")
    smc.byte("F0Md", 1)
    expect(!succeeds(d.setTarget(fan: 0, rpm: 4000)), "conflicting controller rejected")
    expect(smc.writes.isEmpty, "another controller's fan is untouched")
}
do {
    let smc = FakeSMC(); smc.failTargetWrite = true; let d = driver(smc)
    expect(!succeeds(d.setTarget(fan: 0, rpm: 4000)), "failed target write is reported")
    expect(!d.isManualActive && smc.values["F0Md"]?.bytes.first == 0, "failed command restores automatic")
}
do {
    let suite = "dev.optistats.regression.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let s = FanControlSettings(defaults: defaults, modelKey: { "Mac16,8|macOS27" })
    s.savedTargets = [0: .maximum, 1: .rpm(4000)]
    let resumed = FanControlSettings(defaults: defaults, modelKey: { "Mac16,8|macOS27" })
    expect(resumed.savedTargets == s.savedTargets, "fan intent persists across settings instances")
    expect(resumed.savedTargets[0]?.resolve(min: 1200, max: 7000) == 7000, "100% resolves fresh maximum")
    expect(resumed.savedTargets[1]?.resolve(min: 4500, max: 7000) == nil, "stale fixed RPM rejected")
    let other = FanControlSettings(defaults: defaults, modelKey: { "OtherMac|macOS27" })
    expect(other.savedTargets.isEmpty, "preferences never migrate to different hardware")
    s.savedTargets = [:]
    expect(resumed.savedTargets.isEmpty, "Automatic clears saved intent")
}

do {
    let smc = FakeSMC(); let d = driver(smc)
    _ = d.setTarget(fan: 0, rpm: 4000)
    smc.byte("F0Md", 3); smc.failModeReset = true
    expect(d.restoreAutomatic(), "firmware auto3 readback wins over an intermediate rejected mode write")
    expect(!d.restorePending, "confirmed automatic does not leave a false pending fault")
}

do {
    let smc = FakeSMC(); let d = driver(smc)
    _ = d.setTarget(fan: 0, rpm: 6000)
    smc.byte("F0Md", 3); smc.number("F0Tg", 1200)
    expect(succeeds(d.maintainManualTargets()), "heartbeat reconciles firmware target drift")
    expect(smc.values["F0Md"]?.bytes.first == 1 && smc.values["F0Tg"]?.number == 6000, "saved manual target is maintained")
    _ = d.restoreAutomatic()
    let writes = smc.writes.count
    expect(succeeds(d.maintainManualTargets()) && smc.writes.count == writes, "Automatic cancels heartbeat target reconciliation")
}

print("Hardware/settings regressions: \(checks) checks passed (simulated hardware, no SMC writes).")
