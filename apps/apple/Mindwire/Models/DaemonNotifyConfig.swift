import Foundation

/// Credentials stay in the daemon; reads only report whether a token is present.
struct DaemonNotifyConfig: Decodable {
    let configured: Bool
    let url: String
    let channel: String
    let format: String?
    let hasToken: Bool?
}
