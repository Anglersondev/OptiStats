import Foundation

/// Inventário de chaves do SMC conhecidas para Apple Silicon.
///
/// ATENÇÃO: é uma tabela de CONHECIMENTO adaptada do catálogo do Stats (MIT, ver THIRD_PARTY_NOTICES.md),
/// não um contrato. Cada chave só é usada se existir no Mac em execução e devolver valor plausível.
/// Chaves de CPU/GPU descrevem zonas térmicas do SMC, não necessariamente um núcleo físico isolado.
public struct SMCSensorSpec: Equatable {
    public var key: String
    public var name: String
    public var kind: SensorKind
    public var role: SensorRole
    public var generations: Set<Int>?      // nil = todas as gerações
    public var tiers: Set<ChipTier>?       // nil = todas as variantes

    public func applies(to chip: ChipFamily?) -> Bool {
        guard let chip else { return generations == nil && tiers == nil }
        if let g = generations, !g.contains(chip.generation) { return false }
        if let t = tiers, !t.contains(chip.tier) { return false }
        return true
    }

    public func descriptor() -> SensorDescriptor {
        SensorDescriptor(key: key, name: name, kind: kind, role: role, source: .smc)
    }
}

public enum SMCCatalog {
    private static func zones(_ gens: [Int], role: SensorRole, label: String, keys: [String],
                              tiers: Set<ChipTier>? = nil) -> [SMCSensorSpec] {
        keys.enumerated().map { i, k in
            SMCSensorSpec(key: k, name: "\(label) \(i + 1)", kind: .temperature, role: role,
                          generations: Set(gens), tiers: tiers)
        }
    }

    private static func general(_ key: String, _ name: String, _ kind: SensorKind, _ role: SensorRole) -> SMCSensorSpec {
        SMCSensorSpec(key: key, name: name, kind: kind, role: role, generations: nil, tiers: nil)
    }

    public static let all: [SMCSensorSpec] = {
        var l: [SMCSensorSpec] = []
        // M1
        l += zones([1], role: .cpuEfficiencyZone, label: "CPU efficiency zone", keys: ["Tp09", "Tp0T"])
        l += zones([1], role: .cpuPerformanceZone, label: "CPU performance zone",
                   keys: ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"])
        l += zones([1], role: .gpuZone, label: "GPU zone", keys: ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        l += zones([1], role: .memoryZone, label: "Memory zone", keys: ["Tm02", "Tm06", "Tm08", "Tm09"])
        // M2
        l += zones([2], role: .cpuEfficiencyZone, label: "CPU efficiency zone", keys: ["Tp1h", "Tp1t", "Tp1p", "Tp1l"])
        l += zones([2], role: .cpuPerformanceZone, label: "CPU performance zone",
                   keys: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"])
        l += zones([2], role: .gpuZone, label: "GPU zone", keys: ["Tg0f", "Tg0j"])
        // M3
        l += zones([3], role: .cpuEfficiencyZone, label: "CPU efficiency zone", keys: ["Te05", "Te0L", "Te0P", "Te0S"])
        l += zones([3], role: .cpuPerformanceZone, label: "CPU performance zone",
                   keys: ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"])
        l += zones([3], role: .gpuZone, label: "GPU zone",
                   keys: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        // M4
        l += zones([4], role: .cpuEfficiencyZone, label: "CPU efficiency zone", keys: ["Te05", "Te0S", "Te09", "Te0H"])
        l += zones([4], role: .cpuPerformanceZone, label: "CPU performance zone",
                   keys: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"])
        l += zones([4], role: .gpuZone, label: "GPU zone", keys: ["Tg0G", "Tg0H"], tiers: [.base])
        l += zones([4], role: .gpuZone, label: "GPU zone", keys: ["Tg1U", "Tg1k"], tiers: [.pro, .max])
        l += zones([4], role: .gpuZone, label: "GPU zone (extra)", keys: ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        l += zones([4], role: .memoryZone, label: "Memory proximity", keys: ["Tm0p", "Tm1p", "Tm2p"])
        // M5 (núcleos "super" + "performance")
        l += zones([5], role: .cpuSuperZone, label: "CPU super zone", keys: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"])
        l += zones([5], role: .cpuPerformanceZone, label: "CPU performance zone",
                   keys: ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"])
        l += zones([5], role: .gpuZone, label: "GPU zone",
                   keys: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])
        // M6
        l += zones([6], role: .cpuSuperZone, label: "CPU super zone", keys: ["Tp0j", "Tp0g", "Tp09", "Tp07"])
        l += zones([6], role: .cpuPerformanceZone, label: "CPU performance zone",
                   keys: ["Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05"])
        l += zones([6], role: .cpuEfficiencyZone, label: "CPU efficiency zone",
                   keys: ["Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"])
        l += zones([6], role: .gpuZone, label: "GPU zone",
                   keys: ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"])

        // Sistema (todas as gerações Apple Silicon)
        l += [
            general("TaLP", "Airflow left", .temperature, .airflow),
            general("TaRF", "Airflow right", .temperature, .airflow),
            general("TH0x", "NAND", .temperature, .storage),
            general("TB1T", "Battery 1", .temperature, .battery),
            general("TB2T", "Battery 2", .temperature, .battery),
            general("TW0P", "Airport", .temperature, .wireless),
            // Tensão
            general("VD0R", "DC In", .voltage, .dcIn),
            general("VP0R", "12V rail", .voltage, .rail),
            general("Vp0C", "12V vcc", .voltage, .rail),
            // Corrente
            general("ID0R", "DC In", .current, .dcIn),
            general("IBAC", "Battery", .current, .battery),
            general("IU1R", "Thunderbolt left", .current, .thunderbolt),
            general("IU2R", "Thunderbolt right", .current, .thunderbolt),
            // Potência — domínios que SE SOBREPÕEM: nunca somar.
            general("PSTR", "System Total", .power, .systemTotal),
            general("PDTR", "DC In", .power, .dcIn),
            general("PPBR", "Battery", .power, .battery),
            general("PMTR", "Memory Total", .power, .memoryZone),
            general("PC3C", "RAM", .power, .memoryZone),
            general("PU1R", "Thunderbolt left", .power, .thunderbolt),
            general("PU2R", "Thunderbolt right", .power, .thunderbolt),
            general("PDBR", "Power Delivery Brightness", .power, .display),
            general("PBwo", "Display Backlight", .power, .display)
        ]
        return l
    }()

    /// Especificações aplicáveis ao chip detectado.
    public static func specs(for chip: ChipFamily?) -> [SMCSensorSpec] {
        all.filter { $0.applies(to: chip) }
    }

    /// Nomes legíveis de sensores HID (prefixo → papel). A chave HID real vem do campo "Product".
    public static func hidRole(forProductName name: String) -> (role: SensorRole, label: String)? {
        let table: [(prefix: String, role: SensorRole, label: String)] = [
            ("pACC MTR Temp Sensor", .cpuPerformanceZone, "CPU performance zone"),
            ("eACC MTR Temp Sensor", .cpuEfficiencyZone, "CPU efficiency zone"),
            ("GPU MTR Temp Sensor", .gpuZone, "GPU zone"),
            ("SOC MTR Temp Sensor", .socZone, "SOC zone"),
            ("ANE MTR Temp Sensor", .socZone, "Neural Engine zone"),
            ("ISP MTR Temp Sensor", .socZone, "Image signal processor zone"),
            ("PMGR SOC Die Temp Sensor", .socZone, "Power manager die"),
            ("PMU tdev", .socZone, "PMU device"),
            ("PMU tdie", .socZone, "PMU die"),
            ("gas gauge battery", .battery, "Battery"),
            ("NAND CH", .storage, "NAND")
        ]
        for e in table where name.hasPrefix(e.prefix) {
            let suffix = String(name.dropFirst(e.prefix.count)).trimmingCharacters(in: .whitespaces)
            return (e.role, suffix.isEmpty ? e.label : "\(e.label) \(suffix)")
        }
        return nil
    }
}
