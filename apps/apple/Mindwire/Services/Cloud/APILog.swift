import Foundation

/// DEBUG request/response logging for the app's HTTP layers (OblienAPI + direct GitHub REST), so
/// the live Oblien flow is visible in the Xcode console. Filter the console by `🌐`. Token-shaped
/// values are redacted so logs are safe to paste. Compiled out of release builds.
enum APILog {
    #if DEBUG
    static func request(_ req: URLRequest) {
        print("🌐 → \(req.httpMethod ?? "?") \(redact(req.url?.absoluteString ?? "?"))")
    }

    static func response(_ req: URLRequest, status: Int, body: Data) {
        let mark = (200..<300).contains(status) ? "←" : "⚠️"
        var line = "🌐 \(mark) \(status) \(req.httpMethod ?? "?") \(redact(req.url?.absoluteString ?? "?"))"
        if req.url?.absoluteString.removingPercentEncoding?.contains("/.mindwire/daemon.token") == true {
            print(line + " [workspace credential redacted]")
            return
        }
        if !body.isEmpty, let text = String(data: body, encoding: .utf8) {
            line += "\n       " + String(redact(text).prefix(900))
        }
        print(line)
    }

    static func failure(_ req: URLRequest, error: Error) {
        print("🌐 ✗ \(req.httpMethod ?? "?") \(redact(req.url?.absoluteString ?? "?")) — \((error as NSError).localizedDescription)")
    }

    /// Arbitrary debug line (e.g. SDK calls not routed through `perform`).
    static func note(_ message: String) { print("🌐 • \(redact(message))") }

    /// Mask JSON credential fields, JWTs, and GitHub/Oblien token-shaped substrings.
    static func redact(_ s: String) -> String {
        let patterns = [
            (#"(?i)("(?:token|fcm_token|access_token|refresh_token|privateKey|private_key|password)"\s*:\s*")[^"]+(")"#, "$1…$2"),
            (#"(https?://)[^\s/@]+:[^\s/@]+@"#, "$1[REDACTED]@"),
            (#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "[JWT REDACTED]"),
            (#"(ghs_|ghp_|gho_|github_pat_|onp_)[A-Za-z0-9_-]+"#, "$1…")
        ]
        return patterns.reduce(s) { value, item in
            guard let re = try? NSRegularExpression(pattern: item.0) else { return value }
            return re.stringByReplacingMatches(in: value,
                                               range: NSRange(value.startIndex..., in: value),
                                               withTemplate: item.1)
        }
    }
    #else
    static func request(_ req: URLRequest) {}
    static func response(_ req: URLRequest, status: Int, body: Data) {}
    static func failure(_ req: URLRequest, error: Error) {}
    static func note(_ message: String) {}
    #endif
}
