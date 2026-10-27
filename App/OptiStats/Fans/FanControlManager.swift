import Cocoa
import OptiStatsCore

struct HelperInfo: Equatable {
    var state: HelperInstallState
    var build: Int?
    var supported: Bool?
    var error: String?
}

struct FanTestReport: Equatable {
    var passed: Bool
    var message: String
}

/// Orquestra o controle de ventoinhas no lado do app: estado manual, heartbeat, Smart Boost e teste de validação.
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

    func start() {
        guard let s = settings, s.smartBoostEnabled else { return }
        // Smart Boost só retoma se continuar permitido e validado; caso contrário volta a desligado.
        if s.manualAllowed, HelperInstaller.installedMatchesBundled() == true, case .validated = capability {
            startSmartBoost()
        } else { s.smartBoostEnabled = false }
    }

    /// Encerramento do app: restaura o automático e derruba a conexão (o helper também restaura ao ver a desconexão).
    func shutdown() {
        stopHeartbeat()
        fanToken?.cancel(); fanToken = nil
        _ = smartBoost.disable(reason: "encerrando o aplicativo")
        manualTargets.removeAll(); engaged = false
        if let client { client.restoreForShutdown() }
        else { _ = env.platform.fanActuator.apply(.restoreAutomatic(reason: "encerrando o aplicativo")) }
    }

    func systemWillSleep() {
        _ = smartBoost.systemWillSleep()
        if engaged { restoreInBackground(message: L("fan.msg.sleepRestored")) }
    }

    func thermalChanged(_ level: ThermalLevel) {
        guard level == .critical, engaged || settings?.smartBoostEnabled == true else { return }
        settings?.smartBoostEnabled = false
        stopSmartBoostState()
        restoreInBackground(message: L("fan.msg.thermalRestored"))
    }

    // MARK: Helper

    func helperInfo(_ done: @escaping (HelperInfo) -> Void) {
        io.async { [weak self] in
            let state = HelperInstaller.state()
            var info = HelperInfo(state: state)
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
        setBusy(true)
        io.async {
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
            }
        }
    }

    func uninstallHelper(_ done: @escaping (String?) -> Void) {
        setBusy(true)
        stopHeartbeat()
        stopSmartBoostState()
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
        guard let client, let s = settings, s.manualAllowed else { done(L("fan.err.notAllowed")); return }
        guard HelperInstaller.installedMatchesBundled() == true else { done(L("fan.helper.outdatedBanner")); return }
        guard case .validated = capability, !s.isUnsupportedForThisMac else { done(L("fan.err.needsValidation")); return }
        guard !s.smartBoostEnabled else { done(L("fan.err.smartBoostActive")); return }
        guard !busy else { done(L("fan.err.busy")); return }
        setBusy(true)
        io.async { [weak self] in
            let result = client.setTarget(fan: fan, rpm: rpm)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.manualTargets[fan] = rpm
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
        settings?.smartBoostEnabled = false
        stopSmartBoostState()
        restoreInBackground(message: nil, done)
    }

    private func restoreInBackground(message: String?, _ done: ((String?) -> Void)? = nil) {
        stopHeartbeat()
        manualTargets.removeAll(); engaged = false
        if message != nil { lastMessage = message }
        guard let client else { done?(nil); onChange?(); return }
        io.async { [weak self] in
            let result = client.restoreAutomatic()
            DispatchQueue.main.async {
                var err: String?
                if case .failure(let f) = result, f != .notInstalled {
                    err = HelperFanActuator.describe(f)
                    self?.lastMessage = err
                }
                done?(err)
                self?.onChange?()
            }
        }
    }

    private func setBusy(_ value: Bool) { busy = value; onChange?() }

    // MARK: Heartbeat (somente com controle manual ativo)

    private func startHeartbeat() {
        guard heartbeatTimer == nil, let client else { return }
        let t = DispatchSource.makeTimerSource(queue: io)
        let interval = FanHelperConstants.heartbeatInterval
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            if case .failure(let f) = client.heartbeat() {
                DispatchQueue.main.async { self?.heartbeatFailed(f) }
            }
        }
        t.resume()
        heartbeatTimer = t
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func heartbeatFailed(_ failure: FanClientFailure) {
        guard engaged else { return }
        // Sem heartbeat o helper restaura sozinho; reflete o estado e avisa.
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
        guard s.manualAllowed else { return L("fan.err.notAllowed") }
        guard HelperInstaller.installedMatchesBundled() == true else { return L("fan.helper.outdatedBanner") }
        guard case .validated = capability else { return L("fan.err.needsValidation") }
        guard manualTargets.isEmpty else { return L("fan.err.manualActive") }
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
        guard let s = settings, s.smartBoostEnabled, let fans = env.store.sensors?.fans, !fans.isEmpty,
              let ts = fans.map(\.timestamp).max(), ts > lastFanTimestamp else { return }
        lastFanTimestamp = ts   // um passo por leitura nova de ventoinhas (outros coletores também publicam sensores)
        var healthy = s.manualAllowed
        if case .unavailable = capability { healthy = false }
        let obs = FanObservation(timestamp: env.clock.now, fans: fans, actuatorHealthy: healthy,
                                 thermal: env.powerContext.thermal)
        let commands = smartBoost.step(obs)
        if case .faulted(let fault) = smartBoost.state {
            s.smartBoostEnabled = false
            stopSmartBoostState()
            lastMessage = L("fan.msg.smartBoostStopped", Self.describe(fault))
            if engaged || !commands.isEmpty { restoreInBackground(message: nil) }
            onChange?()
            return
        }
        guard !commands.isEmpty, let client else { return }
        io.async { [weak self] in
            for command in commands {
                let result = client.apply(command)
                var failed = false
                if case .restoreAutomatic = command {
                    DispatchQueue.main.async { self?.engaged = false; self?.manualTargets.removeAll(); self?.stopHeartbeat(); self?.onChange?() }
                } else if case .setTarget = command {
                    if result == .ok {
                        DispatchQueue.main.async { self?.engaged = true; self?.startHeartbeat(); self?.onChange?() }
                    } else { failed = true }
                }
                if failed {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.settings?.smartBoostEnabled = false
                        self.stopSmartBoostState()
                        self.lastMessage = L("fan.msg.smartBoostStopped", L("fan.err.commandRejected"))
                        self.restoreInBackground(message: nil)
                    }
                    return
                }
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

    // MARK: Teste de controle

    /// Ciclo curto e seguro: cada ventoinha sobe até ~+300 RPM (dentro de [min, max]) por 5 s, lê de volta e restaura.
    /// Só depois de passar o Mac fica `.validated`.
    func runControlTest(_ done: @escaping (FanTestReport) -> Void) {
        guard let client, let s = settings else { done(FanTestReport(passed: false, message: L("fan.err.notInstalled"))); return }
        guard s.manualAllowed else { done(FanTestReport(passed: false, message: L("fan.err.notAllowed"))); return }
        guard HelperInstaller.installedMatchesBundled() == true else {
            done(FanTestReport(passed: false, message: L("fan.helper.outdatedBanner"))); return
        }
        guard !engaged, !s.smartBoostEnabled, !busy else { done(FanTestReport(passed: false, message: L("fan.test.busy"))); return }
        setBusy(true)
        io.async { [weak self] in
            let report = Self.performTest(client: client)
            DispatchQueue.main.async {
                guard let self else { return }
                // Falha de teste também pode ser transitória (outro app, SMC ocupado, RPM já alto).
                // Só um teste aprovado autoriza escrita; uma falha não prova incompatibilidade do Mac.
                if report.passed { s.markValidated(true); s.markUnsupported(false) }
                else { s.markValidated(false) }
                self.setBusy(false)
                done(report)
            }
        }
    }

    private static func performTest(client: HelperFanActuator) -> FanTestReport {
        func fail(_ text: String) -> FanTestReport { FanTestReport(passed: false, message: text) }
        let fans: [FanHelperFanState]
        switch client.readFans() {
        case .failure(let f): return fail(HelperFanActuator.describe(f))
        case .success(let list): fans = list
        }
        var plans: [(index: Int, start: Double, target: Double)] = []
        for fan in fans {
            guard let rpm = fan.rpm, let target = FanControlTestPlan.target(current: rpm, min: fan.minRPM, max: fan.maxRPM) else { continue }
            plans.append((fan.index, rpm, target))
        }
        guard !plans.isEmpty else { return fail(L("fan.test.inconclusive")) }

        // A partir daqui, SEMPRE restaurar o automático ao sair.
        var restored = false
        func restore() -> Bool {
            if restored { return true }
            var ok = false
            for _ in 0..<2 { if case .success = client.restoreAutomatic() { ok = true; break } }
            restored = ok
            return ok
        }
        defer { _ = restore() }

        for plan in plans {
            if case .failure(let f) = client.setTarget(fan: plan.index, rpm: plan.target) {
                _ = restore()
                return fail(L("fan.test.writeFailed", HelperFanActuator.describe(f)))
            }
        }
        // Segura ~5 s mantendo o heartbeat.
        Thread.sleep(forTimeInterval: FanControlTestPlan.holdSeconds / 2)
        _ = client.heartbeat()
        Thread.sleep(forTimeInterval: FanControlTestPlan.holdSeconds / 2)

        var lines: [String] = []
        var allPassed = true
        if case .success(let after) = client.readFans() {
            for plan in plans {
                let observed = after.first(where: { $0.index == plan.index })?.rpm
                let ok = FanControlTestPlan.passed(start: plan.start, target: plan.target, observed: observed)
                if !ok { allPassed = false }
                lines.append(L("fan.test.line", plan.index + 1, Int(plan.start), Int(plan.target),
                               observed.map { String(Int($0)) } ?? "—"))
            }
        } else {
            allPassed = false
            lines.append(L("fan.test.readFailed"))
        }
        guard restore() else { return fail(L("fan.test.restoreFailed")) }
        let summary = allPassed ? L("fan.test.passed") : L("fan.test.failed")
        return FanTestReport(passed: allPassed, message: summary + "\n" + lines.joined(separator: "\n"))
    }
}
