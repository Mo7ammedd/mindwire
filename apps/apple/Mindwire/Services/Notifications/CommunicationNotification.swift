import Intents
import SwiftUI
import UIKit
import UserNotifications

/// Uses iOS's sender-avatar presentation; the system supplies the small app icon badge.
@MainActor
enum CommunicationNotification {
    static func content(from content: UNNotificationContent) async throws -> UNNotificationContent {
        guard let intent = try intent(for: content) else { return content }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        // The donation must finish before iOS contextualizes the notification.
        try await interaction.donate()
        try Task.checkCancellation()
        return try content.updating(from: intent)
    }

    static func intent(for content: UNNotificationContent) throws -> INSendMessageIntent? {
        let data = PushPayload.data(from: content.userInfo)
        let avatar: INImage
        let senderID: String
        let name: String
        if let appID = data["appId"] as? String, !appID.isEmpty,
           let appName = data["appName"] as? String, !appName.isEmpty {
            avatar = INImage(imageData: try renderAvatar(SavedAppIcon(id: appID, icon: data["appIcon"] as? String, size: 256)))
            senderID = "mindwire.app.\(data["workspaceId"] as? String ?? "").\(appID)"
            name = appName
        } else if let botID = data["botId"] as? String, !botID.isEmpty,
           let botName = data["botName"] as? String, !botName.isEmpty {
            avatar = INImage(imageData: try avatarPNG(botID: botID, icon: data["botIcon"] as? String))
            let workspace = data["workspaceId"] as? String ?? ""
            senderID = "mindwire.bot.\(workspace).\(botID)"
            name = botName
        } else {
            guard let rawID = data["agent"] as? String else { return nil }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { return nil }
            let brand = AgentBrand.resolve(id)
            avatar = INImage(imageData: try avatarPNG(for: brand))
            senderID = "mindwire.harness.\(id)"
            name = brand.name
        }
        let sender = INPerson(personHandle: INPersonHandle(value: senderID, type: .unknown),
                              nameComponents: nil, displayName: name, image: avatar,
                              contactIdentifier: nil, customIdentifier: senderID)
        let conversation = (data["chatId"] ?? data["chat_id"] ?? data["target_id"]) as? String
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                         content: content.body, speakableGroupName: nil,
                                         conversationIdentifier: conversation ?? senderID,
                                         serviceName: nil, sender: sender, attachments: nil)
        intent.setImage(avatar, forParameterNamed: \.sender)
        return intent
    }

    /// Render the same saved character used in the bot list and chat header.
    static func avatarPNG(botID: String, icon: String?) throws -> Data {
        try renderAvatar(AssistantBotAvatar(botId: botID, icon: icon, size: 256))
    }

    private static func renderAvatar<Content: View>(_ view: Content) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let data = renderer.uiImage?.pngData() else { throw AvatarError.renderFailed }
        return data
    }

    /// Asset-catalog vectors must be rasterized before they leave the extension as an INImage.
    /// Keep the original logo transparent and fill the avatar without an added background.
    static func avatarPNG(for brand: AgentBrand, bundle: Bundle = .main) throws -> Data {
        let asset = brand.assetName ?? "agent-custom"
        guard let original = UIImage(named: asset, in: bundle, compatibleWith: nil),
              original.size.width > 0, original.size.height > 0 else {
            throw AvatarError.missingAsset(asset)
        }
        let image = brand.usesTemplate
            ? original.withTintColor(.label, renderingMode: .alwaysOriginal)
            : original.withRenderingMode(.alwaysOriginal)
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let drawingSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(x: (size.width - drawingSize.width) / 2,
                                  y: (size.height - drawingSize.height) / 2,
                                  width: drawingSize.width, height: drawingSize.height))
        }
    }

    private enum AvatarError: Error { case missingAsset(String), renderFailed }
}
