import Foundation
import OptiStatsCore

/// Falhas ao falar com o helper.
enum FanClientFailure: Error, Equatable {
    case notInstalled
    case transport(String)
    case helper(FanHelperErrorCode, String?)
    case versionMismatch
}

struct HelperHello: Equatable {
    var build: Int
    var supported: Bool
    var manualActive: Bool
}

/// Cliente do helper por socket Unix (linhas JSON). Implementa `FanActuator` do Core.
/// - Uma conexão persistente: se o app morrer ou fechar, o helper restaura o automático sozinho.
/// - Todas as trocas são serializadas por trava; chamadas bloqueiam com tempo limite (nunca chamar na main, exceto restauração).
/// - `capability` fica em `.experimentalUnvalidated` até o teste de controle passar neste Mac.
final class HelperFanActuator: FanActuator {
    private let lock = NSLock()
    /// A interface lê a capacidade sem esperar uma troca com o SMC (que pode levar até 40 s).
    private let capabilityLock = NSLock()
    private var fd: Int32 = -1 { didSet { mirrorLock.lock(); fdMirror = fd; mirrorLock.unlock() } }
    /// Cópia do descritor, protegida por trava própria, para `emergencyDisconnect()` não esperar uma troca em andamento.
    private let mirrorLock = NSLock()
    private var fdMirror: Int32 = -1
    private var nextID = 1
    private var buffer = FanHelperLineBuffer()
    private var queued: [Data] = []
    private var manualEngaged = false
    private var unsupportedReason: String?
    let settings: FanControlSettings

    init(settings: FanControlSettings) { self.settings = settings }

    deinit { if fd >= 0 { close(fd) } }

    // MARK: FanActuator

    var capability: FanControlCapability {
        capabilityLock.lock(); let reason = unsupportedReason; capabilityLock.unlock()
        if HelperInstaller.state() == .notInstalled { return .unavailable(reason: L("fan.cap.notInstalled")) }
        if let reason { return .unavailable(reason: reason) }
        return settings.isValidatedForThisMac ? .validated : .experimentalUnvalidated
    }

    func apply(_ command: FanCommand) -> ActuatorResult {
        switch command {
        case .restoreAutomatic:
            lock.lock(); let engaged = manualEngaged; let connected = fd >= 0; lock.unlock()
            // Nada em manual e sem conexão aberta: já está automático (se o app caiu antes, o helper já restaurou).
            if !engaged && !connected { return .ok }
            switch restoreAutomatic() {
            case .success: return .ok
            case .failure(let f): return engaged ? .failed(Self.describe(f)) : .ok
            }

        case .heartbeat:
            lock.lock(); let engaged = manualEngaged; lock.unlock()
            if !engaged { return .ok }
            if case .failure(let f) = heartbeat() { return .failed(Self.describe(f)) }
            return .ok

        case .setTarget(let rpm):
            guard settings.manualAllowed else { return .denied }
            if case .unavailable = capability { return .unsupported }
            switch readFans() {
            case .failure(let f): return .failed(Self.describe(f))
            case .success(let fans):
                guard !fans.isEmpty else { return .unsupported }
                for fan in fans {
                    // Cada ventoinha dentro dos SEUS limites (o helper rejeita qualquer valor fora deles).
                    guard let value = FanRPMPolicy.clampForUI(rpm, min: fan.minRPM, max: fan.maxRPM) else {
                        _ = restoreAutomatic()
                        return .failed(L("fan.err.limitsUnknown"))
                    }
                    if case .failure(let f) = setTarget(fan: fan.index, rpm: value) {
                        _ = restoreAutomatic()
                        return .failed(Self.describe(f))
                    }
                }
                return .ok
            }
        }
    }

    // MARK: Operações do helper

    func hello() -> Result<HelperHello, FanClientFailure> {
        exchange(.hello, timeout: 4).flatMap { (r: FanHelperResponse) -> Result<HelperHello, FanClientFailure> in
            guard let build = r.helperBuild else { return .failure(.versionMismatch) }
            capabilityLock.lock(); unsupportedReason = (r.supported == false) ? L("fan.cap.unsupportedHardware") : nil; capabilityLock.unlock()
            return .success(HelperHello(build: build, supported: r.supported ?? false, manualActive: r.manualActive ?? false))
        }
    }

    func readFans() -> Result<[FanHelperFanState], FanClientFailure> {
        exchange(.readFans, timeout: 4).map { $0.fans ?? [] }
    }

    /// `setTarget` pode demorar (destravamento Ftst no Apple Silicon): tempo limite longo.
    func setTarget(fan: Int, rpm: Double) -> Result<Void, FanClientFailure> {
        let r = exchange(.setTarget, fan: fan, rpm: rpm, timeout: 40)
        if case .success = r { lock.lock(); manualEngaged = true; lock.unlock() }
        return r.map { _ in () }
    }

    func restoreAutomatic() -> Result<Void, FanClientFailure> {
        let r = exchange(.restoreAutomatic, timeout: 8)
        if case .success = r { lock.lock(); manualEngaged = false; lock.unlock() }
        return r.map { _ in () }
    }

    func heartbeat() -> Result<Void, FanClientFailure> {
        exchange(.heartbeat, timeout: 4).map { _ in () }
    }

    /// Fecha a conexão. O helper restaura o automático ao ver a desconexão.
    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
        manualEngaged = false
    }

    /// Encerramento do app: tenta restaurar de forma educada (se não houver troca em andamento) e, de qualquer jeito,
    /// derruba a conexão (`shutdown`), o que acorda leituras bloqueadas e faz o helper restaurar o automático.
    func restoreForShutdown() {
        if lock.try() {
            let engaged = manualEngaged || fd >= 0
            lock.unlock()
            if engaged { _ = restoreAutomatic() }
        }
        emergencyDisconnect()
    }

    func emergencyDisconnect() {
        mirrorLock.lock(); let f = fdMirror; mirrorLock.unlock()
        if f >= 0 { shutdown(f, SHUT_RDWR) }
    }

    // MARK: Transporte

    static func describe(_ f: FanClientFailure) -> String {
        switch f {
        case .notInstalled: return L("fan.err.notInstalled")
        case .transport(let m): return L("fan.err.transport", m)
        case .versionMismatch: return L("fan.err.version")
        case .helper(let code, let detail):
            let text = L("fan.err.\(code.rawValue)")
            return detail.map { text + " (\($0))" } ?? text
        }
    }

    private func closeLocked() {
        if fd >= 0 { close(fd); fd = -1 }
        buffer = FanHelperLineBuffer()
        queued.removeAll()
    }

    private func connectLocked() -> FanClientFailure? {
        if fd >= 0 { return nil }
        guard FileManager.default.fileExists(atPath: FanHelperConstants.socketPath) else { return .notInstalled }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return .transport("socket \(errno)") }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(FanHelperConstants.socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return .transport("path") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { let e = errno; close(s); return .transport("connect \(e)") }
        fd = s
        buffer = FanHelperLineBuffer()
        queued.removeAll()
        return nil
    }

    private func setTimeouts(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func exchange(_ type: FanHelperRequestType, fan: Int? = nil, rpm: Double? = nil,
                          timeout: TimeInterval) -> Result<FanHelperResponse, FanClientFailure> {
        lock.lock(); defer { lock.unlock() }
        if let failure = connectLocked() { return .failure(failure) }
        let id = nextID; nextID += 1
        guard let data = FanHelperCodec.encodeLine(FanHelperRequest(id: id, type: type, fan: fan, rpm: rpm)) else {
            return .failure(.transport("encode"))
        }
        setTimeouts(timeout)
        let sent = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let w = write(fd, raw.baseAddress! + off, raw.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
        guard sent else { closeLocked(); return .failure(.transport("write")) }

        // Lê até a resposta com o mesmo id (respostas antigas são descartadas).
        while true {
            // id 0 = o helper não conseguiu nem ler o pedido (ex.: versão do protocolo diferente).
            if let idx = queued.firstIndex(where: { let rid = FanHelperCodec.decodeResponse($0)?.id; return rid == id || rid == 0 }) {
                let line = queued.remove(at: idx)
                guard let resp = FanHelperCodec.decodeResponse(line) else { return .failure(.transport("decode")) }
                if resp.ok { return .success(resp) }
                if resp.error == .unsupportedVersion { return .failure(.versionMismatch) }
                return .failure(.helper(resp.error ?? .internalError, resp.message))
            }
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = read(fd, &buf, buf.count)
            if n <= 0 { closeLocked(); return .failure(.transport(n == 0 ? "closed" : "timeout")) }
            queued += buffer.append(Data(buf[0..<n]))
            if buffer.overflowed { closeLocked(); return .failure(.transport("overflow")) }
        }
    }
}
