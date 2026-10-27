import Cocoa
import OptiStatsCore

/// Bateria: carga, estado, tempo restante, saúde, ciclos e dados elétricos do pacote (V × A NÃO é o consumo do sistema).
final class BatteryPopover: StatPopover {
    private let ring = RingGaugeView(size: 92)
    private let statusRow = KeyValueRowView(title: L("battery.status"))
    private let timeRow = KeyValueRowView(title: L("battery.timeRemaining"))
    private let healthRow = KeyValueRowView(title: L("battery.health"))
    private let cyclesRow = KeyValueRowView(title: L("battery.cycles"))
    private let tempRow = KeyValueRowView(title: L("battery.temperature"))
    private let voltageRow = KeyValueRowView(title: L("battery.voltage"))
    private let currentRow = KeyValueRowView(title: L("battery.current"))
    private let packPowerRow = KeyValueRowView(title: L("battery.packPower"))

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "battery", title: L("battery.title"), collectors: [.battery], kinds: [.battery])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.battery?.timestamp }

    override func buildBody() {
        body.addFullWidth(makeSection(L("battery.section.charge"), [makeGaugeLayout(ring, [statusRow, timeRow, healthRow, cyclesRow])]))
        body.addFullWidth(makeSection(L("battery.section.pack"), [
            tempRow, voltageRow, currentRow, packPowerRow, Fmt.note(L("battery.packNote"), lines: 4, size: 10)]))
    }

    override func render() {
        guard let b = env.store.battery else { showEmpty(L("battery.empty")); return }
        guard b.isPresent else { showEmpty(L("battery.none")); return }
        showEmpty(nil)

        let fraction = b.percent.map { min(1, max(0, $0 / 100)) }
        ring.fraction = fraction ?? 0
        ring.color = fraction.map { $0 <= 0.2 && !b.onAC ? Theme.bad : Theme.good } ?? Theme.track
        ring.centerText = Fmt.percent(fraction)
        ring.subtitle = L("battery.charge")
        ring.setAccessibilityLabel("\(L("battery.charge")): \(Fmt.percent(fraction))")

        if b.isCharging {
            statusRow.value = L("battery.state.charging")
            timeRow.title = L("battery.timeToFull")
        } else if b.onAC {
            statusRow.value = L("battery.state.onACIdle")
            timeRow.title = L("battery.timeRemaining")
        } else {
            statusRow.value = L("battery.state.discharging")
            timeRow.title = L("battery.timeRemaining")
        }
        timeRow.value = b.minutesRemaining.map { Fmt.duration(minutes: $0) } ?? Fmt.dash
        healthRow.value = b.healthPercent.map { Fmt.number($0, decimals: 0, unit: "%") } ?? Fmt.dash
        cyclesRow.value = b.cycleCount.map { String($0) } ?? Fmt.dash
        tempRow.value = Fmt.temperature(b.temperatureC, unit: env.preferences.current.temperatureUnit)
        voltageRow.value = Fmt.number(b.voltageV, decimals: 2, unit: "V")
        currentRow.value = Fmt.number(b.amperageA, decimals: 2, unit: "A")
        packPowerRow.value = Fmt.number(b.batteryPowerW, decimals: 1, unit: "W")
    }
}
