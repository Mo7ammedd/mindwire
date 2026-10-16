import SwiftUI

struct ExperienceOnboardingScreen: View {
    @Environment(\.stores) private var stores
    @State private var selection = AppExperienceMode.general

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        AppLogo(size: 48)
                        Text(t("experience.welcome")).font(.largeTitle.bold())
                        Text(t("experience.choose")).font(.title3).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.lg)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(AppExperienceMode.allCases) { mode in
                        Button { selection = mode } label: {
                            HStack(alignment: .top, spacing: Spacing.md) {
                                AppIcon(mode.icon, size: 24).padding(.top, 2)
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(mode.title).font(.headline)
                                    Text(mode.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if selection == mode { AppIcon(.check).foregroundStyle(Palette.accent) }
                            }
                            .padding(.vertical, Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(selection == mode ? .isSelected : [])
                    }
                } footer: {
                    Text(t("experience.switchHint"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(t("common.continue")) { stores.experience.mode = selection }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(Palette.accent)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
