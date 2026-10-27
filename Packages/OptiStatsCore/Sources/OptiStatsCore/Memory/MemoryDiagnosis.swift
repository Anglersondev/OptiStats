import Foundation

/// Diagnóstico honesto de memória: "pressão real" versus "cache cheio" (o macOS usa RAM livre como cache; isso é normal).
public struct MemoryDiagnosisConfig: Equatable {
    /// Swap in/out por segundo (páginas) a partir do qual há troca ativa.
    public var activeSwapPerSecond: Double = 5
    /// Memória disponível (fração do total) abaixo da qual a folga é considerada baixa.
    public var lowAvailableFraction = 0.10
    /// Comprimido (fração do total) acima da qual o compressor está muito usado.
    public var heavyCompressedFraction = 0.25
    /// "Livre estrito" abaixo disto + cache acima de `cacheLooksFullFraction` = parece cheia, mas é cache.
    public var lowFreeFraction = 0.05
    public var cacheLooksFullFraction = 0.15
    public init() {}
}

public enum MemoryVerdict: Equatable {
    /// Pressão do kernel normal e sem sinais de aperto.
    case healthy
    /// Pouca memória "livre" porque o macOS a usa como cache de arquivos. Normal; nenhuma ação necessária.
    case cacheFull
    /// Sinais leves de aperto (pressão em atenção, compressor alto, swap em uso) sem troca ativa.
    case watch
    /// Pressão real: kernel em nível crítico, ou atenção com troca ativa em disco.
    case realPressure
    /// Sem pressão do kernel disponível: sem diagnóstico confiável.
    case insufficientData
}

public enum MemoryDiagnosisReason: Equatable {
    case kernelPressure(PressureBand)
    case activeSwapOut(perSecond: Double)
    case activeSwapIn(perSecond: Double)
    case swapInUse(bytes: UInt64)
    case heavyCompression(bytes: UInt64)
    case lowAvailable(bytes: UInt64)
    case fileCacheLarge(bytes: UInt64)
}

public struct MemoryDiagnosis: Equatable {
    public var verdict: MemoryVerdict
    public var reasons: [MemoryDiagnosisReason]
    /// Bytes originais ÷ bytes do compressor (> 1 = o compressor está poupando RAM). nil se a fonte não informa.
    public var compressionRatio: Double?
    public var compressionsPerSecond: Double?

    /// - Parameter rates: taxas entre duas fotos recentes (nil na primeira amostra).
    public static func evaluate(_ snap: MemorySnapshot, rates: MemoryRates?,
                                config: MemoryDiagnosisConfig = MemoryDiagnosisConfig()) -> MemoryDiagnosis {
        let ratio = compressionRatio(of: snap)
        guard let level = snap.pressure else {
            return MemoryDiagnosis(verdict: .insufficientData, reasons: [], compressionRatio: ratio,
                                   compressionsPerSecond: rates?.compressionsPerSecond)
        }
        let total = Double(max(1, snap.totalBytes))
        var reasons: [MemoryDiagnosisReason] = []
        let band = PressureBand(level)
        if band != .normal { reasons.append(.kernelPressure(band)) }

        let outs = rates?.swapOutsPerSecond ?? 0
        let ins = rates?.swapInsPerSecond ?? 0
        let swapOutActive = outs >= config.activeSwapPerSecond
        let swapInActive = ins >= config.activeSwapPerSecond
        if swapOutActive { reasons.append(.activeSwapOut(perSecond: outs)) }
        if swapInActive { reasons.append(.activeSwapIn(perSecond: ins)) }

        if let used = snap.swap?.usedBytes, used > 512 * 1024 * 1024 { reasons.append(.swapInUse(bytes: used)) }
        let heavyCompressed = Double(snap.compressedBytes) / total >= config.heavyCompressedFraction
        if heavyCompressed { reasons.append(.heavyCompression(bytes: snap.compressedBytes)) }
        let lowAvailable = Double(snap.availableBytes) / total < config.lowAvailableFraction
        if lowAvailable { reasons.append(.lowAvailable(bytes: snap.availableBytes)) }

        let verdict: MemoryVerdict
        if level == .critical || (band != .normal && (swapOutActive || swapInActive)) {
            verdict = .realPressure
        } else if band != .normal || swapOutActive || swapInActive || heavyCompressed || lowAvailable {
            verdict = .watch
        } else if Double(snap.freeStrictBytes) / total < config.lowFreeFraction
                    && Double(snap.cachedFilesBytes) / total >= config.cacheLooksFullFraction {
            reasons.append(.fileCacheLarge(bytes: snap.cachedFilesBytes))
            verdict = .cacheFull
        } else {
            verdict = .healthy
        }
        return MemoryDiagnosis(verdict: verdict, reasons: reasons, compressionRatio: ratio,
                               compressionsPerSecond: rates?.compressionsPerSecond)
    }

    public static func compressionRatio(of snap: MemorySnapshot) -> Double? {
        guard let original = snap.compressorOriginalBytes, original > 0, snap.compressedBytes > 0 else { return nil }
        return Double(original) / Double(snap.compressedBytes)
    }
}

/// Antes/depois de um `purge`: variações GLOBAIS observadas; nunca atribuídas a um ganho do purge.
public struct PurgeReport: Equatable {
    public var before: MemorySnapshot?
    public var after: MemorySnapshot?
    public init(before: MemorySnapshot?, after: MemorySnapshot?) { self.before = before; self.after = after }

    private func delta(_ f: (MemorySnapshot) -> UInt64) -> Int64? {
        guard let b = before, let a = after else { return nil }
        return Int64(f(a)) - Int64(f(b))
    }
    public var availableDelta: Int64? { delta(\.availableBytes) }
    public var cachedDelta: Int64? { delta(\.cachedFilesBytes) }
    public var appDelta: Int64? { delta(\.appBytes) }
}
