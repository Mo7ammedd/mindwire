import SwiftUI

struct ProjectSyncFileReviewScreen: View {
    let review: ProjectSyncFileReview
    @State private var addingPath = false
    @State private var path = ""

    var body: some View {
        Form {
            Section {
                if let preview = review.preview {
                    LabeledContent(t("project.transfer.files.workingFiles"), value: String(preview.fileCount))
                    LabeledContent(t("project.transfer.files.size"), value: ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file))
                }
                if review.loading {
                    HStack {
                        Text(t("project.transfer.files.checking")).foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            } footer: { Text(t("project.transfer.files.sizeHelp")) }

            if let error = review.error {
                Section {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button(t("common.retry")) { review.refresh() }
                }
            }

            if let preview = review.preview {
                Section {
                    if preview.ignored.isEmpty {
                        Text(t("project.transfer.files.noIgnored")).foregroundStyle(.secondary)
                    }
                    ForEach(preview.ignored) { item in
                        Toggle(isOn: Binding(get: { review.includes(item.path) }, set: { review.setIncluded(item.path, $0) })) {
                            HStack(spacing: Spacing.md) {
                                AppIcon(item.kind == "directory" ? .folder : .file).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(item.path).lineLimit(2).truncationMode(.middle)
                                    if review.partiallyIncludes(item.path) {
                                        Text(t("project.transfer.files.partial")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .tint(Palette.accent)
                        .accessibilityIdentifier("project.transfer.include." + item.path)
                    }
                    if let next = preview.next, next > 0 {
                        Button { Task { await review.loadMore() } } label: {
                            HStack {
                                Text(t("project.transfer.files.showMore"))
                                if review.loadingMore { Spacer(); ProgressView().controlSize(.small) }
                            }
                        }.disabled(review.loading || review.loadingMore)
                    }
                } header: {
                    Text(t("project.transfer.files.ignored", ["count": String(preview.ignoredCount)]))
                } footer: {
                    Text(t("project.transfer.files.ignoredHelp"))
                }
            }

            Section {
                ForEach(review.customPaths, id: \.self) { path in
                    Toggle(path, isOn: Binding(get: { review.includes(path) }, set: { review.setIncluded(path, $0) }))
                        .tint(Palette.accent)
                }
                Button(t("project.transfer.files.includePath")) { path = ""; addingPath = true }
            } footer: { Text(t("project.transfer.files.pathHelp")) }
        }
        .navigationTitle(t("project.transfer.files.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) {
                Button { review.refresh() } label: { AppIcon(.refresh) }
                    .disabled(review.loading)
                    .accessibilityLabel(t("project.transfer.files.refresh"))
            }
        }
        .inputDialog(titleKey: "project.transfer.files.includePath", isPresented: $addingPath,
                     text: $path, placeholder: ".env or cache/fixtures", confirmKey: "project.transfer.files.include") {
            let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { review.setIncluded(value, true) }
        }
    }
}
