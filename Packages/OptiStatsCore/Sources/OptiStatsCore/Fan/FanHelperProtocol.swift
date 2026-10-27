import Foundation

// Protocolo entre o app e o helper privilegiado de ventoinhas (linhas JSON sobre socket Unix).
// Tudo aqui é puro (Foundation): o helper (root) e o app compartilham ESTAS regras, e elas são testadas no Linux.
// Princípios: versionado, mínimo, entrada hostil por padrão (tudo é validado), nunca aceita nome de chave SMC do cliente.

public enum FanHelperConstants {
    public static let protocolVersion = 1
    /// Versão do binário do helper (informada em `hello`). Incrementar quando o comportamento mudar.
    public static let helperBuild = 3
    public static let label = "dev.optistats.helper"
    public static let socketPath = "/var/run/dev.optistats.helper.sock"
    public static let helperPath = "/Library/PrivilegedHelperTools/dev.optistats.helper"
    public static let daemonPlistPath = "/Library/LaunchDaemons/dev.optistats.helper.plist"
    public static let logPath = "/var/log/dev.optistats.helper.log"
    /// Sem heartbeat por este tempo (com controle manual ativo) → o helper restaura o automático.
    public static let heartbeatTimeout: TimeInterval = 10
    /// Frequência com que o app envia heartbeat enquanto houver controle manual.
    public static let heartbeatInterval: TimeInterval = 3
    public static let maxLineBytes = 4096
}

public enum FanHelperRequestType: String, Codable, Equatable {
    case hello, readFans, setTarget, restoreAutomatic, heartbeat
}

public struct FanHelperRequest: Codable, Equatable {
    public var v: Int
    public var id: Int
    public var type: FanHelperRequestType
    public var fan: Int?
    public var rpm: Double?

    public init(id: Int, type: FanHelperRequestType, fan: Int? = nil, rpm: Double? = nil,
                v: Int = FanHelperConstants.protocolVersion) {
        self.v = v; self.id = id; self.type = type; self.fan = fan; self.rpm = rpm
    }
}

public enum FanHelperErrorCode: String, Codable, Equatable {
    case badRequest, unsupportedVersion, noSuchFan, limitsUnknown, outOfRange
    case smcUnavailable, unsupportedHardware, conflictingController, unlockFailed, writeFailed, verifyFailed, internalError
}

public struct FanHelperFanState: Codable, Equatable {
    public var index: Int
    public var rpm: Double?
    public var minRPM: Double?
    public var maxRPM: Double?
    /// true quando o modo da ventoinha no SMC é manual (diferente de 0).
    public var manual: Bool?
    public init(index: Int, rpm: Double?, minRPM: Double?, maxRPM: Double?, manual: Bool?) {
        self.index = index; self.rpm = rpm; self.minRPM = minRPM; self.maxRPM = maxRPM; self.manual = manual
    }
}

public struct FanHelperResponse: Codable, Equatable {
    public var v: Int
    public var id: Int
    public var ok: Bool
    public var error: FanHelperErrorCode?
    public var message: String?
    public var helperBuild: Int?
    /// `hello`: este hardware tem caminho de escrita suportado pelo helper (Apple Silicon).
    public var supported: Bool?
    public var fans: [FanHelperFanState]?
    /// O helper acredita que alguma ventoinha está em modo manual por causa dele.
    public var manualActive: Bool?

    public init(id: Int, ok: Bool, error: FanHelperErrorCode? = nil, message: String? = nil, helperBuild: Int? = nil,
                supported: Bool? = nil, fans: [FanHelperFanState]? = nil, manualActive: Bool? = nil,
                v: Int = FanHelperConstants.protocolVersion) {
        self.v = v; self.id = id; self.ok = ok; self.error = error; self.message = message
        self.helperBuild = helperBuild; self.supported = supported; self.fans = fans; self.manualActive = manualActive
    }

    public static func failure(id: Int, _ code: FanHelperErrorCode, _ message: String? = nil) -> FanHelperResponse {
        FanHelperResponse(id: id, ok: false, error: code, message: message)
    }
}

public enum FanHelperCodecError: Error, Equatable {
    case tooLong, notJSON, unsupportedVersion(Int), invalidField(String)
}

/// Codificação por linhas (um objeto JSON por linha, terminado em "\n").
public enum FanHelperCodec {
    public static func encodeLine<T: Encodable>(_ value: T) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]   // JSONEncoder nunca emite quebras de linha sem prettyPrinted
        guard var data = try? enc.encode(value), data.count < FanHelperConstants.maxLineBytes else { return nil }
        data.append(0x0A)
        return data
    }

    /// Decodifica e VALIDA um pedido (versão, índice da ventoinha, rpm finito). Não valida min/max (isso é do SMC).
    public static func decodeRequest(_ line: Data) -> Result<FanHelperRequest, FanHelperCodecError> {
        guard line.count <= FanHelperConstants.maxLineBytes else { return .failure(.tooLong) }
        guard let req = try? JSONDecoder().decode(FanHelperRequest.self, from: line) else { return .failure(.notJSON) }
        guard req.v == FanHelperConstants.protocolVersion else { return .failure(.unsupportedVersion(req.v)) }
        switch req.type {
        case .setTarget:
            guard let fan = req.fan, FanSMCKeys.isValidFanIndex(fan) else { return .failure(.invalidField("fan")) }
            guard let rpm = req.rpm, rpm.isFinite else { return .failure(.invalidField("rpm")) }
        case .hello, .readFans, .restoreAutomatic, .heartbeat:
            break
        }
        return .success(req)
    }

    public static func decodeResponse(_ line: Data) -> FanHelperResponse? {
        guard line.count <= FanHelperConstants.maxLineBytes else { return nil }
        return try? JSONDecoder().decode(FanHelperResponse.self, from: line)
    }
}

/// Acumula bytes e devolve linhas completas. Linha maior que o limite invalida o buffer (`overflowed`): fechar a conexão.
public struct FanHelperLineBuffer {
    private var pending = Data()
    public private(set) var overflowed = false
    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        guard !overflowed else { return [] }
        pending.append(data)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            if line.count > FanHelperConstants.maxLineBytes { overflowed = true; return lines }
            if !line.isEmpty { lines.append(line) }
        }
        if pending.count > FanHelperConstants.maxLineBytes { overflowed = true }
        return lines
    }
}

// MARK: - Lista fixa de chaves SMC que o helper pode escrever

/// O helper só escreve chaves geradas AQUI a partir de um índice de ventoinha validado; nunca uma chave vinda do cliente.
public enum FanSMCKeys {
    /// Quantidade máxima de ventoinhas tratadas (índices 0..<maxFans).
    public static let maxFans = 8
    public static let unlockKey = "Ftst"
    public static let countKey = "FNum"

    public static func isValidFanIndex(_ i: Int) -> Bool { i >= 0 && i < maxFans }
    public static func actual(_ i: Int) -> String { "F\(i)Ac" }
    public static func minimum(_ i: Int) -> String { "F\(i)Mn" }
    public static func maximum(_ i: Int) -> String { "F\(i)Mx" }
    public static func target(_ i: Int) -> String { "F\(i)Tg" }
    /// Chave de modo: "F{i}Md" (maioria) ou "F{i}md" (Apple Silicon recente). O helper sonda qual existe.
    public static func modeUpper(_ i: Int) -> String { "F\(i)Md" }
    public static func modeLower(_ i: Int) -> String { "F\(i)md" }

    /// Todas as chaves que podem ser escritas. Qualquer outra é recusada pelo helper.
    public static let writableKeys: Set<String> = {
        var s: Set<String> = [unlockKey]
        for i in 0..<maxFans { s.insert(target(i)); s.insert(modeUpper(i)); s.insert(modeLower(i)) }
        return s
    }()

    public static func isWritable(_ key: String) -> Bool { writableKeys.contains(key) }
}

// MARK: - Validação de RPM

public enum FanRPMValidation: Equatable {
    case ok(Double)
    case rejected(FanHelperErrorCode)
}

public enum FanRPMPolicy {
    /// Teto de sanidade para limites lidos do SMC (mesmo da validação de sensores).
    public static let sanityCeiling: Double = 20_000

    /// ESTRITA: rejeita (não ajusta) qualquer rpm fora de [min, max], valores não finitos e limites incoerentes.
    public static func validate(rpm: Double, min: Double?, max: Double?) -> FanRPMValidation {
        guard let lo = min, let hi = max, lo.isFinite, hi.isFinite, lo >= 0, hi > lo, hi <= sanityCeiling else {
            return .rejected(.limitsUnknown)
        }
        guard rpm.isFinite, rpm >= lo, rpm <= hi else { return .rejected(.outOfRange) }
        return .ok(rpm)
    }

    /// Para controles de interface (slider): ajusta para um inteiro dentro de [min, max]. nil se os limites forem inválidos.
    public static func clampForUI(_ rpm: Double, min: Double?, max: Double?) -> Double? {
        guard let lo = min, let hi = max, lo.isFinite, hi.isFinite, lo >= 0, hi > lo, hi <= sanityCeiling else { return nil }
        let a = lo.rounded(.up), b = hi.rounded(.down)
        guard b >= a, rpm.isFinite else { return nil }
        return Swift.min(b, Swift.max(a, rpm.rounded()))
    }
}

// MARK: - Codificação do alvo no SMC

public enum SMCFanTargetEncoding {
    /// Bytes do alvo para o tipo da chave `F{i}Tg`. Tipos: "flt " (float32 em ordem nativa little-endian no arm64)
    /// e "fpe2" (ponto fixo 14.2 big-endian), como em `SMC/smc.swift` do Stats (MIT). Outro tipo → nil (nunca adivinhar).
    public static func encode(type: String, rpm: Double, size: Int) -> [UInt8]? {
        guard rpm.isFinite, rpm >= 0 else { return nil }
        switch type {
        case "flt ":
            guard size >= 4 else { return nil }
            let bits = Float(rpm).bitPattern
            return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "fpe2":
            guard size >= 2, rpm <= 16383 else { return nil }
            let v = Int(rpm.rounded())
            return [UInt8(v >> 6), UInt8((v << 2) & 0xff)]
        default:
            return nil
        }
    }

    /// O alvo lido de volta confere com o pedido?
    public static func matches(readBack: Double?, requested: Double) -> Bool {
        guard let r = readBack, r.isFinite else { return false }
        return abs(r - requested) <= 1.0
    }
}

// MARK: - Watchdog

/// Relógio de segurança do helper. PURO: o tempo é passado por quem chama (relógio monotônico).
public struct FanWatchdog: Equatable {
    public let timeout: TimeInterval
    public private(set) var armed = false
    private var lastBeat: TimeInterval = 0

    public init(timeout: TimeInterval = FanHelperConstants.heartbeatTimeout) { self.timeout = timeout }

    /// Chamar quando alguma ventoinha entra em modo manual.
    public mutating func arm(at now: TimeInterval) { armed = true; lastBeat = now }
    /// Heartbeat (ou qualquer pedido válido do cliente).
    public mutating func beat(at now: TimeInterval) { if armed { lastBeat = now } }
    /// Chamar depois de restaurar o automático.
    public mutating func disarm() { armed = false }
    public func isExpired(at now: TimeInterval) -> Bool { armed && now - lastBeat > timeout }
    /// Quanto falta para expirar (para o timeout do poll); nil se desarmado.
    public func remaining(at now: TimeInterval) -> TimeInterval? { armed ? max(0, timeout - (now - lastBeat)) : nil }
}

// MARK: - Teste de validação de controle

public enum FanControlTestPlan {
    public static let boostRPM: Double = 300
    public static let holdSeconds: TimeInterval = 5
    /// Fração mínima do aumento planejado que o RPM real precisa atingir para o teste passar.
    public static let requiredFraction = 0.3
    /// Aumento mínimo para o teste ser conclusivo.
    public static let minimumDelta: Double = 100

    /// Alvo do teste: até +300 RPM acima do atual, dentro de [min, max]. nil se não houver margem conclusiva.
    public static func target(current: Double, min: Double?, max: Double?) -> Double? {
        guard current.isFinite, let hi = FanRPMPolicy.clampForUI(.greatestFiniteMagnitude, min: min, max: max),
              let lo = FanRPMPolicy.clampForUI(0, min: min, max: max) else { return nil }
        let target = Swift.min(hi, Swift.max(lo, (current + boostRPM).rounded()))
        guard target - current >= minimumDelta else { return nil }
        return target
    }

    /// O RPM observado subiu o suficiente em direção ao alvo?
    public static func passed(start: Double, target: Double, observed: Double?) -> Bool {
        guard let o = observed, o.isFinite, target > start else { return false }
        return o >= start + requiredFraction * (target - start)
    }
}
