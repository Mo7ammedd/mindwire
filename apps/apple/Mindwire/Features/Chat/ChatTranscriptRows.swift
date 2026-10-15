import Foundation

/// One lazy row per response part, rather than one very tall row for an entire agent run.
/// Command groups disclose separate recycled rows, never a stack of every command's output.
/// The first part retains the message's pagination anchor; prepending pages never renumbers it.
struct ChatTranscriptRow: Identifiable, Equatable {
    struct ID: Hashable {
        let messageID: String
        var partIndex = 0
        var isCommandDetail = false
    }
    enum Content: Equatable {
        case user(String)
        case text(String)
        case part(DaemonMessagePart)
        case commands([DaemonMessagePart], expanded: Bool)
        case status(message: String?, reconnecting: Bool, waiting: Bool, typing: Bool)
    }
    let id: ID
    let message: DaemonMessage?
    let content: Content
    let isLive: Bool
    let isLast: Bool
    var animatesLiveUpdates = false
    var autoExpanded = false
    var toolExpanded = false
    var commandGroupID: ID? = nil
    var startsBlock = false
    var joinsUserAbove = false
    var joinsUserBelow = false
    // Menu availability participates in row equality so recycled cells update
    // when preparation or a running turn finishes, without reloading the feed.
    var canFork = false
    var startsMessage: Bool { id.partIndex == 0 && !id.isCommandDetail }

    static func make(messages: [DaemonMessage], live: LiveTurn?, runID: String?,
                     animatesLiveUpdates: Bool = false, autoExpandedToolIDs: Set<String> = [],
                     expandedCommandGroups: Set<ID> = [], expandedTools: Set<ID> = [],
                     reconnecting: Bool = false, canForkHistory: Bool = false) -> [Self] {
        var rows: [Self] = []

        func appendParts(_ parts: [DaemonMessagePart], messageID: String,
                         message: DaemonMessage?, isLive: Bool) {
            for group in ChatPartGroup.make(parts) {
                let id = ID(messageID: messageID, partIndex: group.startIndex)
                if group.isCommandGroup {
                    let expanded = expandedCommandGroups.contains(id)
                    rows.append(.init(id: id, message: message,
                                      content: .commands(group.parts, expanded: expanded), isLive: isLive,
                                      isLast: group.startIndex + group.parts.count == parts.count,
                                      startsBlock: group.startsBlock))
                    if expanded {
                        for (offset, part) in group.parts.enumerated() {
                            let index = group.startIndex + offset
                            rows.append(.init(id: .init(messageID: messageID, partIndex: index, isCommandDetail: true),
                                              message: message, content: .part(part), isLive: isLive,
                                              isLast: index == parts.count - 1,
                                              toolExpanded: expandedTools.contains(.init(messageID: messageID, partIndex: index, isCommandDetail: true)),
                                              commandGroupID: id))
                        }
                    }
                } else if let part = group.parts.first {
                    if part.kind == .user, let input = part.input {
                        let user = input.message(chatId: message?.chatId ?? "")
                        rows.append(.init(id: .init(messageID: user.id), message: user,
                                          content: .user(user.text), isLive: false, isLast: true,
                                          startsBlock: true,
                                          joinsUserAbove: group.startIndex > 0 && parts[group.startIndex - 1].kind == .user,
                                          joinsUserBelow: group.startIndex + 1 < parts.count && parts[group.startIndex + 1].kind == .user))
                        continue
                    }
                    rows.append(.init(id: id, message: message, content: .part(part), isLive: isLive,
                                      isLast: group.startIndex == parts.count - 1,
                                      animatesLiveUpdates: isLive && animatesLiveUpdates,
                                      autoExpanded: part.tool.map { autoExpandedToolIDs.contains($0.id) } ?? false,
                                      toolExpanded: expandedTools.contains(id),
                                      startsBlock: group.startsBlock))
                }
            }
        }

        func groups(_ left: DaemonMessage, _ right: DaemonMessage) -> Bool {
            guard left.role == .user, right.role == .user else { return false }
            guard let start = RelativeTime.date(left.createdAt), let end = RelativeTime.date(right.createdAt) else { return true }
            return (0...120).contains(end.timeIntervalSince(start))
        }
        for (index, message) in messages.enumerated() {
            if message.role == .user {
                rows.append(.init(id: .init(messageID: message.id), message: message,
                                  content: .user(message.text), isLive: false, isLast: true,
                                  joinsUserAbove: index > 0 && groups(messages[index - 1], message),
                                  joinsUserBelow: index + 1 < messages.count && groups(message, messages[index + 1]),
                                  canFork: canForkHistory && message.canFork == true))
            } else if let parts = message.parts, !parts.isEmpty {
                appendParts(parts, messageID: message.id, message: message, isLive: false)
            } else {
                rows.append(.init(id: .init(messageID: message.id), message: message,
                                  content: .text(message.text), isLive: false, isLast: true))
            }
        }
        if let live {
            let liveID = "live:\(runID ?? "current")"
            appendParts(live.parts, messageID: liveID, message: nil, isLive: true)
            let typing = !live.waitingForInput && live.parts.last?.kind != .text
            if live.statusMessage != nil || reconnecting || live.waitingForInput || typing {
                rows.append(.init(id: .init(messageID: liveID, partIndex: -1), message: nil,
                                  content: .status(message: live.statusMessage, reconnecting: reconnecting,
                                                   waiting: live.waitingForInput, typing: typing),
                                  isLive: true, isLast: true))
            }
        }
        return rows
    }
}
