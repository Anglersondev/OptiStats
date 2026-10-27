import Foundation

/// Tabela de intervalos de partida (§5B). São PONTOS DE PARTIDA para benchmark, não valores comprovados.
public struct SamplingPolicy {
    public struct Pair { public var bar: TimeInterval?; public var popover: TimeInterval }

    public init() {}

    public static func table(_ profile: SamplingProfile, _ id: CollectorID) -> Pair {
        func p(_ bar: TimeInterval?, _ pop: TimeInterval) -> Pair { Pair(bar: bar, popover: pop) }
        // O perfil .custom parte do equilibrado e aplica sobreposições por módulo.
        let base: SamplingProfile = profile == .custom ? .balanced : profile
        switch (base, id) {
        case (.economy, .cpu), (.economy, .gpu): return p(5, 2)
        case (.balanced, .cpu), (.balanced, .gpu): return p(3, 1)
        case (.realtime, .cpu), (.realtime, .gpu): return p(2, 1)

        case (.economy, .memory): return p(10, 3)
        case (.balanced, .memory): return p(5, 2)
        case (.realtime, .memory): return p(2, 1)

        case (.economy, .temperatures): return p(30, 5)
        case (.balanced, .temperatures): return p(20, 3)
        case (.realtime, .temperatures): return p(10, 2)

        case (.economy, .fans): return p(10, 3)
        case (.balanced, .fans): return p(5, 2)
        case (.realtime, .fans): return p(3, 2)

        case (.economy, .power): return p(30, 10)
        case (.balanced, .power): return p(15, 3)
        case (.realtime, .power): return p(10, 2)

        case (.economy, .processes): return p(nil, 10)
        case (.balanced, .processes): return p(nil, 5)
        case (.realtime, .processes): return p(nil, 3)

        case (.economy, .sensorList): return p(nil, 5)
        case (.balanced, .sensorList): return p(nil, 3)
        case (.realtime, .sensorList): return p(nil, 2)

        case (.economy, .disk), (.economy, .network): return p(10, 3)
        case (.balanced, .disk), (.balanced, .network): return p(5, 2)
        case (.realtime, .disk), (.realtime, .network): return p(2, 1)

        case (.economy, .battery): return p(30, 10)
        case (.balanced, .battery): return p(20, 5)
        case (.realtime, .battery): return p(10, 2)

        case (.custom, _): return p(nil, 5) // inalcançável (base nunca é .custom)
        }
    }

    /// Intervalo efetivo ou nil (= não agendar; leitura só sob demanda ou suspensa).
    public func interval(for id: CollectorID, visibility: Visibility, config: SamplingConfiguration) -> TimeInterval? {
        guard visibility != .hidden else { return nil }
        let pair = Self.table(config.profile, id)
        var base: TimeInterval?
        let override = config.profile == .custom ? config.custom[id] : nil
        switch visibility {
        case .popover:
            if case .seconds(let s)? = override?.visible { base = TimeInterval(AllowedIntervals.coerce(s, for: id)) }
            else { base = pair.popover }
        case .bar:
            if case .seconds(let s)? = override?.background { base = TimeInterval(AllowedIntervals.coerce(s, for: id)) }
            else { base = pair.bar }
        case .hidden: base = nil
        }
        guard let b = base else { return nil }
        return Self.scaled(b, id: id, visibility: visibility, power: config.power)
    }

    /// Política conservadora sob Modo de Baixo Consumo e estado térmico.
    public static func scaled(_ interval: TimeInterval, id: CollectorID, visibility: Visibility,
                              power: PowerContext) -> TimeInterval? {
        var factor = 1.0
        if power.lowPowerMode { factor *= id.isEssential ? 1.5 : 2.0 }
        switch power.thermal {
        case .nominal, .fair: break
        case .serious: factor *= id.isEssential ? 1.5 : 2.0
        case .critical:
            // Opcionais só com painel aberto; essenciais bem mais lentos.
            if !id.isEssential && visibility != .popover { return nil }
            factor *= id.isEssential ? 2.0 : 3.0
        }
        return min(120, interval * factor)
    }
}
