import Foundation

/// Preferências do controle de ventoinhas. Ficam FORA de `Preferences` (Core) de propósito: não alteram o esquema
/// compartilhado, e tudo aqui nasce DESLIGADO. Chaves próprias em UserDefaults.
final class FanControlSettings {
    private let defaults: UserDefaults
    private let modelKey: () -> String
    private enum Key {
        static let manualAllowed = "app.optistats.fanControl.manualAllowed"
        static let smartBoost = "app.optistats.fanControl.smartBoost"
        static let validatedModels = "app.optistats.fanControl.validatedModels"
        static let unsupportedModels = "app.optistats.fanControl.unsupportedModels"
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

    var isValidatedForThisMac: Bool {
        (defaults.stringArray(forKey: Key.validatedModels) ?? []).contains(currentModel)
    }

    /// O teste reprovou neste Mac/macOS: o controle manual fica escondido até o dono pedir para tentar de novo.
    var isUnsupportedForThisMac: Bool {
        (defaults.stringArray(forKey: Key.unsupportedModels) ?? []).contains(currentModel)
    }

    func markUnsupported(_ unsupported: Bool) {
        var list = Set(defaults.stringArray(forKey: Key.unsupportedModels) ?? [])
        if unsupported { list.insert(currentModel) } else { list.remove(currentModel) }
        defaults.set(Array(list).sorted(), forKey: Key.unsupportedModels)
    }

    func markValidated(_ validated: Bool) {
        var list = Set(defaults.stringArray(forKey: Key.validatedModels) ?? [])
        if validated { list.insert(currentModel) } else { list.remove(currentModel) }
        defaults.set(Array(list).sorted(), forKey: Key.validatedModels)
    }
}
