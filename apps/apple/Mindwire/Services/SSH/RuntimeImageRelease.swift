import Foundation

/// GitHub assets and GHCR images can finish publishing at different times. Choose
/// a published, pinned runtime image; the shared installer supplies the requested daemon.
enum RuntimeImageRelease {
    static func version(for target: String, session: URLSession = .shared) async throws -> String {
        let repository = "oblien/mindwire-runtime"
        let authURL = URL(string: "https://ghcr.io/token?service=ghcr.io&scope=repository:\(repository):pull")!
        var request = URLRequest(url: authURL)
        request.timeoutInterval = 20
        let (authData, authResponse) = try await session.data(for: request)
        guard (authResponse as? HTTPURLResponse)?.statusCode == 200 else { throw unavailable }
        struct RegistryAuth: Decodable { let token: String }
        let auth = try JSONDecoder().decode(RegistryAuth.self, from: authData)
        // Prefer the exact release even after the registry grows beyond one tags page.
        request = URLRequest(url: URL(string: "https://ghcr.io/v2/\(repository)/manifests/\(target)")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json",
                         forHTTPHeaderField: "Accept")
        let (_, manifestResponse) = try await session.data(for: request)
        let manifestStatus = (manifestResponse as? HTTPURLResponse)?.statusCode
        if manifestStatus == 200 { return target }
        guard manifestStatus == 404 else { throw unavailable }
        request = URLRequest(url: URL(string: "https://ghcr.io/v2/\(repository)/tags/list?n=1000")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw unavailable }
        struct Tags: Decodable { let tags: [String] }
        guard let version = select(try JSONDecoder().decode(Tags.self, from: data).tags, target: target) else { throw unavailable }
        return version
    }

    static func select(_ versions: [String], target: String) -> String? {
        versions.filter {
            $0.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
                && $0.compare("0.1.15", options: .numeric) != .orderedAscending
                && $0.compare(target, options: .numeric) != .orderedDescending
        }.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    private static var unavailable: BackendError {
        .message("Couldn't find an available Mindwire sandbox image. Check your connection and try again.")
    }
}
