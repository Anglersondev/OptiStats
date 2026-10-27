import Foundation
import OptiStatsCore

/// Servidor de socket Unix de um único cliente, num único thread (poll). Sem filas, sem timers, sem threads extras.
/// Segurança:
/// - o arquivo do socket é 0666, mas CADA conexão é validada por LOCAL_PEERCRED: só o uid do usuário de console;
/// - watchdog: sem heartbeat por 10 s, cliente desconectado, SIGTERM/SIGINT ou início → restaura o automático.
final class HelperServer {
    private let driver: SMCFanDriver
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var lineBuffer = FanHelperLineBuffer()
    private var watchdog = FanWatchdog()

    // Constantes do Darwin usadas literalmente (SOL_LOCAL / LOCAL_PEERCRED / XUCRED_VERSION).
    private static let solLocal: Int32 = 0
    private static let localPeerCred: Int32 = 0x001
    private static let xucredVersion: UInt32 = 0

    init(driver: SMCFanDriver) { self.driver = driver }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Ciclo principal

    /// Bloqueia até receber SIGTERM/SIGINT. Retorna depois de restaurar o automático e remover o socket.
    func run() -> Bool {
        guard openListener() else { return false }
        HelperLog.write("helper 1.0 escutando")
        while terminateRequested == 0 {
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
            if clientFD >= 0 { fds.append(pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)) }
            // Acorda no máximo a cada 1 s (e antes, se o watchdog estiver perto de expirar).
            var timeoutMs: Int32 = 1000
            if let rem = watchdog.remaining(at: now) { timeoutMs = min(timeoutMs, Int32(rem * 1000) + 20) }
            let n = poll(&fds, nfds_t(fds.count), timeoutMs)
            if n < 0 {
                if errno == EINTR { continue }
                HelperLog.write("poll falhou: errno \(errno)")
                break
            }
            if watchdog.isExpired(at: now) {
                HelperLog.write("watchdog: sem heartbeat; restaurando automático")
                restoreNow(reason: "watchdog")
            } else if driver.restorePending {
                restoreNow(reason: "nova tentativa")
            }
            guard n > 0 else { continue }
            if fds[0].revents & Int16(POLLIN) != 0 { acceptClient() }
            if fds.count > 1, fds[1].revents != 0 { serviceClient(fds[1].revents) }
        }
        HelperLog.write("encerrando; restaurando automático")
        closeClient(reason: "encerramento")
        _ = driver.restoreAutomatic()
        close(listenFD)
        unlink(FanHelperConstants.socketPath)
        return true
    }

    // MARK: Socket

    private func openListener() -> Bool {
        unlink(FanHelperConstants.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { HelperLog.write("socket falhou: errno \(errno)"); return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(FanHelperConstants.socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { HelperLog.write("bind falhou: errno \(errno)"); close(fd); return false }
        // O arquivo é acessível a qualquer usuário; a autorização real é o uid do peer (LOCAL_PEERCRED).
        chmod(FanHelperConstants.socketPath, 0o666)
        guard listen(fd, 2) == 0 else { HelperLog.write("listen falhou: errno \(errno)"); close(fd); return false }
        listenFD = fd
        return true
    }

    /// uid do dono de /dev/console (usuário logado na sessão gráfica). 0 = sem usuário (tela de login): ninguém é aceito.
    private func consoleUID() -> uid_t? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return nil }
        return st.st_uid
    }

    private func peerUID(of fd: Int32) -> uid_t? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, Self.solLocal, Self.localPeerCred, &cred, &len) == 0,
              cred.cr_version == Self.xucredVersion else { return nil }
        return cred.cr_uid
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard let console = consoleUID(), let peer = peerUID(of: fd), peer == console else {
            HelperLog.write("conexão recusada: uid do peer não é o do usuário de console")
            close(fd); return
        }
        guard clientFD < 0 else { HelperLog.write("conexão recusada: já existe um cliente"); close(fd); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)   // escrita de respostas nunca bloqueia por muito tempo
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        clientFD = fd
        lineBuffer = FanHelperLineBuffer()
        HelperLog.write("cliente conectado")
    }

    private func closeClient(reason: String) {
        guard clientFD >= 0 else { return }
        close(clientFD)
        clientFD = -1
        lineBuffer = FanHelperLineBuffer()
        HelperLog.write("cliente desconectado (\(reason))")
        restoreNow(reason: "cliente desconectou")
    }

    private func restoreNow(reason: String) {
        if driver.restoreAutomatic() { watchdog.disarm() }
        else { HelperLog.write("restauração pendente (\(reason))") }
    }

    private func serviceClient(_ revents: Int16) {
        if revents & Int16(POLLIN) != 0 {
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = read(clientFD, &buf, buf.count)
            if n <= 0 { closeClient(reason: n == 0 ? "fim" : "erro de leitura"); return }
            let lines = lineBuffer.append(Data(buf[0..<n]))
            for line in lines {
                handle(line)
                if clientFD < 0 { return }
            }
            if lineBuffer.overflowed { closeClient(reason: "linha longa demais"); return }
        } else if revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)) != 0 {
            closeClient(reason: "hangup")
        }
    }

    private func send(_ response: FanHelperResponse) {
        guard clientFD >= 0, let data = FanHelperCodec.encodeLine(response) else { return }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let w = write(clientFD, raw.baseAddress! + sent, raw.count - sent)
                if w <= 0 { return false }
                sent += w
            }
            return true
        }
        if !ok { closeClient(reason: "erro de escrita") }
    }

    // MARK: Pedidos

    private func handle(_ line: Data) {
        let request: FanHelperRequest
        switch FanHelperCodec.decodeRequest(line) {
        case .failure(let error):
            switch error {
            case .unsupportedVersion: send(.failure(id: 0, .unsupportedVersion))
            default: send(.failure(id: 0, .badRequest))
            }
            return
        case .success(let r): request = r
        }
        watchdog.beat(at: now)   // qualquer pedido válido prova que o app está vivo

        switch request.type {
        case .hello:
            send(FanHelperResponse(id: request.id, ok: true, helperBuild: FanHelperConstants.helperBuild,
                                   supported: driver.isSupportedArchitecture && driver.isSMCAvailable,
                                   manualActive: driver.isManualActive))
        case .readFans:
            send(FanHelperResponse(id: request.id, ok: true, fans: driver.readFans(), manualActive: driver.isManualActive))
        case .heartbeat:
            send(FanHelperResponse(id: request.id, ok: true, manualActive: driver.isManualActive))
        case .restoreAutomatic:
            if driver.restoreAutomatic() {
                watchdog.disarm()
                send(FanHelperResponse(id: request.id, ok: true, manualActive: false))
            } else {
                send(.failure(id: request.id, .writeFailed, "restauração não confirmada"))
            }
        case .setTarget:
            guard let fan = request.fan, let rpm = request.rpm else { send(.failure(id: request.id, .badRequest)); return }
            switch driver.setTarget(fan: fan, rpm: rpm) {
            case .success:
                watchdog.arm(at: now)
                send(FanHelperResponse(id: request.id, ok: true, manualActive: true))
            case .failure(let f):
                if !driver.isManualActive { watchdog.disarm() }
                send(.failure(id: request.id, f.code, f.message))
            }
        }
    }
}
