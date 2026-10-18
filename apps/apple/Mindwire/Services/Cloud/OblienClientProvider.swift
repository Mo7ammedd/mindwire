import Foundation
import OblienKit

/// The app's shared Oblien SDK client. It authenticates with the app's anonymous session
/// token (minted via `OblienAPI` / `POST /auth/token`) using the SDK's `.bearerSession` auth,
/// so the existing mint + Keychain + 401-refresh flow is preserved while every workspace /
/// runtime call goes through the typed SDK. Swap the `auth` case to adopt API keys or scoped
/// tokens later with no call-site changes.
enum OblienCloud {
    static let client = OblienClient(
        OblienConfiguration(
            auth: .bearerSession { forceRefresh in
                try await OblienAPI.shared.token(forceRefresh: forceRefresh)
            },
            baseURL: URL(string: AppConstants.oblienAPIBase) ?? URL(string: "https://api.oblien.com")!,
            runtimeURL: URL(string: AppConstants.oblienRuntimeBase) ?? URL(string: "https://workspace.oblien.com")!
        )
    )
}
