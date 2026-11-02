import Foundation

/// User-selected intent. Resolve against freshly read hardware limits on every resume.
public enum SavedFanTarget: Codable, Equatable {
    case maximum
    case rpm(Double)

    public func resolve(min: Double?, max: Double?) -> Double? {
        switch self {
        case .maximum:
            return FanRPMPolicy.clampForUI(.greatestFiniteMagnitude, min: min, max: max)
        case .rpm(let value):
            guard case .ok = FanRPMPolicy.validate(rpm: value, min: min, max: max) else { return nil }
            return value
        }
    }
}
