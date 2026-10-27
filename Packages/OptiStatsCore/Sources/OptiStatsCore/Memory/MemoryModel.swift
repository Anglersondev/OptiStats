import Foundation

/// Contadores brutos de `host_statistics64(HOST_VM_INFO64)` (em páginas) já extraídos pela camada de plataforma.
public struct VMStatistics: Equatable {
    public var pageSize: UInt64
    public var freeCount: UInt64
    public var activeCount: UInt64
    public var inactiveCount: UInt64
    public var speculativeCount: UInt64
    public var wireCount: UInt64
    public var compressorPageCount: UInt64
    public var purgeableCount: UInt64
    public var externalPageCount: UInt64
    public var internalPageCount: UInt64
    // Contadores cumulativos (usados só para taxas)
    public var swapIns: UInt64
    public var swapOuts: UInt64
    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64
    /// Páginas ORIGINAIS (não comprimidas) guardadas no compressor (`total_uncompressed_pages_in_compressor`). Opcional.
    public var uncompressedInCompressorCount: UInt64 = 0

    public init(pageSize: UInt64, freeCount: UInt64 = 0, activeCount: UInt64 = 0, inactiveCount: UInt64 = 0,
                speculativeCount: UInt64 = 0, wireCount: UInt64 = 0, compressorPageCount: UInt64 = 0,
                purgeableCount: UInt64 = 0, externalPageCount: UInt64 = 0, internalPageCount: UInt64 = 0,
                swapIns: UInt64 = 0, swapOuts: UInt64 = 0, pageIns: UInt64 = 0, pageOuts: UInt64 = 0,
                compressions: UInt64 = 0, decompressions: UInt64 = 0, uncompressedInCompressorCount: UInt64 = 0) {
        self.uncompressedInCompressorCount = uncompressedInCompressorCount
        self.pageSize = pageSize
        self.freeCount = freeCount
        self.activeCount = activeCount
        self.inactiveCount = inactiveCount
        self.speculativeCount = speculativeCount
        self.wireCount = wireCount
        self.compressorPageCount = compressorPageCount
        self.purgeableCount = purgeableCount
        self.externalPageCount = externalPageCount
        self.internalPageCount = internalPageCount
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.compressions = compressions
        self.decompressions = decompressions
    }
}

public struct SwapUsage: Equatable {
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var freeBytes: UInt64
    public init(totalBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
    }
}

/// Nível de pressão do kernel (`kern.memorystatus_vm_pressure_level`: 1, 2, 4).
public enum MemoryPressureLevel: Int, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public init?(kernelValue: Int) {
        switch kernelValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }
    public static func < (a: MemoryPressureLevel, b: MemoryPressureLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Foto imutável da memória. Todas as grandezas em bytes.
///
/// Fórmulas (estilo Monitor de Atividade; devem ser reconciliadas no hardware real):
/// - app        = (internal − purgeable) × página
/// - wired      = wire × página
/// - compressed = compressor × página
/// - used       = app + wired + compressed
/// - cachedFiles= (external + purgeable) × página   (reutilizável)
/// - freeStrict = (free − speculative) × página      (estrito, como `vm_stat`)
/// - available  = total − used                        (livre + cache reutilizável)
public struct MemorySnapshot: Equatable {
    public var timestamp: TimeInterval
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var usedBytes: UInt64
    public var cachedFilesBytes: UInt64
    public var freeStrictBytes: UInt64
    public var availableBytes: UInt64
    /// Fórmula alternativa (a usada pelo Stats), mantida para reconciliação em diagnósticos.
    public var alternativeUsedBytes: UInt64
    public var swap: SwapUsage?
    public var pressure: MemoryPressureLevel?
    public var counters: MemoryCounters
    /// Bytes originais (antes de comprimir) guardados no compressor; nil se a fonte não informa.
    public var compressorOriginalBytes: UInt64? = nil

    public var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

public struct MemoryCounters: Equatable {
    public var swapIns: UInt64
    public var swapOuts: UInt64
    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64
}

public enum MemoryFormula {
    private static func sub(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }

    public static func snapshot(from vm: VMStatistics, totalBytes: UInt64, swap: SwapUsage?,
                                pressure: MemoryPressureLevel?, timestamp: TimeInterval) -> MemorySnapshot {
        let page = vm.pageSize
        let app = sub(vm.internalPageCount, vm.purgeableCount) * page
        let wired = vm.wireCount * page
        let compressed = vm.compressorPageCount * page
        let used = app + wired + compressed
        let cached = (vm.externalPageCount + vm.purgeableCount) * page
        let freeStrict = sub(vm.freeCount, vm.speculativeCount) * page
        let available = sub(totalBytes, used)

        let altGross = (vm.activeCount + vm.inactiveCount + vm.speculativeCount + vm.wireCount + vm.compressorPageCount) * page
        let altUsed = sub(altGross, (vm.purgeableCount + vm.externalPageCount) * page)

        return MemorySnapshot(
            timestamp: timestamp, totalBytes: totalBytes,
            appBytes: app, wiredBytes: wired, compressedBytes: compressed, usedBytes: used,
            cachedFilesBytes: cached, freeStrictBytes: freeStrict, availableBytes: available,
            alternativeUsedBytes: altUsed, swap: swap, pressure: pressure,
            counters: MemoryCounters(swapIns: vm.swapIns, swapOuts: vm.swapOuts, pageIns: vm.pageIns,
                                     pageOuts: vm.pageOuts, compressions: vm.compressions,
                                     decompressions: vm.decompressions),
            compressorOriginalBytes: vm.uncompressedInCompressorCount > 0 ? vm.uncompressedInCompressorCount * page : nil)
    }
}

/// Taxas por segundo entre duas fotos (swap, compressão), com proteção a reinícios de contador.
public struct MemoryRates: Equatable {
    public var swapInsPerSecond: Double
    public var swapOutsPerSecond: Double
    public var compressionsPerSecond: Double

    public static func between(_ a: MemorySnapshot, _ b: MemorySnapshot) -> MemoryRates? {
        let dt = b.timestamp - a.timestamp
        guard dt > 0 else { return nil }
        func rate(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) / dt : 0 }
        return MemoryRates(
            swapInsPerSecond: rate(a.counters.swapIns, b.counters.swapIns),
            swapOutsPerSecond: rate(a.counters.swapOuts, b.counters.swapOuts),
            compressionsPerSecond: rate(a.counters.compressions, b.counters.compressions))
    }
}

/// Classificação exibida na interface (Normal / Atenção / Alta).
public enum PressureBand: Equatable {
    case normal, attention, high, unknown
    public init(_ level: MemoryPressureLevel?) {
        switch level {
        case .some(.normal): self = .normal
        case .some(.warning): self = .attention
        case .some(.critical): self = .high
        case .none: self = .unknown
        }
    }
}
