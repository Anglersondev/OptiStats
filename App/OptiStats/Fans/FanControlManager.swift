import Cocoa
import OptiStatsCore

struct HelperInfo: Equatable {
    var state: HelperInstallState
    var build: Int?
    var supported: Bool?
    var error: String?
    var matchesBundled: Bool?
}

/// Orquestra o controle de ventoinhas no lado do app: estado manual persistente, heartbeat e Smart Boost.
/// Regras de segurança:
/// - nada é escrito sem `settings.manualAllowed` (desligado por padrão);
/// - qualquer falha, suspensão do sistema, estado térmico crítico, desinstalação ou saída do app devolve o automático;
/// - NÃO há timer permanente: o único timer (heartbeat) existe somente enquanto alguma ventoinha está em manual.
/// Estado mutável só na main; E/S com o helper na fila serial `io`.
final class FanControlManager {
    private unowned let env: AppEnvironment
    private let client: HelperFanActuator?
    private let io = DispatchQueue(label: "app.optistats.fan.io", qos: .userInitiated)

    // Estado (main)
    private(set) var manualTargets: [Int: Double] = [:]
    private(set) var busy = false
    private(set) var lastMessage: String?
    private var engaged = false
    private var heartbeatTimer: DispatchSourceTimer?
    private let smartBoost = SmartBoostController()
    private var fanToken: SubscriptionToken?
    private var lastFanTimestamp: TimeInterval = -.infinity
    /// Invalida respostas de comandos anteriores a uma restauração ou encerramento.
    private var controlGeneration = 0
    private var resumeAfterPendingCommand = false
    private var isSleeping = false
    private var heartbeatInFlight = false

    /// Chamado na main quando algo relevante para a interface mudou.
    var onChange: (() -> Void)?

    var settings: FanControlSettings? { client?.settings }
    var smartBoostState: SmartBoostState { smartBoost.state }
    var isEngaged: Bool { engaged }
    var capability: FanControlCapability { env.platform.fanActuator.capability }

    init(env: AppEnvironment) {
        self.env = env
        self.client = env.platform.fanActuator as? HelperFanActuator
    }

    // MARK: Ciclo de vida

    func start() { resumeSavedControl() }

    /// One asynchronous pass on launch/wake. Never waits for a heavy workload to start the fans.
    func resumeSavedControl() {
        guard !isSleeping else { return }
        if busy { resumeAfterPendingCommand = true; return }
        guard !engaged, let s = settings, s.manualAllowed,
              env.powerContext.thermal != .critical else { return }
        if s.smartBoostEnabled {
            guard HelperInstaller.installedMatchesBundled() == true else {
                lastMessage = L("fan.helper.outdatedBanner")
                return
            }
            startSmartBoost()
            return
        }
        let saved = s.savedTargets
        guard !saved.isEmpty, let client else { return }
        let generation = controlGeneration
        setBusy(true)
        io.async { [weak self] in
            var applied: [Int: Double] = [:]
            var failure: String?
            if HelperInstaller.installedMatchesBundled() != true {
                failure = L("fan.helper.outdatedBanner")
            } else {
                switch client.readFans() {
                case .failure(let f): failure = HelperFanActuator.describe(f)
                case .success(let fans):
                    for index in saved.keys.sorted() {
                        guard let fan = fans.first(where: { $0.index == index }),
                              let rpm = saved[index]?.resolve(min: fan.minRPM, max: fan.maxRPM) else {
                            failure = L("fan.err.limitsUnknown"); break
                        }
                        if case .failure(let f) = client.setTarget(fan: index, rpm: rpm) {
                            failure = HelperFanActuator.describe(f); break
                        }
                        applied[index] = rpm
                    }
                }
            }
            if failure != nil { _ = client.restoreAutomatic(); applied.removeAll() }
            DispatchQueue.main.async {
                guard let self, generation == self.controlGeneration else { return }
                self.manualTargets = applied
                self.engaged = !applied.isEmpty
                self.lastMessage = failure
                if self.engaged { self.startHeartbeat() }
                self.setBusy(false)
            }
        }
    }

    /// Encerramento do app: restaura o automático e derruba a conexão (o helper também restaura ao ver a desconexão).
    func shutdown() {
        resumeAfterPendingCommand = false
        controlGeneration += 1
        stopHeartbeat()
        fanToken?.cancel(); fanToken = nil
        _ = smartBoost.disable(reason: "encerrando o aplicativo")
        manualTargets.removeAll(); engaged = false
        if let client { client.emergencyDisconnect() }
        else { _ = env.platform.fanActuator.apply(.restoreAutomatic(reason: "encerrando o aplicativo")) }
    }

    func systemWillSleep() {
        isSleeping = true
        resumeAfterPendingCommand = false
        stopSmartBoostState()
        if engaged || busy || settings?.smartBoostEnabled == true {
            client?.emergencyDisconnect()
            restoreInBackground(message: L("fan.msg.sleepRestored"))
        }
    }

    func systemDidWake() {
        isSleeping = false
        resumeSavedControl()
    }

    func thermalChanged(_ level: ThermalLevel) {
        guard level == .critical, engaged || busy || settings?.smartBoostEnabled == true else { return }
        settings?.smartBoostEnabled = false
        stopSmartBoostState()
        restoreInBackground(message: L("fan.msg.thermalRestored"))
    }

    // MARK: Helper

    func helperInfo(_ done: @escaping (HelperInfo) -> Void) {
        io.async { [weak self] in
            let state = HelperInstaller.state()
            var info = HelperInfo(state: state)
            info.matchesBundled = HelperInstaller.installedMatchesBundled()
            if state == .running, let client = self?.client {
                switch client.hello() {
                case .success(let h): info.build = h.build; info.supported = h.supported
                case .failure(let f): info.error = HelperFanActuator.describe(f)
                }
            }
            DispatchQueue.main.async { done(info) }
        }
    }

    /// `done(nil)` em sucesso; senão, texto do erro para exibir.
    func installHelper(_ done: @escaping (String?) -> Void) {
        controlGeneration += 1
        stopHeartbeat()
        stopSmartBoostState()
        manualTargets.removeAll(); engaged = false
        setBusy(true)
        io.async { [weak self] in
            if let client = self?.client {
                _ = client.restoreAutomatic()
                client.disconnect()
            }
            var message: String?
            if let error = HelperInstaller.install() {
                message = Self.text(for: error)
            } else {
                // O daemon sobe de forma assíncrona: aguardar o socket (até ~8 s, em fatias; sem timer).
                var waited = 0
                while HelperInstaller.state() != .running && waited < 32 { usleep(250_000); waited += 1 }
                if HelperInstaller.state() != .running { message = L("fan.install.notRunning") }
            }
            DispatchQueue.main.async { [weak self] in
                self?.setBusy(false)
                done(message)
                if message == nil { self?.resumeSavedControl() }
            }
        }
    }

    func uninstallHelper(_ done: @escaping (String?) -> Void) {
        controlGeneration += 1
        setBusy(true)
        stopHeartbeat()
        stopSmartBoostState()
        settings?.savedTargets = [:]
        settings?.smartBoostEnabled = false
        manualTargets.removeAll(); engaged = false
        io.async { [weak self] in
            // Antes de remover: restaurar o automático (o bootout também faz o helper restaurar via SIGTERM).
            if HelperInstaller.state() == .running { _ = self?.client?.restoreAutomatic() }
            self?.client?.disconnect()
            let error = HelperInstaller.uninstall()
            DispatchQueue.main.async {
                self?.setBusy(false)
                done(error.map { Self.text(for: $0) })
            }
        }
    }

    private static func text(for error: HelperInstaller.HelperError) -> String {
        switch error {
        case .missingBinary: return L("fan.install.missingBinary")
        case .cancelled: return L("fan.install.cancelled")
        case .failed(let detail): return L("fan.install.failed", detail)
        }
    }

    // MARK: Controle manual

    func setManual(fan: Int, rpm: Double, _ done: @escaping (String?) -> Void) {
        guard env.powerContext.thermal != .critical else { done(L("fan.msg.thermalRestored")); return }
        guard let client, let s = settings, s.manualAllowed else { done(L("fan.err.notAllowed")); return }
        guard HelperInstaller.installedMatchesBundled() == true else { done(L("fan.helper.outdatedBanner")); return }
        guard case .available = capability else { done(L("fan.err.notInstalled")); return }
        guard !s.smartBoostEnabled else { done(L("fan.err.smartBoostActive")); return }
        guard !busy else { done(L("fan.err.busy")); return }
        let generation = controlGeneration
        setBusy(true)
        io.async { [weak self] in
            let result = client.setTarget(fan: fan, rpm: rpm)
            // Recusas anteriores à escrita também precisam devolver eventuais ventoinhas já controladas.
            if case .failure = result { _ = client.restoreAutomatic() }
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.controlGeneration else { done(nil); return }
                switch result {
                case .success:
                    self.manualTargets[fan] = rpm
                    let maximum = self.env.store.sensors?.fans.first(where: { $0.index == fan })?.maxRPM
                    s.savedTargets[fan] = maximum.map { abs($0.rounded(.down) - rpm) <= 1 } == true ? .maximum : .rpm(rpm)
                    self.engaged = true
                    self.startHeartbeat()
                    done(nil)
                case .failure(let f):
                    // O helper já restaurou o automático; refletir isso aqui.
                    self.manualTargets.removeAll(); self.engaged = false
                    self.stopHeartbeat()
                    done(HelperFanActuator.describe(f))
                }
                self.setBusy(false)
            }
        }
    }

    /// Botão "Restaurar automático": restaura TUDO e desliga o Smart Boost.
    func restoreAutomatic(_ done: ((String?) -> Void)? = nil) {
        resumeAfterPendingCommand = false
        settings?.smartBoostEnabled = false
        settings?.savedTargets = [:]
        stopSmartBoostState()
        restoreInBackground(message: nil, done)
    }

    private func restoreInBackground(message: String?, _ done: ((String?) -> Void)? = nil) {
        controlGeneration += 1
        let generation = controlGeneration
        stopHeartbeat()
        manualTargets.removeAll(); engaged = false
        if message != nil { lastMessage = message }
        guard let client else { done?(nil); onChange?(); return }
        setBusy(true)
        io.async { [weak self] in
            let result = client.restoreAutomatic()
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.controlGeneration else { done?(nil); return }
                self.manualTargets.removeAll(); self.engaged = false
                self.stopHeartbeat()
                var err: String?
                if case .failure(let f) = result, f != .notInstalled {
                    err = HelperFanActuator.describe(f)
                    self.lastMessage = err
                }
                self.setBusy(false)
                done?(err)
            }
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value; onChange?()
        if !value, resumeAfterPendingCommand {
            resumeAfterPendingCommand = false
            DispatchQueue.main.async { [weak self] in self?.resumeSavedControl() }
        }
    }

    // MARK: Heartbeat (somente com controle manual ativo)

    private func startHeartbeat() {
        guard heartbeatTimer == nil, let client else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        let interval = FanHelperConstants.heartbeatInterval
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.sendHeartbeat(using: client) }
        t.resume()
        heartbeatTimer = t
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private var sensorTimeout: TimeInterval {
        let interval = env.coordinator.effectiveInterval(for: .fans) ?? 0
        return max(smartBoost.config.staleObservation, 2 * interval + 1)
    }

    private func sendHeartbeat(using client: HelperFanActuator) {
        guard engaged, !busy, !heartbeatInFlight else { return }
        if settings?.smartBoostEnabled == true, env.clock.now - lastFanTimestamp > sensorTimeout {
            settings?.smartBoostEnabled = false
            stopSmartBoostState()
            restoreInBackground(message: L("fan.msg.smartBoostStopped", L("fan.fault.stale")))
            return
        }
        let generation = controlGeneration
        heartbeatInFlight = true
        io.async { [weak self] in
            let result = client.heartbeat()
            DispatchQueue.main.async {
                guard let self else { return }
                self.heartbeatInFlight = false
                guard generation == self.controlGeneration else { return }
                if case .failure(let error) = result { self.heartbeatFailed(error) }
            }
        }
    }

    private func heartbeatFailed(_ failure: FanClientFailure) {
        guard engaged else { return }
        // A desconexão encerra a posse da ventoinha mesmo quando o heartbeat falha no transporte.
        client?.emergencyDisconnect()
        stopHeartbeat()
        manualTargets.removeAll(); engaged = false
        settings?.smartBoostEnabled = false
        stopSmartBoostState()
        lastMessage = L("fan.msg.connectionLost", HelperFanActuator.describe(failure))
        onChange?()
    }

    // MARK: Smart Boost

    /// Devolve nil se ligou/desligou, ou o motivo da recusa.
    @discardableResult
    func setSmartBoost(_ on: Bool) -> String? {
        guard let s = settings else { return L("fan.err.notInstalled") }
        if !on {
            s.smartBoostEnabled = false
            stopSmartBoostState()
            restoreInBackground(message: nil)
            return nil
        }
        guard !busy else { return L("fan.err.busy") }
        guard env.powerContext.thermal != .critical else { return L("fan.msg.thermalRestored") }
        guard s.manualAllowed else { return L("fan.err.notAllowed") }
        guard HelperInstaller.installedMatchesBundled() == true else { return L("fan.helper.outdatedBanner") }
        guard case .available = capability else { return L("fan.err.notInstalled") }
        guard manualTargets.isEmpty else { return L("fan.err.manualActive") }
        s.savedTargets = [:]
        s.smartBoostEnabled = true
        startSmartBoost()
        onChange?()
        return nil
    }

    private func startSmartBoost() {
        smartBoost.enable()
        lastFanTimestamp = -.infinity
        env.setDemand(consumer: "fan.smartboost", collectors: [.fans], visibility: .bar)
        fanToken?.cancel()
        fanToken = env.store.subscribe(.sensors, queue: .main) { [weak self] in self?.smartBoostTick() }
    }

    /// Para de observar e zera a máquina de estados (não envia comandos; quem chama restaura se necessário).
    private func stopSmartBoostState() {
        fanToken?.cancel(); fanToken = nil
        env.setDemand(consumer: "fan.smartboost", collectors: [.fans], visibility: nil)
        _ = smartBoost.disable(reason: "desativado")
    }

    private func smartBoostTick() {
        guard !busy, let s = settings, s.smartBoostEnabled, let snapshot = env.store.sensors else { return }
        let fans = snapshot.fans
        if let measuredAt = fans.map(\.timestamp).max() {
            guard measuredAt > lastFanTimestamp else { return }
            lastFanTimestamp = measuredAt
        }
        var healthy = s.manualAllowed
        if case .unavailable = capability { healthy = false }
        let obs = FanObservation(timestamp: env.clock.now, fans: fans, actuatorHealthy: healthy,
                                 thermal: env.powerContext.thermal)
        let commands = smartBoost.step(obs, staleAfter: sensorTimeout).filter { command in
            // The dedicated timer is the only source of socket heartbeats.
            if case .heartbeat = command { return false }
            return true
        }
        if case .faulted(let fault) = smartBoost.state {
            s.smartBoostEnabled = false
            stopSmartBoostState()
            lastMessage = L("fan.msg.smartBoostStopped", Self.describe(fault))
            if engaged || !commands.isEmpty { restoreInBackground(message: nil) }
            onChange?()
            return
        }
        guard let command = commands.first, let client else { return }
        let generation = controlGeneration
        setBusy(true)
        io.async { [weak self] in
            let result = client.apply(command)
            DispatchQueue.main.async {
                guard let self, generation == self.controlGeneration else { return }
                guard result == .ok else {
                    self.settings?.smartBoostEnabled = false
                    self.stopSmartBoostState()
                    self.restoreInBackground(message: L("fan.msg.smartBoostStopped", L("fan.err.commandRejected")))
                    return
                }
                switch command {
                case .restoreAutomatic:
                    self.engaged = false
                    self.manualTargets.removeAll()
                    self.stopHeartbeat()
                case .setTarget:
                    self.engaged = true
                    self.startHeartbeat()
                case .heartbeat: break
                }
                self.setBusy(false)
            }
        }
    }

    private static func describe(_ fault: SmartBoostFault) -> String {
        switch fault {
        case .noFans: return L("fan.fault.noFans")
        case .missingLimits: return L("fan.fault.missingLimits")
        case .conflictingController: return L("fan.fault.conflict")
        case .rpmDidNotRespond: return L("fan.fault.noResponse")
        case .actuatorUnhealthy: return L("fan.fault.actuator")
        case .staleObservation: return L("fan.fault.stale")
        case .commandRejected(let m): return m
        }
    }

}
