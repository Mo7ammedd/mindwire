import Foundation

/// Persistence port for a list of identifiable records.
protocol ListStore<Item> {
    associatedtype Item: Codable & Identifiable where Item.ID == String
    func list() -> [Item]
    func get(_ id: String) -> Item?
    func save(_ item: Item)
    func remove(_ id: String)
    func replaceAll(_ items: [Item])
}

/// Lossy element wrapper — a single corrupt/legacy row decodes to `nil` instead of
/// failing the whole array (this is how legacy `type:"cloud"` connection rows are dropped).
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try? c.decode(T.self)
    }
}

/// A JSON list persisted in `UserDefaults`. Every op degrades gracefully — never throws.
final class JSONListStore<Item: Codable & Identifiable>: ListStore where Item.ID == String {
    private let key: String
    private let defaults: UserDefaults
    var didChange: (() -> Void)?

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    func list() -> [Item] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let wrapped = (try? JSONDecoder().decode([Failable<Item>].self, from: data)) ?? []
        return wrapped.compactMap(\.value)
    }

    func get(_ id: String) -> Item? { list().first { $0.id == id } }

    func save(_ item: Item) {
        var items = list()
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
        persist(items)
    }

    func remove(_ id: String) { persist(list().filter { $0.id != id }) }

    func replaceAll(_ items: [Item]) { persist(items) }

    private func persist(_ items: [Item]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(items), defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
        didChange?()
    }
}
