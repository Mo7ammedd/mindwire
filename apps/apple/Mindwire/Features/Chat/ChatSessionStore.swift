import Foundation
import Observation
import UIKit

/// A bounded, in-memory cache of daemon-backed conversations. A screen owns visibility;
/// the cache owns initial reads, so leaving and reopening shares the same request and data.
@MainActor
@Observable
final class ChatSessionStore {
    private var models: [String: ChatModel] = [:]
    @ObservationIgnored private weak var stores: Stores?
    @ObservationIgnored private var recency: [String: Int] = [:]
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?
    private let capacity: Int
    private let byteLimit: Int
    private let makeModel: ((String) -> ChatModel)?

    init(stores: Stores, capacity: Int = 6, byteLimit: Int = 32 * 1_024 * 1_024,
         makeModel: ((String) -> ChatModel)? = nil) {
        self.stores = stores
        self.capacity = capacity
        self.byteLimit = byteLimit
        self.makeModel = makeModel
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.trim(allInactive: true) }
        }
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    func cached(_ chatId: String) -> ChatModel? { models[chatId] }

    func model(for chatId: String) -> ChatModel {
        clock += 1
        recency[chatId] = clock
        if let model = models[chatId] { return model }
        let model = makeModel?(chatId) ?? ChatModel(chatId: chatId)
        if let stores { model.bind(chat: stores.chats.get(chatId), stores: stores) }
        model.cacheDidChange = { [weak self] in self?.trim() }
        models[chatId] = model
        trim(keeping: chatId)
        return model
    }

    func remove(_ chatId: String) {
        let model = models.removeValue(forKey: chatId)
        recency[chatId] = nil
        model?.discardCachedHistory()
    }

    func trim(allInactive: Bool = false, keeping: String? = nil) {
        var bytes = models.values.reduce(0) { $0 + $1.cachedHistoryBytes }
        for id in models.keys.sorted(by: { recency[$0, default: 0] < recency[$1, default: 0] }) {
            guard allInactive || models.count > capacity || bytes > byteLimit else { break }
            guard id != keeping, let model = models[id], !model.isRetainedForWork else { continue }
            bytes -= model.cachedHistoryBytes
            remove(id)
        }
    }
}
