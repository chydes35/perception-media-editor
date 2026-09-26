import Foundation

struct UserPresetRepository {
    private static let key = "perceptionEditor.userPresets.v1"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [PhotoPreset] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? decoder.decode([PhotoPreset].self, from: data)) ?? []
    }

    func save(_ presets: [PhotoPreset]) {
        guard let data = try? encoder.encode(presets) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
