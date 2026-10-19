import Foundation

/// The reader's fallback list: which of them are offered, in what order, and their own presets.
@MainActor
@Observable
final class FallbackStore {
    private let defaults = UserDefaults.standard
    private let orderKey = "fallbackOrder"
    private let disabledKey = "disabledFallbacks"
    private let presetsKey = "fallbackPresets"

    private(set) var orderedIDs: [String]
    private(set) var disabledIDs: Set<String>
    /// In creation order; the list's own order is `orderedIDs`, like every other fallback.
    private(set) var presets: [FallbackPreset]

    init() {
        orderedIDs = defaults.stringArray(forKey: orderKey) ?? []
        disabledIDs = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        presets =
            defaults.data(forKey: presetsKey)
            .flatMap { try? JSONDecoder().decode([FallbackPreset].self, from: $0) } ?? []
    }

    func preset(id: UUID) -> FallbackPreset? {
        presets.first { $0.id == id }
    }

    /// Adds or replaces by id. Blank values are dropped, so the query may fill those arguments.
    func save(_ preset: FallbackPreset) {
        var value = preset
        value.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.values = preset.values.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let index = presets.firstIndex(where: { $0.id == value.id }) {
            presets[index] = value
        } else {
            presets.append(value)
        }
        persistPresets()
    }

    func removePresets(where shouldRemove: (FallbackPreset) -> Bool) {
        let removed = presets.filter(shouldRemove)
        guard !removed.isEmpty else { return }
        presets.removeAll(where: shouldRemove)
        let ids = Set(removed.map { Fallback.preset($0.id).id })
        orderedIDs.removeAll(where: ids.contains)
        disabledIDs.subtract(ids)
        defaults.set(orderedIDs, forKey: orderKey)
        defaults.set(Array(disabledIDs), forKey: disabledKey)
        persistPresets()
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey)
    }

    func ordered(_ available: [Fallback]) -> [Fallback] {
        Fallback.ordered(available, by: orderedIDs)
    }

    func isEnabled(_ fallback: Fallback) -> Bool { !disabledIDs.contains(fallback.id) }

    func setEnabled(_ enabled: Bool, for fallback: Fallback) {
        if enabled {
            disabledIDs.remove(fallback.id)
        } else {
            disabledIDs.insert(fallback.id)
        }
        defaults.set(Array(disabledIDs), forKey: disabledKey)
    }

    /// Swaps two neighbours and stores the whole visible order, so no later row can drift.
    func exchange(_ fallback: Fallback, with other: Fallback, in order: [Fallback]) {
        guard let from = order.firstIndex(of: fallback), let to = order.firstIndex(of: other) else {
            return
        }
        var updated = order
        updated.swapAt(from, to)
        orderedIDs = updated.map(\.id)
        defaults.set(orderedIDs, forKey: orderKey)
    }
}
