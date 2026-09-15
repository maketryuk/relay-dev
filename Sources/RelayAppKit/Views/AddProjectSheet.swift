import RelayUI
import SwiftUI
import UniformTypeIdentifiers

/// Adding a project.
///
/// A bare file picker is a poor fit: the folder you want is usually already
/// visible in Finder or in a terminal's title, so dropping it is fewer moves
/// than navigating to it again.
struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var rejected: String?

    var body: some View {
        ModalSurface(relayLocalized("Add Project"), onDismiss: { dismiss() }) {
            dropZone
        } footer: {
            footer
        }
        .frame(width: 480, height: 460)
        .modalPlate()
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                add(urls)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: isTargeted ? "folder.fill.badge.plus" : "folder.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? Theme.Palette.accent : Theme.Palette.textTertiary)

            VStack(spacing: Theme.Spacing.xsmall) {
                Text(isTargeted ? "Drop to add" : "Drag a folder here")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(rejected ?? "Relay reads the git branch, package manager and dev command it finds.")
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(rejected == nil ? Theme.Palette.textTertiary : Theme.Palette.statusError)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RelayButton(relayLocalized("Choose Folder…"), systemImage: "folder", kind: .secondary) {
                isImporting = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.large)
        .background(isTargeted ? Theme.Palette.accentMuted.opacity(0.35) : Theme.Palette.base)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(
                    isTargeted ? Theme.Palette.accent : Theme.Palette.border,
                    style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [] : [5, 4])
                )
                .padding(Theme.Spacing.medium)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.projects.count) project\(model.projects.count == 1 ? "" : "s") in this workspace")
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            RelayButton(relayLocalized("Done"), kind: .primary) { dismiss() }
        }
    }

    // MARK: - Dropping

    private func load(_ providers: [NSItemProvider]) {
        // Providers deliver asynchronously and in any order, so results are
        // collected before anything is added.
        let group = DispatchGroup()
        let box = URLBox()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            add(box.urls)
        }
    }

    private func add(_ urls: [URL]) {
        var directories: [URL] = []
        var sawFile = false

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                directories.append(url)
            } else {
                sawFile = true
            }
        }

        guard !directories.isEmpty else {
            rejected = sawFile ? "That is a file. Drop the folder that contains it." : nil
            return
        }

        rejected = nil
        for directory in directories {
            model.addProject(at: directory)
        }
        dismiss()
    }
}

/// Collects URLs delivered from several providers on arbitrary threads.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.withLock { storage.append(url) }
    }

    var urls: [URL] {
        lock.withLock { storage }
    }
}
