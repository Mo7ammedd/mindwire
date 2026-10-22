import SwiftUI

enum MessagingProvider: String, CaseIterable, Identifiable {
    case slack, telegram, discord, teams
    var id: Self { self }
    var title: String {
        switch self {
        case .slack: "Slack"
        case .telegram: "Telegram"
        case .discord: "Discord"
        case .teams: "Microsoft Teams"
        }
    }
    var summary: String {
        switch self {
        case .slack: "Channels, mentions and direct messages"
        case .telegram: "Private chats and groups"
        case .discord: "Commands in your server"
        case .teams: "Conversations with your team"
        }
    }
    var setupURL: URL { URL(string: "https://mindwire.sh/docs/guides/integrations#\(self == .teams ? "microsoft-teams" : rawValue)")! }
    var portalURL: URL {
        let address = switch self {
        case .slack: "https://api.slack.com/apps"
        case .telegram: "https://t.me/BotFather"
        case .discord: "https://discord.com/developers/applications"
        case .teams: "https://portal.azure.com/"
        }
        return URL(string: address)!
    }
    var channelLabel: String { self == .telegram ? "Chat IDs" : self == .teams ? "Conversation IDs" : "Channel IDs" }
    var workspaceLabel: String { self == .slack ? "Team ID" : self == .discord ? "Server ID" : "Tenant ID" }
    var credentialHint: String {
        switch self {
        case .slack: "Install a Slack app in your workspace. Find its bot token under OAuth & Permissions and signing secret under Basic Information."
        case .telegram: "Create a bot with @BotFather and paste its token. Generate a webhook secret to protect incoming messages."
        case .discord: "Create a Discord application. Find its token under Bot, and its application ID and public key under General Information."
        case .teams: "Use the application ID, tenant ID and client secret from your Microsoft Entra app and Azure Bot."
        }
    }
    var webhookHint: String {
        switch self {
        case .slack: "Set this URL in Slack’s Event Subscriptions. Subscribe to mentions or direct messages and invite your bot to the allowed channels."
        case .telegram: "Register this URL with Telegram’s setWebhook method, using the webhook secret you saved."
        case .discord: "Set this URL as your Interactions Endpoint. Register /mindwire with a string option named message."
        case .teams: "Set this URL as your Azure Bot’s messaging endpoint, then install the bot in Teams."
        }
    }
}

struct MessagingProviderIcon: View {
    let provider: MessagingProvider
    var size: CGFloat = 40

    var body: some View {
        Group {
            if provider == .teams { Image(systemName: "person.2.fill").resizable().scaledToFit() }
            else { Image("integration-\(provider.rawValue)").resizable().scaledToFit() }
        }
        .foregroundStyle(.primary)
        .padding(size * 0.23)
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: size * 0.28))
        .accessibilityHidden(true)
    }
}

enum MessagingMode: String, CaseIterable, Identifiable {
    case chat, commands, trigger, notifications
    var id: Self { self }
    var title: String {
        switch self {
        case .chat: "Chat with this bot"
        case .commands: "Commands only"
        case .trigger: "A new task per message"
        case .notifications: "Updates only"
        }
    }
    var summary: String {
        switch self {
        case .chat: "Continue conversations and receive replies. Discord uses slash commands."
        case .commands: "Only your slash command starts work. Other messages are ignored."
        case .trigger: "Each incoming message starts a separate task."
        case .notifications: "Receive updates. Incoming messages cannot start work."
        }
    }
}
