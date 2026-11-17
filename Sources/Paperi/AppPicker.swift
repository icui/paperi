import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An application that can be offered wherever settings expect a bundle ID.
struct AppEntry: Identifiable, Hashable, Sendable {
    let name: String
    let bundleID: String
    let path: String
    var running = false
    var id: String { bundleID }
}

/// Running and installed applications, gathered once and refreshed whenever a
/// picker opens so newly launched apps appear without restarting Settings.
@MainActor final class AppCatalog: ObservableObject {
    static let shared = AppCatalog()
    @Published private(set) var apps: [AppEntry] = []
    private var installed: [AppEntry] = []
    private var scanning = false

    nonisolated private static let folders: [String] = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]
    nonisolated private static let extras = ["/System/Library/CoreServices/Finder.app"]

    func refresh() {
        merge()
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = Self.scan()
            await MainActor.run {
                self.installed = found
                self.scanning = false
                self.merge()
            }
        }
    }

    private func merge() {
        var byID: [String: AppEntry] = [:]
        for app in installed { byID[app.bundleID] = app }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let id = running.bundleIdentifier else { continue }
            let path = running.bundleURL?.path ?? byID[id]?.path ?? ""
            let name = byID[id]?.name ?? running.localizedName ?? id
            byID[id] = AppEntry(name: name, bundleID: id, path: path, running: true)
        }
        apps = byID.values.sorted {
            if $0.running != $1.running { return $0.running }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var paths = extras
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            paths += names.filter { $0.hasSuffix(".app") }.map { folder + "/" + $0 }
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let entry = entry(at: URL(fileURLWithPath: path)), seen.insert(entry.bundleID).inserted else { return nil }
            return entry
        }
    }

    nonisolated static func entry(at url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return AppEntry(name: name, bundleID: id, path: url.path)
    }
}

/// A compact button that opens a searchable list of applications. Picking one
/// hands its bundle ID to `onPick`; "Other…" chooses any .app from disk.
struct AppPickerButton: View {
    var title = "Choose App…"
    var excluded: Set<String> = []
    let onPick: (String) -> Void
    @StateObject private var state = PickerState()

    var body: some View {
        Button {
            state.presented.toggle()
        } label: {
            Label(title, systemImage: "app.badge.checkmark")
        }
        .help("Pick an application to fill in its bundle ID")
        .popover(isPresented: $state.presented, arrowEdge: .bottom) {
            AppPickerList(excluded: excluded) { id in
                state.presented = false
                onPick(id)
            }
        }
    }
}

@MainActor private final class PickerState: ObservableObject {
    @Published var presented = false
    @Published var query = ""
}

private struct AppPickerList: View {
    let excluded: Set<String>
    let onPick: (String) -> Void
    @ObservedObject private var catalog = AppCatalog.shared
    @StateObject private var state = PickerState()
    @FocusState private var searchFocused: Bool

    private var matches: [AppEntry] {
        let q = state.query.trimmingCharacters(in: .whitespaces)
        return catalog.apps.filter {
            q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search by name or bundle ID", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = matches.first(where: { !excluded.contains($0.bundleID) }) { onPick(first.bundleID) } }
                .padding(10)
            Divider()
            if matches.isEmpty {
                Text(catalog.apps.isEmpty ? "Loading applications…" : "No matching applications")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches) { app in
                    let added = excluded.contains(app.bundleID)
                    Button { onPick(app.bundleID) } label: { AppRow(app: app, added: added) }
                        .buttonStyle(.plain)
                        .disabled(added)
                }
                .listStyle(.plain)
            }
            Divider()
            HStack {
                Text("Running apps are listed first.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Other…", action: browse)
            }
            .padding(10)
        }
        .frame(width: 380, height: 420)
        .onAppear { catalog.refresh(); searchFocused = true }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let entry = AppCatalog.entry(at: url) { onPick(entry.bundleID) } else { NSSound.beep() }
    }
}

private struct AppRow: View {
    let app: AppEntry
    let added: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.path.isEmpty ? NSWorkspace.shared.icon(for: .applicationBundle) : NSWorkspace.shared.icon(forFile: app.path))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if added {
                Image(systemName: "checkmark").foregroundStyle(.secondary).help("Already added")
            } else if app.running {
                Circle().fill(.green).frame(width: 6, height: 6).help("Running")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
