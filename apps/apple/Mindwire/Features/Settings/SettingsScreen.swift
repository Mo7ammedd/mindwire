// Settings tab — native grouped List: account, appearance, preferences, about.
import SwiftUI

struct SettingsScreen: View {
    @Environment(\.stores) private var stores
    @AppStorage("mindwire.appearance") private var appearance = "system"
    @AppStorage(StorageKey.chatTextSize) private var chatTextSize = ChatTextSize.medium.rawValue
    #if targetEnvironment(macCatalyst)
    @AppStorage("mindwire.desktop.developerTools") private var developerTools = false
    #endif
    private var auth = OblienAuth.shared

    var body: some View {
        List {
            Section(t("settings.section.account")) {
                RootNavigationLink(value: SettingsRoute.account) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accountTitle)
                            Text(accountSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        accountIcon
                    }
                }
            }

            Section(t("settings.section.infrastructure")) {
                RootNavigationLink(value: SettingsRoute.servers) {
                    Label("Computers & Servers", icon: .monitor)
                }
            }

            Section(t("settings.section.integrations")) {
                RootNavigationLink(value: SettingsRoute.github) {
                    Label {
                        Text(t("settings.github"))
                    } icon: {
                        ProviderLogo(id: .github, size: 20)
                    }
                }
            }

            ServiceUpdatesSettingsSection()

            Section(t("settings.appearance")) {
                Picker(t("settings.appearance"), selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker(t("settings.textSize.title"), selection: $chatTextSize) {
                    ForEach(ChatTextSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
            }

            Section(t("settings.preferences")) {
                #if targetEnvironment(macCatalyst)
                Toggle("Developer tools", isOn: $developerTools)
                #endif
                RootNavigationLink(value: SettingsRoute.backupSync) {
                    Label("Backup & Sync", icon: .cloud)
                }
                RootNavigationLink(value: SettingsRoute.notifications) {
                    Label(t("notifications.title"), icon: .bell)
                }
                LabeledContent(t("settings.language"), value: "English")
            }

            Section(t("settings.about")) {
                Link(destination: URL(string: "https://mindwire.sh")!) {
                    HStack {
                        Label {
                            Text("Mindwire")
                        } icon: {
                            AppLogo(size: 28)
                        }
                        Spacer()
                        Text(AppConstants.appVersion).foregroundStyle(.secondary)
                    }
                }
                Link(destination: URL(string: "https://github.com/oblien/mindwire")!) {
                    Label {
                        Text("Source code")
                    } icon: {
                        ProviderLogo(id: .github, size: 20)
                    }
                }
            }
            .tint(.primary)
        }
        .serviceUpdatePresentation()
        .navigationTitle(t("tabs.settings"))
        .principalBrand()
    }

    @ViewBuilder private var accountIcon: some View {
        if let s = auth.user?.image, let url = URL(string: s) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { personIcon }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else if auth.authenticated {
            Avatar(initial: initial, size: 28)
        } else {
            personIcon
        }
    }

    private var personIcon: some View {
        AppIcon(.userCircle).font(.title2).foregroundStyle(.secondary)
    }

    private var initial: String { (auth.user?.name?.first.map(String.init) ?? "?").uppercased() }
    private var accountTitle: String { auth.user?.name ?? t("settings.account") }
    private var accountSubtitle: String {
        auth.authenticated ? (auth.user?.email ?? t("account.signedInAs")) : t("account.notSignedIn")
    }
}
