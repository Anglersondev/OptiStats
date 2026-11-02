import Foundation
import OptiStatsCore

/// Preferências do controle de ventoinhas. Ficam FORA de `Preferences` (Core) de propósito: não alteram o esquema
/// compartilhado, e tudo aqui nasce DESLIGADO. Chaves próprias em UserDefaults.
final class FanControlSettings {
    private let defaults: UserDefaults
    private let modelKey: () -> String
    private enum Key {
        static let manualAllowed = "app.optistats.fanControl.manualAllowed"
        static let smartBoost = "app.optistats.fanControl.smartBoost"
        static let savedTargets = "app.optistats.fanControl.savedTargets"
    }

    init(defaults: UserDefaults = .standard, modelKey: @escaping () -> String) {
        self.defaults = defaults
        self.modelKey = modelKey
    }

    /// "Permitir controle manual". Desligado por padrão; sem ele nenhum comando de escrita sai do app.
    var manualAllowed: Bool {
        get { defaults.bool(forKey: Key.manualAllowed) }
        set { defaults.set(newValue, forKey: Key.manualAllowed) }
    }

    /// Smart Boost: desligado por padrão; só liga por interruptor explícito (e só em Mac validado).
    var smartBoostEnabled: Bool {
        get { defaults.bool(forKey: Key.smartBoost) }
        set { defaults.set(newValue, forKey: Key.smartBoost) }
    }

    /// Identificador do Mac usado na flag de validação (modelo de hardware + versão principal do macOS).
    var currentModel: String { modelKey() }

    /// Per-model intent survives exit/sleep; Automatic and revoking permission clear it.
    var savedTargets: [Int: SavedFanTarget] {
        get {
            guard let data = defaults.data(forKey: Key.savedTargets + "." + currentModel),
                  let targets = try? JSONDecoder().decode([Int: SavedFanTarget].self, from: data) else { return [:] }
            return targets.filter { FanSMCKeys.isValidFanIndex($0.key) }
        }
        set {
            let key = Key.savedTargets + "." + currentModel
            if newValue.isEmpty { defaults.removeObject(forKey: key) }
            else if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
        }
    }

}
