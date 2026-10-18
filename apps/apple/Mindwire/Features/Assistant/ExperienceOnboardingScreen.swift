import SwiftUI

struct ExperienceOnboardingScreen: View {
    @Environment(\.stores) private var stores
    @State private var selection = AppExperienceMode.general

    var body: some View {
        AssistantPage {
            AssistantArtwork()
            AssistantHeading(title: t("experience.welcome"))
            VStack(spacing: 12) {
                ForEach(AppExperienceMode.allCases) { mode in
                    AssistantOption(title: mode.title, detail: mode.detail, icon: mode.icon,
                                    selected: selection == mode) { selection = mode }
                }
            }
        } footer: {
            AssistantPrimaryButton(title: t("common.continue")) { stores.experience.mode = selection }
            Text(t("experience.switchHint"))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
