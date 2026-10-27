import Foundation

/// Relatório textual para "Copiar diagnósticos": sem nomes de processos, caminhos pessoais ou identificadores.
public struct DiagnosticsInput {
    public var appVersion: String
    public var system: SystemProfile?
    public var memory: MemorySnapshot?
    public var states: [CollectorID: SourceState]
    public var stats: [CollectorID: CollectorStats]
    public var configuration: SamplingConfiguration
    public var wakeups: Int
    public var sensorCounts: [SensorKind: Int]
    public var fanControl: FanControlCapability
    public var selfFootprintBytes: UInt64?
    public var selfCPUPercent: Double?

    public init(appVersion: String, system: SystemProfile?, memory: MemorySnapshot?,
                states: [CollectorID: SourceState], stats: [CollectorID: CollectorStats],
                configuration: SamplingConfiguration, wakeups: Int, sensorCounts: [SensorKind: Int],
                fanControl: FanControlCapability, selfFootprintBytes: UInt64?, selfCPUPercent: Double?) {
        self.appVersion = appVersion; self.system = system; self.memory = memory; self.states = states
        self.stats = stats; self.configuration = configuration; self.wakeups = wakeups
        self.sensorCounts = sensorCounts; self.fanControl = fanControl
        self.selfFootprintBytes = selfFootprintBytes; self.selfCPUPercent = selfCPUPercent
    }
}

public enum DiagnosticsReport {
    public static func render(_ i: DiagnosticsInput, locale: Locale = Locale(identifier: "en_US")) -> String {
        var l: [String] = []
        l.append("OptiStats \(i.appVersion)")
        if let s = i.system {
            l.append("Chip: \(s.chip?.displayName ?? "desconhecido")  Modelo: \(s.modelIdentifier ?? "—")")
            l.append("macOS: \(s.osVersion)  Memória: \(ByteFormat.string(s.totalMemoryBytes, locale: locale))")
            l.append("CPUs lógicas: \(s.logicalCPUs)  físicas: \(s.physicalCPUs)  ventoinhas: \(s.fanCount.map(String.init) ?? "—")")
            if let t = s.topology {
                switch t.confidence {
                case .verified:
                    let parts = t.orderedClasses.map { "\($0.key)=\(t.classes[$0]?.count ?? 0)" }.joined(separator: " ")
                    l.append("Topologia: verificada (\(parts))")
                case .unverified(let r): l.append("Topologia: NÃO verificada — \(r)")
                }
            }
        }
        l.append("Perfil: \(i.configuration.profile.rawValue)  bateria=\(i.configuration.power.onBattery)  baixo consumo=\(i.configuration.power.lowPowerMode)  térmico=\(i.configuration.power.thermal)")
        l.append("Despertares do agendador: \(i.wakeups)")
        if let m = i.memory {
            l.append("Memória: usada(AM)=\(ByteFormat.string(m.usedBytes, locale: locale)) usada(alt/Stats)=\(ByteFormat.string(m.alternativeUsedBytes, locale: locale)) app=\(ByteFormat.string(m.appBytes, locale: locale)) wired=\(ByteFormat.string(m.wiredBytes, locale: locale)) comprimida=\(ByteFormat.string(m.compressedBytes, locale: locale)) cache=\(ByteFormat.string(m.cachedFilesBytes, locale: locale)) disponível=\(ByteFormat.string(m.availableBytes, locale: locale)) swap=\(m.swap.map { ByteFormat.string($0.usedBytes, locale: locale) } ?? "—") pressão=\(m.pressure.map { "\($0)" } ?? "—")")
        }
        l.append("Fontes:")
        for id in CollectorID.allCases {
            let st = i.states[id].map(describe) ?? "não iniciada"
            var line = "  \(id.rawValue): \(st)"
            if let s = i.stats[id] {
                let avg = s.runs > 0 ? s.totalRunSeconds / Double(s.runs) * 1000 : 0
                line += "  ativa=\(s.isActive) intervalo=\(s.interval.map { String($0) + "s" } ?? "—") leituras/min=\(s.readsLastMinute) média=\(String(format: "%.1f", avg))ms"
                if s.isStalled { line += "  TRAVADA" }
            }
            l.append(line)
        }
        l.append("Sensores: " + SensorKind.allCases.map { "\($0.rawValue)=\(i.sensorCounts[$0] ?? 0)" }.joined(separator: " "))
        l.append("Controle de ventoinha: \(describe(i.fanControl))")
        if let f = i.selfFootprintBytes { l.append("Consumo do próprio app: footprint=\(ByteFormat.string(f, locale: locale)) cpu=\(i.selfCPUPercent.map { String(format: "%.2f%%", $0) } ?? "—") (medição pontual)") }
        return Redactor.redact(l.joined(separator: "\n"))
    }

    private static func describe(_ s: SourceState) -> String {
        switch s {
        case .loading: return "carregando"
        case .available: return "disponível"
        case .stale: return "desatualizada"
        case .unsupported(let r): return "não suportada (\(r))"
        case .permissionDenied(let h): return "permissão negada (\(h))"
        case .failed(let m): return "erro (\(m))"
        case .paused: return "pausada"
        }
    }
    private static func describe(_ c: FanControlCapability) -> String {
        switch c {
        case .unavailable(let r): return "indisponível (\(r))"
        case .experimentalUnvalidated: return "experimental, não validado, bloqueado"
        case .validated: return "validado"
        }
    }
}
