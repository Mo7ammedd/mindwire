// Settings tab — native grouped List: account, appearance, preferences, about.
import SwiftUI

struct SettingsScreen: View {
    @Environment(\.stores) private var stores
    @Environment(\.appExperienceMode) private var experienceMode
    @AppStorage("mindwire.appearance") private var appearance = "system"
    @AppStorage(StorageKey.chatTextSize) private var chatTextSize = ChatTextSize.medium.rawValue
    @State private var showingAssistantSetup = false
    private var auth = OblienAuth.shared

    var body: some View {
        List {
            #if !targetEnvironment(macCatalyst)
            Section {
                Picker(t("experience.mode"), selection: Binding(
                    get: { stores.experience.mode ?? .general },
                    set: { stores.experience.mode = $0 }
                )) {
                    ForEach(AppExperienceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
            } footer: {
                Text(t("experience.switchHint"))
            }
            #endif
            if experienceMode == .general {
                Section {
                    Button { showingAssistantSetup = true } label: {
                        Label(t("assistant.connection"), icon: .monitor)
                    }
                    .tint(.primary)
                } footer: {
                    Text(t("assistant.connection.hint"))
                }
            }
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

            if experienceMode == .developer {
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
            }

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
        .sheet(isPresented: $showingAssistantSetup) {
            AssistantSetupScreen { showingAssistantSetup = false }
        }
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
