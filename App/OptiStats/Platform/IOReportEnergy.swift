import Foundation
import OptiStatsCore

/// Potência por domínio (CPU/GPU/ANE/DRAM) a partir do grupo "Energy Model" do IOReport — API PRIVADA resolvida por dlsym.
/// Lê contadores de energia (delta entre duas amostras ÷ tempo): valores `.calculated`, com precisão dependente do chip.
/// Abordagem de assinatura/delta adaptada do Stats (exelban/stats, MIT); os nomes de canal NÃO são validados em todos os chips.
final class IOReportEnergy {
    struct Watts: Equatable {
        var cpu: Double?
        var gpu: Double?
        var ane: Double?
        var dram: Double?
        var isEmpty: Bool { cpu == nil && gpu == nil && ane == nil && dram == nil }
    }

    private typealias CopyChannelsFn = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValueFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannels: CopyChannelsFn?
    private let createSubscription: CreateSubscriptionFn?
    private let createSamples: CreateSamplesFn?
    private let createDelta: CreateDeltaFn?
    private let channelName: ChannelNameFn?
    private let channelUnit: ChannelNameFn?
    private let integerValue: IntegerValueFn?

    private var subscription: UnsafeMutableRawPointer?
    private var channels: CFMutableDictionary?
    private var previous: (sample: CFDictionary, time: TimeInterval)?

    init() {
        let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        copyChannels = sym("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self)
        createSubscription = sym("IOReportCreateSubscription", as: CreateSubscriptionFn.self)
        createSamples = sym("IOReportCreateSamples", as: CreateSamplesFn.self)
        createDelta = sym("IOReportCreateSamplesDelta", as: CreateDeltaFn.self)
        channelName = sym("IOReportChannelGetChannelName", as: ChannelNameFn.self)
        channelUnit = sym("IOReportChannelGetUnitLabel", as: ChannelNameFn.self)
        integerValue = sym("IOReportSimpleGetIntegerValue", as: IntegerValueFn.self)
    }

    var isAvailable: Bool {
        copyChannels != nil && createSubscription != nil && createSamples != nil && createDelta != nil
            && channelName != nil && channelUnit != nil && integerValue != nil
    }

    /// Descarta a linha de base e a amostra retida (libera memória). A assinatura é mantida de propósito:
    /// o IOReport não documenta a liberação do objeto e recriá-la a cada retomada vazaria memória.
    func reset() { previous = nil }

    private func subscribe() -> Bool {
        if subscription != nil { return true }
        guard let copyChannels, let createSubscription,
              let chans = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return false }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, chans, &subscribed, 0, nil) else { return false }
        subscription = sub
        channels = subscribed?.takeRetainedValue() ?? chans
        return true
    }

    /// Potência média desde a leitura anterior. nil na primeira chamada (linha de base) ou se indisponível.
    func read(at now: TimeInterval) -> Watts? {
        guard isAvailable, subscribe(), let sub = subscription, let createSamples, let createDelta,
              let sample = createSamples(sub, channels, nil)?.takeRetainedValue() else { return nil }
        defer { previous = (sample, now) }
        guard let prev = previous, now > prev.time, now - prev.time < 120,
              let delta = createDelta(prev.sample, sample, nil)?.takeRetainedValue() else { return nil }
        let dt = now - prev.time
        guard let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary],
              let channelName, let channelUnit, let integerValue else { return nil }

        var cpuTotal: Double?, cpuParts = 0.0, anyCPUPart = false
        var gpu: Double?, ane = 0.0, anyANE = false, dram = 0.0, anyDRAM = false
        for item in items {
            guard let name = channelName(item)?.takeUnretainedValue() as String?,
                  let unit = channelUnit(item)?.takeUnretainedValue() as String? else { continue }
            guard let scale = Self.joulesPerUnit(unit) else { continue }
            let joules = Double(integerValue(item, 0)) * scale
            guard joules.isFinite, joules >= 0 else { continue }
            let watts = joules / dt
            switch name {
            case "CPU Energy": cpuTotal = watts
            case "GPU Energy": gpu = watts
            default:
                if name.hasSuffix("CPU") && (name.hasPrefix("EACC") || name.hasPrefix("PACC")) { cpuParts += watts; anyCPUPart = true }
                else if name.hasPrefix("ANE") { ane += watts; anyANE = true }
                else if name.hasPrefix("DRAM") { dram += watts; anyDRAM = true }
            }
        }
        let result = Watts(cpu: cpuTotal ?? (anyCPUPart ? cpuParts : nil), gpu: gpu,
                           ane: anyANE ? ane : nil, dram: anyDRAM ? dram : nil)
        return result.isEmpty ? nil : result
    }

    private static func joulesPerUnit(_ unit: String) -> Double? {
        switch unit {
        case "mJ": return 1e-3
        case "uJ", "µJ": return 1e-6
        case "nJ": return 1e-9
        case "J": return 1
        default: return nil   // unidade desconhecida: descarta o canal
        }
    }
}
