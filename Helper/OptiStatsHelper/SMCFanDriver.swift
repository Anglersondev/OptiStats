import Foundation
import OptiStatsCore

/// Sequência de controle de ventoinhas no SMC. Adaptada de `SMC/smc.swift` do Stats (exelban/stats, MIT):
/// `fanModeKey`, `unlockFanControl`, `retryModeWrite`, `setFanSpeed`, `setFanMode(.automatic)` e `resetFanControl`.
/// Diferenças deliberadas: toda escrita é conferida por leitura de volta; qualquer falha restaura o automático;
/// limites [min, max] vêm do SMC e são validados por `FanRPMPolicy` (rejeita, não ajusta); somente Apple Silicon.
///
/// Chaves usadas (todas presentes no código do Stats): FNum, F{i}Ac, F{i}Mn, F{i}Mx, F{i}Tg, F{i}Md ou F{i}md, Ftst.
final class SMCFanDriver {
    struct Failure: Error { let code: FanHelperErrorCode; let message: String }

    private let smc = SMCConnection()
    private let shouldAbort: () -> Bool
    private var modeKeyIsLower: Bool?
    /// Ventoinhas que ESTE helper colocou em modo manual.
    private(set) var manualFans = Set<Int>()
    private var ftstEngaged = false
    /// Verdadeiro quando uma restauração falhou e precisa ser repetida.
    private(set) var restorePending = false

    var isManualActive: Bool { !manualFans.isEmpty || ftstEngaged || restorePending }

    init(shouldAbort: @escaping () -> Bool) { self.shouldAbort = shouldAbort }

    /// O caminho de escrita implementado vale somente para Apple Silicon (o Stats usa outro caminho em Intel, não adotado aqui).
    var isSupportedArchitecture: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    var isSMCAvailable: Bool { smc.open() }

    // MARK: Leitura

    func fanCount() -> Int? {
        guard let n = smc.read(FanSMCKeys.countKey)?.number, n >= 1, n <= Double(FanSMCKeys.maxFans) else { return nil }
        return Int(n)
    }

    private func modeKey(_ i: Int) -> String {
        if modeKeyIsLower == nil {
            // Como no Stats: se "F0md" existe, é a variante em minúsculas (Apple Silicon recente).
            modeKeyIsLower = smc.read(FanSMCKeys.modeLower(0)) != nil
        }
        return modeKeyIsLower! ? FanSMCKeys.modeLower(i) : FanSMCKeys.modeUpper(i)
    }

    private func rpmValue(_ key: String) -> Double? {
        guard let v = smc.read(key)?.number, v.isFinite, v >= 0, v <= FanRPMPolicy.sanityCeiling else { return nil }
        return v
    }

    func readFans() -> [FanHelperFanState] {
        guard let n = fanCount() else { return [] }
        return (0..<n).map { i in
            let mode = smc.read(modeKey(i))
            return FanHelperFanState(index: i, rpm: rpmValue(FanSMCKeys.actual(i)),
                                     minRPM: rpmValue(FanSMCKeys.minimum(i)), maxRPM: rpmValue(FanSMCKeys.maximum(i)),
                                     manual: mode.map { $0.bytes.first == 1 })
        }
    }

    // MARK: Escrita (com confirmação)

    func setTarget(fan: Int, rpm: Double) -> Result<Void, Failure> {
        guard isSupportedArchitecture else { return .failure(Failure(code: .unsupportedHardware, message: "somente Apple Silicon")) }
        guard smc.open() else { return .failure(Failure(code: .smcUnavailable, message: smc.lastError ?? "SMC indisponível")) }
        guard let n = fanCount(), FanSMCKeys.isValidFanIndex(fan), fan < n else {
            return .failure(Failure(code: .noSuchFan, message: "ventoinha inexistente"))
        }
        // Limites REAIS do SMC; qualquer valor fora de [min, max] é rejeitado sem tocar em nada.
        switch FanRPMPolicy.validate(rpm: rpm, min: rpmValue(FanSMCKeys.minimum(fan)), max: rpmValue(FanSMCKeys.maximum(fan))) {
        case .rejected(let code): return .failure(Failure(code: code, message: "rpm fora de [min,max] ou limites desconhecidos"))
        case .ok: break
        }
        guard let target = smc.read(FanSMCKeys.target(fan)),
              let payload = SMCFanTargetEncoding.encode(type: target.type, rpm: rpm, size: target.size) else {
            return .failure(Failure(code: .unsupportedHardware, message: "tipo da chave de alvo não suportado"))
        }

        // 1) modo manual (com destravamento Ftst se necessário)
        manualFans.insert(fan)   // registrar ANTES: se algo falhar, a restauração cobre esta ventoinha
        if let failure = enterManual(fan: fan) { return failAndRestore(failure) }
        if shouldAbort() { return failAndRestore(Failure(code: .internalError, message: "encerrando")) }

        // 2) alvo
        guard writeWithRetry(FanSMCKeys.target(fan), bytes: payload, size: target.size) else {
            return failAndRestore(Failure(code: .writeFailed, message: "escrita do alvo recusada: \(smc.lastError ?? "?")"))
        }

        // 3) leitura de volta: modo == 1 e alvo confere
        let modeNow = smc.read(modeKey(fan))?.bytes.first
        let targetNow = smc.read(FanSMCKeys.target(fan))?.number
        guard modeNow == 1, SMCFanTargetEncoding.matches(readBack: targetNow, requested: rpm) else {
            return failAndRestore(Failure(code: .verifyFailed, message: "leitura de volta não confere (modo/alvo)"))
        }
        return .success(())
    }

    private func failAndRestore(_ failure: Failure) -> Result<Void, Failure> {
        HelperLog.write("falha: \(failure.code.rawValue) (\(failure.message)); restaurando automático")
        _ = restoreAutomatic()
        return .failure(failure)
    }

    /// Passa a ventoinha para o modo manual (valor 1). Devolve nil em sucesso.
    private func enterManual(fan: Int) -> Failure? {
        let key = modeKey(fan)
        guard let current = smc.read(key) else { return Failure(code: .unlockFailed, message: "não foi possível ler \(key)") }
        if current.bytes.first == 1 { return nil }
        // Tentativa direta (funciona em chips recentes sem Ftst).
        if writeMode(key, current, to: 1) { return nil }

        // Caminho Ftst (M1–M4): pedir ao thermalmonitord que ceda o controle e repetir a escrita do modo.
        guard let ftst = smc.read(FanSMCKeys.unlockKey), ftst.size > 0 else {
            return Failure(code: .unlockFailed, message: "modo manual recusado e Ftst ausente")
        }
        if ftst.bytes.first == 1 {
            ftstEngaged = true
            return retryModeWrite(fan: fan, attempts: 20) ? nil : Failure(code: .unlockFailed, message: "modo manual recusado (Ftst já ativo)")
        }
        var on = ftst.bytes; on[0] = 1
        guard writeWithRetry(FanSMCKeys.unlockKey, bytes: on, size: ftst.size, attempts: 100) else {
            return Failure(code: .unlockFailed, message: "escrita de Ftst recusada")
        }
        ftstEngaged = true
        // Espera o thermalmonitord ceder o controle (3 s no Stats), em fatias para poder abortar.
        for _ in 0..<30 { if shouldAbort() { return Failure(code: .internalError, message: "encerrando") }; usleep(100_000) }
        return retryModeWrite(fan: fan, attempts: 100) ? nil : Failure(code: .unlockFailed, message: "modo manual recusado após Ftst")
    }

    private func writeMode(_ key: String, _ current: SMCConnection.Value, to mode: UInt8) -> Bool {
        var bytes = current.bytes
        bytes[0] = mode
        return smc.write(key, bytes: bytes, size: current.size)
    }

    private func retryModeWrite(fan: Int, attempts: Int) -> Bool {
        let key = modeKey(fan)
        for _ in 0..<attempts {
            if shouldAbort() { return false }
            if let current = smc.read(key), writeMode(key, current, to: 1) { return true }
            usleep(100_000)
        }
        return false
    }

    private func writeWithRetry(_ key: String, bytes: [UInt8], size: Int, attempts: Int = 10) -> Bool {
        for attempt in 0..<attempts {
            if smc.write(key, bytes: bytes, size: size) { return true }
            if attempt < attempts - 1 { usleep(50_000) }
        }
        return false
    }

    // MARK: Restauração

    /// Devolve o controle ao macOS: modo 0 e alvo 0 nas ventoinhas que estão em manual, depois Ftst = 0.
    /// true somente se a leitura de volta confirmar. Se falhar, `restorePending` fica ativo para nova tentativa.
    @discardableResult
    func restoreAutomatic() -> Bool {
        guard isSupportedArchitecture else { restorePending = false; manualFans.removeAll(); return true }
        guard smc.open() else { restorePending = isManualActive; return !restorePending }
        var ok = true
        let count = fanCount() ?? 0
        for i in 0..<count {
            let key = modeKey(i)
            guard let mode = smc.read(key) else { continue }
            if mode.bytes.first == 1 {   // 1 = manual (como o Stats); 0/3 já são automáticos
                if !writeWithRetry(key, bytes: { var b = mode.bytes; b[0] = 0; return b }(), size: mode.size) { ok = false }
                // Como no Stats (setFanMode automático): zerar o alvo.
                if let tg = smc.read(FanSMCKeys.target(i)),
                   let zero = SMCFanTargetEncoding.encode(type: tg.type, rpm: 0, size: tg.size) {
                    _ = writeWithRetry(FanSMCKeys.target(i), bytes: zero, size: tg.size)
                }
            }
        }
        if let ftst = smc.read(FanSMCKeys.unlockKey), ftst.size > 0, (ftst.bytes.first ?? 0) != 0 {
            var off = ftst.bytes; off[0] = 0
            if !writeWithRetry(FanSMCKeys.unlockKey, bytes: off, size: ftst.size) { ok = false }
        }
        // Confirmação por leitura de volta.
        for i in 0..<count where smc.read(modeKey(i))?.bytes.first == 1 { ok = false }
        if let ftst = smc.read(FanSMCKeys.unlockKey), (ftst.bytes.first ?? 0) != 0 { ok = false }
        if ok { manualFans.removeAll(); ftstEngaged = false }
        restorePending = !ok
        if !ok { HelperLog.write("restauração não confirmada; nova tentativa em breve") }
        return ok
    }
}
