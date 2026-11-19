import Foundation

/// Named sets of picture settings, stored as `[name: [key: value]]`.
public enum Presets {
    /// What a preset holds: the look and framing, not the load (size, frame rate, quality).
    public static let keys: Set<String> = ["lens", "zoom", "frame", "level", "wb", "exp", "mains", "sat", "con", "black",
                                           "hsl", "accents", "accentAmt", "light", "lightAmt", "tone", "warm", "tint", "skinWarm", "rot", "lut", "lutAmt"]
    public static let maxCount = 12
    public static let maxNameLength = 24

    /// Trimmed and shortened name; nil when nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        return name.isEmpty ? nil : name
    }

    /// `all` with the current `settings` saved as `raw`; nil when the name is empty or the list is full
    /// (overwriting an existing preset is always allowed).
    public static func saving(_ raw: String, settings: [String: String],
                              into all: [String: [String: String]]) -> [String: [String: String]]? {
        guard let name = cleanName(raw), all[name] != nil || all.count < maxCount else { return nil }
        var out = all
        out[name] = settings.filter { keys.contains($0.key) }
        return out
    }

    public static func sortedNames(_ all: [String: [String: String]]) -> [String] {
        all.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
