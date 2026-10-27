import Foundation

public struct SmartBoostConfig: Equatable {
    /// RPM mínimo (acima de zero) para considerar que o macOS ligou as ventoinhas.
    public var engageRPM: Double = 1000
    /// Amostras consecutivas acima de `engageRPM` (em modo automático) para entrar.
    public var engageSamples = 3
    /// Amostras abaixo de `releaseRPM` (durante a sondagem) para sair definitivamente.
    public var releaseRPM: Double = 900
    public var releaseSamples = 3
    /// Fração do RPM máximo reportado usada como alvo (1.0 = máximo reportado pelo hardware).
    public var boostFraction = 1.0
    public var maxBoostDuration: TimeInterval = 600
    public var cooldown: TimeInterval = 180
    /// Intervalo mínimo entre mudanças de modo (restaurar para automático nunca é bloqueado).
    public var minChangeInterval: TimeInterval = 20
    /// De tempos em tempos, volta ao automático para observar o que o macOS faria.
    public var probeEvery: TimeInterval = 90
    public var probeDuration: TimeInterval = 12
    /// Tempo para o RPM responder a um comando antes de contar falha de verificação.
    public var verifyDelay: TimeInterval = 4
    public var verifyFailuresToFault = 2
    public var heartbeatTTL: TimeInterval = 15
    /// Sem observação nova por este tempo → restaurar.
    public var staleObservation: TimeInterval = 15
    public init() {}
}

public struct FanObservation: Equatable {
    public var timestamp: TimeInterval
    public var fans: [FanReading]
    public var actuatorHealthy: Bool
    public var thermal: ThermalLevel
    public init(timestamp: TimeInterval, fans: [FanReading], actuatorHealthy: Bool = true, thermal: ThermalLevel = .nominal) {
        self.timestamp = timestamp; self.fans = fans; self.actuatorHealthy = actuatorHealthy; self.thermal = thermal
    }
}

public enum SmartBoostFault: Equatable {
    case noFans
    case missingLimits
    case conflictingController
    case rpmDidNotRespond
    case actuatorUnhealthy
    case staleObservation
    case commandRejected(String)
}

public enum SmartBoostState: Equatable {
    case disabled
    case monitoring
    case boosting(since: TimeInterval)
    case probing(since: TimeInterval)
    case cooldown(until: TimeInterval)
    case faulted(SmartBoostFault)
}

/// Máquina de estados do Smart Boost. PURA: recebe observações e devolve comandos; não toca em hardware.
/// Desativada por padrão. Qualquer falha ou dúvida devolve o controle ao macOS (`restoreAutomatic`).
public final class SmartBoostController {
    public private(set) var state: SmartBoostState = .disabled
    public let config: SmartBoostConfig

    private var consecutiveHigh = 0
    private var consecutiveLow = 0
    private var lastChange: TimeInterval = -.infinity
    private var boostStart: TimeInterval?
    private var lastProbe: TimeInterval = 0
    private var commandSentAt: TimeInterval?
    private var rpmAtCommand: Double = 0
    private var verifyFailures = 0
    private var lastObservation: TimeInterval?
    private var appleFloorRPM: Double = 0

    public init(config: SmartBoostConfig = SmartBoostConfig()) { self.config = config }

    // MARK: Entradas externas

    public func enable() { if state == .disabled { state = .monitoring; reset() } }

    /// Desligar, sair do app, dormir etc.: sempre restaura o automático.
    public func disable(reason: String = "desativado") -> [FanCommand] {
        let wasActive: Bool
        switch state { case .boosting, .probing: wasActive = true; default: wasActive = false }
        state = .disabled; reset()
        return wasActive ? [.restoreAutomatic(reason: reason)] : []
    }

    public func systemWillSleep() -> [FanCommand] { fault(.staleObservation, restore: "repouso do sistema", markFault: false) }

    /// Recupera de uma falha somente por ação explícita do usuário.
    public func acknowledgeFault() { if case .faulted = state { state = .monitoring; reset() } }

    private func reset() {
        consecutiveHigh = 0; consecutiveLow = 0; verifyFailures = 0; commandSentAt = nil; lastObservation = nil
        boostStart = nil
    }

    private func fault(_ f: SmartBoostFault, restore reason: String, markFault: Bool = true) -> [FanCommand] {
        let wasActive: Bool
        switch state { case .boosting, .probing: wasActive = true; default: wasActive = false }
        state = markFault ? .faulted(f) : .monitoring
        reset()
        return wasActive || markFault ? [.restoreAutomatic(reason: reason)] : []
    }

    // MARK: Passo

    public func step(_ obs: FanObservation) -> [FanCommand] {
        let now = obs.timestamp
        switch state {
        case .disabled, .faulted: return []
        default: break
        }
        guard !obs.fans.isEmpty else { return fault(.noFans, restore: "sem ventoinhas detectadas") }
        guard obs.actuatorHealthy else { return fault(.actuatorUnhealthy, restore: "atuador indisponível") }
        if let last = lastObservation, now - last > config.staleObservation {
            return fault(.staleObservation, restore: "leituras antigas")
        }
        lastObservation = now

        let rpms = obs.fans.compactMap(\.rpm)
        let anyManual = obs.fans.contains { $0.mode == .manual }

        switch state {
        case .monitoring:
            // Outro controlador já está forçando: não escrever nada.
            if anyManual { state = .faulted(.conflictingController); return [] }
            guard obs.fans.allSatisfy({ $0.minRPM != nil && $0.maxRPM != nil }) else {
                state = .faulted(.missingLimits); return []
            }
            if obs.thermal == .critical { return [] }
            let engaged = !rpms.isEmpty && rpms.allSatisfy { $0 >= config.engageRPM }
            consecutiveHigh = engaged ? consecutiveHigh + 1 : 0
            if consecutiveHigh >= config.engageSamples, now - lastChange >= config.minChangeInterval {
                return beginBoost(obs)
            }
            return []

        case .cooldown(let until):
            if anyManual { state = .faulted(.conflictingController); return [] }
            if now >= until { state = .monitoring; consecutiveHigh = 0 }
            return []

        case .boosting(let since):
            // Em boost esperamos modo manual (fomos nós). Se voltou a automático, outro agente mexeu.
            if obs.fans.contains(where: { $0.mode == .automatic }) && (commandSentAt.map { now - $0 > config.verifyDelay } ?? true) {
                return fault(.conflictingController, restore: "modo alterado externamente")
            }
            if obs.thermal == .critical { return endBoost(now, reason: "estado térmico crítico", cooldown: true) }
            if now - since >= config.maxBoostDuration { return endBoost(now, reason: "duração máxima do boost", cooldown: true) }
            if let sent = commandSentAt, now - sent >= config.verifyDelay {
                let target = (obs.fans.compactMap(\.maxRPM).min() ?? 0) * config.boostFraction
                let responding = rpms.contains { $0 >= rpmAtCommand + 0.5 * max(0, target - rpmAtCommand) }
                if responding { verifyFailures = 0; commandSentAt = nil }
                else {
                    verifyFailures += 1; commandSentAt = now
                    if verifyFailures >= config.verifyFailuresToFault {
                        return fault(.rpmDidNotRespond, restore: "RPM não respondeu ao comando")
                    }
                }
            }
            if now - lastProbe >= config.probeEvery, now - lastChange >= config.minChangeInterval {
                state = .probing(since: now); lastChange = now; consecutiveLow = 0
                return [.restoreAutomatic(reason: "sondagem do comportamento do macOS")]
            }
            return [.heartbeat(ttl: config.heartbeatTTL)]

        case .probing(let since):
            if now - since < config.probeDuration { return [] }   // aguardar o macOS assumir
            let lowEnough = !rpms.isEmpty && rpms.allSatisfy { $0 < config.releaseRPM }
            consecutiveLow = lowEnough ? consecutiveLow + 1 : 0
            if lowEnough && consecutiveLow >= config.releaseSamples {
                state = .cooldown(until: now + config.cooldown); lastChange = now
                return []
            }
            if now - (boostStart ?? now) >= config.maxBoostDuration {
                state = .cooldown(until: now + config.cooldown); lastChange = now; boostStart = nil
                return []
            }
            if !lowEnough {
                lastProbe = now
                return beginBoost(obs, resume: true)
            }
            return []

        case .disabled, .faulted: return []
        }
    }

    private func beginBoost(_ obs: FanObservation, resume: Bool = false) -> [FanCommand] {
        let now = obs.timestamp
        guard let hi = obs.fans.compactMap(\.maxRPM).min(), hi > 0 else { return [] }
        let floor = obs.fans.compactMap(\.rpm).max() ?? 0
        appleFloorRPM = resume ? max(appleFloorRPM, floor) : floor
        // Nunca abaixo do que o macOS já estava fazendo (piso gerenciado pelo sistema).
        let target = max(hi * config.boostFraction, appleFloorRPM)
        if !resume || boostStart == nil { boostStart = now }
        state = .boosting(since: boostStart ?? now)
        lastChange = now; lastProbe = now
        commandSentAt = now; rpmAtCommand = floor; verifyFailures = 0
        return [.setTarget(rpm: min(target, hi)), .heartbeat(ttl: config.heartbeatTTL)]
    }

    private func endBoost(_ now: TimeInterval, reason: String, cooldown: Bool) -> [FanCommand] {
        state = cooldown ? .cooldown(until: now + config.cooldown) : .monitoring
        lastChange = now; reset()
        return [.restoreAutomatic(reason: reason)]
    }
}
