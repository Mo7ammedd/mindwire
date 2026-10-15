#if DEBUG
import SwiftUI
import WebKit

/// A real, locally rendered demo website supplies the pixels for the production desktop viewer.
/// No tunnel, login, or real computer is touched by screenshot automation.
@MainActor
final class AppStoreDesktopPage: NSObject, WKNavigationDelegate {
    private let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
    private var completion: CheckedContinuation<Void, Error>?

    func image() async throws -> CGImage {
        browser.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completion = continuation
            browser.loadHTMLString(Self.html, baseURL: nil)
        }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1_440
        let snapshot = try await browser.takeSnapshot(configuration: config)
        guard let image = snapshot.cgImage else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume(); completion = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }

    private static let html = #"""
    <!doctype html><html lang="en"><meta name="viewport" content="width=1440, initial-scale=1">
    <style>
    *{box-sizing:border-box}body{margin:0;background:#15171c;color:#f4f2ec;font:16px -apple-system,BlinkMacSystemFont,sans-serif}
    .browser{height:58px;background:#202228;display:flex;align-items:center;gap:9px;padding:0 22px;border-bottom:1px solid #35373c}
    .dot{height:11px;width:11px;border-radius:50%;background:#fe6158}.dot:nth-child(2){background:#fcbf4b}.dot:nth-child(3){background:#35c94a}
    .address{height:31px;border-radius:8px;background:#303239;width:640px;text-align:center;margin:auto;color:#b8bac0;font-size:13px;padding:8px}
    .shell{display:grid;grid-template-columns:230px 1fr;height:842px}.sidebar{padding:32px 20px;border-right:1px solid #2b2d33}
    .brand{font-size:26px;font-weight:650;letter-spacing:-1px;display:flex;align-items:center;gap:12px;margin:0 12px 48px}
    .orb{display:inline-block;width:30px;height:30px;border:7px solid #eb9272;border-radius:50%}.nav{padding:15px 16px;color:#94969e;display:flex;align-items:center;gap:14px;font-size:15px}
    .nav.selected{background:#2b2828;color:#edab90;border-radius:10px}.tiny{width:15px;height:15px;border:1.5px solid currentColor;border-radius:4px}
    .caption{color:#686c76;font-size:10px;font-weight:700;letter-spacing:2px;margin:36px 16px 10px}.workspace{position:absolute;bottom:30px;left:30px;display:flex;gap:12px;align-items:center;font-size:13px}.avatar{background:#61697c;border-radius:8px;width:34px;height:34px;display:grid;place-items:center}.muted{color:#8c9099}
    main{padding:34px 46px}.top{display:flex;align-items:center;justify-content:space-between;font-size:13px;color:#9396a0}
    .live{color:#a9c497;display:flex;align-items:center;gap:8px}.live:before{content:'';height:6px;width:6px;border-radius:50%;background:#a9c497}
    .welcome{display:flex;justify-content:space-between;align-items:center;margin:37px 0 31px}h1{font-size:37px;line-height:1.1;font-weight:580;letter-spacing:-1.5px;margin:0 0 12px}p{color:#969aa5;margin:0;font-size:15px}
    .button{border:1px solid #474343;border-radius:9px;color:#f0d0bf;font-size:13px;padding:13px 19px;background:#322a28}
    .stats{display:grid;grid-template-columns:repeat(3,1fr);gap:19px}.card{background:#1e2026;border:1px solid #303238;border-radius:15px;padding:25px}.label{font-size:13px;color:#9ca0a9}.value{font-size:36px;letter-spacing:-1px;margin-top:16px;display:flex;align-items:baseline;gap:15px}.change{font-size:12px;letter-spacing:0;color:#b1cb97}.bar{height:3px;background:#34363e;margin-top:23px;border-radius:5px}.bar span{display:block;height:100%;background:#c3947c;border-radius:5px}
    .panels{display:grid;grid-template-columns:1.52fr 1fr;gap:19px;margin-top:22px}h2{font-size:17px;font-weight:550;margin:0 0 8px}.sub{font-size:12px;color:#7f8490}.chart{height:230px;margin-top:24px;position:relative;overflow:hidden}.gridline{position:absolute;border-bottom:1px solid #30323a;width:100%}.day{display:flex;justify-content:space-between;font-size:10px;color:#707683;padding-top:9px}
    .activity{display:flex;gap:12px;padding:20px 0;border-bottom:1px solid #2f3137;font-size:13px}.activity:last-child{border:0}.check{flex:none;color:#b0c596;background:#2e3730;width:27px;height:27px;border-radius:50%;display:grid;place-items:center;font-size:12px}.activity small{display:block;color:#7b818d;margin-top:6px;font-size:11px}.activity time{margin-left:auto;white-space:nowrap;color:#717785;font-size:11px;padding-top:4px}
    .footer{display:flex;justify-content:space-between;color:#696e79;font-size:11px;margin-top:24px}
    </style>
    <div class="browser"><i class="dot"></i><i class="dot"></i><i class="dot"></i><div class="address">localhost:3000 / dashboard</div></div>
    <div class="shell"><aside class="sidebar"><div class="brand"><i class="orb"></i>orbit</div>
    <div class="nav selected"><i class="tiny"></i>Overview</div><div class="nav"><i class="tiny"></i>Projects</div><div class="nav"><i class="tiny"></i>Activity</div><div class="nav"><i class="tiny"></i>Insights</div>
    <div class="caption">YOUR WORKSPACE</div><div class="nav">Team</div><div class="nav">Settings</div>
    <div class="workspace"><div class="avatar">A</div><div>Alex Morgan<br><span class="muted" style="font-size:11px">Personal workspace</span></div></div></aside>
    <main><div class="top"><span>Workspace / Overview</span><span class="live">All systems running</span></div>
    <div class="welcome"><div><h1>A little clarity.<br>A lot of progress.</h1><p>Everything you're building, in one place.</p></div><div class="button">Create project &nbsp; +</div></div>
    <div class="stats"><div class="card"><div class="label">Active projects</div><div class="value">12<span class="change">+3 this week</span></div><div class="bar"><span style="width:72%"></span></div></div>
    <div class="card"><div class="label">Tasks completed</div><div class="value">248<span class="change">+18.6%</span></div><div class="bar"><span style="width:88%;background:#acbd8d"></span></div></div>
    <div class="card"><div class="label">Focus time</div><div class="value">32.5<span style="font-size:18px;color:#9b9fa8">hours</span></div><div class="bar"><span style="width:64%;background:#959cca"></span></div></div></div>
    <div class="panels"><section class="card"><h2>Small steps. Steady momentum.</h2><div class="sub">Your activity over the last seven days</div>
    <div class="chart"><div class="gridline" style="top:15%"></div><div class="gridline" style="top:45%"></div><div class="gridline" style="top:75%"></div>
    <svg viewBox="0 0 560 230" preserveAspectRatio="none" width="100%" height="100%"><defs><linearGradient id="fade" x1="0" x2="0" y1="0" y2="1"><stop stop-color="#df9a79" stop-opacity=".22"/><stop offset="1" stop-color="#df9a79" stop-opacity="0"/></linearGradient></defs><path d="M0 180C45 180 50 120 100 138S170 183 215 110S260 115 310 83S365 125 415 53S480 77 510 31S545 16 560 18V230H0Z" fill="url(#fade)"/><path d="M0 180C45 180 50 120 100 138S170 183 215 110S260 115 310 83S365 125 415 53S480 77 510 31S545 16 560 18" fill="none" stroke="#df9a79" stroke-width="3"/></svg></div><div class="day"><span>MON</span><span>TUE</span><span>WED</span><span>THU</span><span>FRI</span><span>SAT</span><span>SUN</span></div></section>
    <section class="card"><h2>Latest activity</h2><div class="sub">The details that move things forward</div>
    <div class="activity"><span class="check">✓</span><div>Dashboard ready for review<small>Orbit · feature/dashboard</small></div><time>now</time></div>
    <div class="activity"><span class="check">✓</span><div>All 24 checks passed<small>Tests · no issues found</small></div><time>2m</time></div>
    <div class="activity"><span class="check">✓</span><div>Activity feed added<small>Orbit · 42 lines</small></div><time>4m</time></div>
    <div class="activity"><span class="check">✓</span><div>Workspace connected<small>Cloud Studio</small></div><time>8m</time></div></section></div>
    <div class="footer"><span>Built with a little help from your agents.</span><span>Orbit · Your space to build.</span></div>
    </main></div></html>
    """#
}

@MainActor
final class StoreDesktopProvider: WorkspaceDesktopProvider {
    func status() async throws -> DesktopProviderStatus { .init(supported: true, enabled: true, available: true, credentials: false) }
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        try await api.decode("GET", "/surfaces/desktop", quiet: true)
    }
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        .init(port: 1, cleanup: {})
    }
}

final class StoreDesktopViewer: DesktopViewing {
    var onFrame: ((DesktopDisplayFrame) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    var onCursor: ((DesktopCursorShape, TimeInterval) -> Void)?
    private let image: CGImage
    init(image: CGImage) { self.image = image }
    func connect(port: Int, settings: DesktopStreamSettings, debugLogging: Bool) { onState?(true, nil); requestFreshFrame() }
    func disconnect() { }
    func setFrameRate(_ value: Int) { }
    func requestFreshFrame() {
        onFrame?(.init(image: image, sourceSize: .init(width: 1_440, height: 900), requestedAt: ProcessInfo.processInfo.systemUptime))
    }
}
#endif
