import Foundation

public struct ClusterUsage: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(coreClass: CoreClass, usage: Double, cpuCount: Int) {
        self.coreClass = coreClass; self.usage = usage; self.cpuCount = cpuCount
    }
    public var coreClass: CoreClass
    public var usage: Double          // 0...1
    public var cpuCount: Int
}

public struct CPUSnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(load: CPULoad, loadAverage: LoadAverage?, clusters: [ClusterUsage], thermal: ThermalLevel) {
        self.load = load; self.loadAverage = loadAverage; self.clusters = clusters; self.thermal = thermal
    }
    public var load: CPULoad
    public var loadAverage: LoadAverage?
    /// Vazio quando a topologia não foi validada (mostrar só total e por núcleo, sem rótulos E/P).
    public var clusters: [ClusterUsage]
    public var thermal: ThermalLevel
}

public struct GPUSnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(timestamp: TimeInterval, name: String?, coreCount: Int?, utilization: Double?, renderer: Double?, tiler: Double?) {
        self.timestamp = timestamp; self.name = name; self.coreCount = coreCount
        self.utilization = utilization; self.renderer = renderer; self.tiler = tiler
    }
    public var timestamp: TimeInterval
    public var name: String?
    public var coreCount: Int?
    /// 0...1 ou nil quando a fonte não expõe utilização (nunca derivar de temperatura/potência).
    public var utilization: Double?
    public var renderer: Double?
    public var tiler: Double?
}

public struct SensorsSnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(timestamp: TimeInterval, readings: [SensorReading], aggregates: [SensorReading], fans: [FanReading]) {
        self.timestamp = timestamp; self.readings = readings; self.aggregates = aggregates; self.fans = fans
    }
    public var timestamp: TimeInterval
    public var readings: [SensorReading]
    public var aggregates: [SensorReading]
    public var fans: [FanReading]
}

public enum PowerScope: String, Codable {
    case systemTotal, dcIn, battery, cpu, gpu, ane, dram, pci, display, other
}

public struct PowerReading: Equatable, Identifiable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(id: String, name: String, scope: PowerScope, watts: Double?, quality: MetricQuality,
         source: SensorSource, timestamp: TimeInterval) {
        self.id = id; self.name = name; self.scope = scope; self.watts = watts
        self.quality = quality; self.source = source; self.timestamp = timestamp
    }
    public var id: String
    public var name: String
    public var scope: PowerScope
    public var watts: Double?
    public var quality: MetricQuality
    public var source: SensorSource
    public var timestamp: TimeInterval
}

public struct PowerSnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(timestamp: TimeInterval, readings: [PowerReading], energy: EnergyAccumulator?, energyScope: PowerScope?,
         movingAverageWatts: Double?) {
        self.timestamp = timestamp; self.readings = readings; self.energy = energy
        self.energyScope = energyScope; self.movingAverageWatts = movingAverageWatts
    }
    public var timestamp: TimeInterval
    public var readings: [PowerReading]
    public var energy: EnergyAccumulator?
    public var energyScope: PowerScope?
    public var movingAverageWatts: Double?
}

public struct VolumeInfo: Equatable, Identifiable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(id: String, name: String, totalBytes: UInt64, availableBytes: UInt64, isInternal: Bool, isRemovable: Bool) {
        self.id = id; self.name = name; self.totalBytes = totalBytes; self.availableBytes = availableBytes
        self.isInternal = isInternal; self.isRemovable = isRemovable
    }
    public var id: String          // ponto de montagem
    public var name: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var isInternal: Bool
    public var isRemovable: Bool
    public var usedFraction: Double { totalBytes > 0 ? 1 - Double(availableBytes) / Double(totalBytes) : 0 }
}

public struct DiskSnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(timestamp: TimeInterval, volumes: [VolumeInfo], readBytesPerSecond: Double?, writeBytesPerSecond: Double?) {
        self.timestamp = timestamp; self.volumes = volumes
        self.readBytesPerSecond = readBytesPerSecond; self.writeBytesPerSecond = writeBytesPerSecond
    }
    public var timestamp: TimeInterval
    public var volumes: [VolumeInfo]
    public var readBytesPerSecond: Double?
    public var writeBytesPerSecond: Double?
}

public enum NetworkKind: String, Codable { case wifi, ethernet, cellular, vpn, bridge, other }

public struct NetworkInterfaceRate: Equatable, Identifiable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(id: String, kind: NetworkKind, isUp: Bool, rxBytesPerSecond: Double?, txBytesPerSecond: Double?,
         totalRxBytes: UInt64, totalTxBytes: UInt64) {
        self.id = id; self.kind = kind; self.isUp = isUp
        self.rxBytesPerSecond = rxBytesPerSecond; self.txBytesPerSecond = txBytesPerSecond
        self.totalRxBytes = totalRxBytes; self.totalTxBytes = totalTxBytes
    }
    public var id: String          // nome BSD (en0…)
    public var kind: NetworkKind
    public var isUp: Bool
    public var rxBytesPerSecond: Double?
    public var txBytesPerSecond: Double?
    public var totalRxBytes: UInt64   // desde o início da sessão do app
    public var totalTxBytes: UInt64
}

public struct NetworkSnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(timestamp: TimeInterval, interfaces: [NetworkInterfaceRate], rxBytesPerSecond: Double?, txBytesPerSecond: Double?) {
        self.timestamp = timestamp; self.interfaces = interfaces
        self.rxBytesPerSecond = rxBytesPerSecond; self.txBytesPerSecond = txBytesPerSecond
    }
    public var timestamp: TimeInterval
    public var interfaces: [NetworkInterfaceRate]
    /// Soma só de interfaces físicas ativas (evita contar VPN/túnel em duplicidade).
    public var rxBytesPerSecond: Double?
    public var txBytesPerSecond: Double?
}

public struct BatterySnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(timestamp: TimeInterval, isPresent: Bool, percent: Double?, isCharging: Bool, onAC: Bool, minutesRemaining: Int?,
         cycleCount: Int?, healthPercent: Double?, temperatureC: Double?, voltageV: Double?, amperageA: Double?) {
        self.timestamp = timestamp; self.isPresent = isPresent; self.percent = percent; self.isCharging = isCharging
        self.onAC = onAC; self.minutesRemaining = minutesRemaining; self.cycleCount = cycleCount
        self.healthPercent = healthPercent; self.temperatureC = temperatureC
        self.voltageV = voltageV; self.amperageA = amperageA
    }
    public var timestamp: TimeInterval
    public var isPresent: Bool
    public var percent: Double?
    public var isCharging: Bool
    public var onAC: Bool
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    public var healthPercent: Double?
    public var temperatureC: Double?
    public var voltageV: Double?
    public var amperageA: Double?       // negativo = descarregando
    /// V × A do pacote de bateria. Escopo "bateria"; NÃO é o consumo do sistema.
    public var batteryPowerW: Double? {
        guard let v = voltageV, let a = amperageA else { return nil }
        return v * a
    }
}

public struct ProcessCPUEntry: Equatable, Identifiable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(identity: ProcessIdentity, name: String, groupName: String, coresBusy: Double) {
        self.identity = identity; self.name = name; self.groupName = groupName; self.coresBusy = coresBusy
    }
    public var id: ProcessIdentity { identity }
    public var identity: ProcessIdentity
    public var name: String
    public var groupName: String
    /// 1.0 = um núcleo inteiro (pode passar de 1, como no Monitor de Atividade).
    public var coresBusy: Double
}

public struct ProcessListSnapshot: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(timestamp: TimeInterval, byMemory: [AppGroup], byCPU: [ProcessCPUEntry], permissionLimited: Bool) {
        self.timestamp = timestamp; self.byMemory = byMemory; self.byCPU = byCPU; self.permissionLimited = permissionLimited
    }
    public var timestamp: TimeInterval
    public var byMemory: [AppGroup]
    public var byCPU: [ProcessCPUEntry]
    /// Verdadeiro quando o sistema negou leitura de parte dos processos.
    public var permissionLimited: Bool
}

public struct SystemProfile: Equatable {
    // Inicializador público (camada de plataforma do app, em outro módulo).
    public init(chip: ChipFamily?, modelIdentifier: String?, marketingModel: String?, totalMemoryBytes: UInt64,
         logicalCPUs: Int, physicalCPUs: Int, topology: CoreTopology?, osVersion: String,
         fanCount: Int?, gpuName: String?, gpuCores: Int?) {
        self.chip = chip; self.modelIdentifier = modelIdentifier; self.marketingModel = marketingModel
        self.totalMemoryBytes = totalMemoryBytes; self.logicalCPUs = logicalCPUs; self.physicalCPUs = physicalCPUs
        self.topology = topology; self.osVersion = osVersion; self.fanCount = fanCount
        self.gpuName = gpuName; self.gpuCores = gpuCores
    }
    public var chip: ChipFamily?
    public var modelIdentifier: String?
    public var marketingModel: String?
    public var totalMemoryBytes: UInt64
    public var logicalCPUs: Int
    public var physicalCPUs: Int
    public var topology: CoreTopology?
    public var osVersion: String
    public var fanCount: Int?
    public var gpuName: String?
    public var gpuCores: Int?
}
