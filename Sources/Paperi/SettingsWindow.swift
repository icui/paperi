import AppKit
import SwiftUI
import CoreFoundation
import PaperiPlatform

/// Edits the on-disk layer, preserving keys that this version does not know.
@MainActor final class SettingsModel: ObservableObject {
    @Published var values: [String: Any] = [:]
    @Published var error = ""
    @Published var loginEnabled = LoginAgent.isEnabled
    @Published var textDrafts: [String: String] = [:]
    @Published var dirty = false
    @Published var category = "Layout"
    @Published var gestureTab = "General"
    @Published var search = ""
    @Published var newKey = ""
    @Published var newCommand = ""
    private var original: Data?
    let defaults: [String: Any]
    let apply: () -> [String: Any]

    init(apply: @escaping () -> [String: Any]) {
        self.apply = apply
        var d = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(LiveConfig()))) as? [String: Any] ?? [:]
        d["gap"] = 8; d["outerGap"] = 8; d["focusScrollDuration"] = 0.22
        d["autoCenter"] = true; d["autoCenterThreshold"] = 0.75
        d["swapHighlight"] = LiveConfig.defaultSwapHighlight
        defaults = d
        load()
    }
    func load() {
        do {
            original = try Data(contentsOf: LiveConfig.defaultURL)
            _ = try JSONDecoder().decode(LiveConfig.self, from: original!)
            values = try JSONSerialization.jsonObject(with: original!) as? [String: Any] ?? [:]
            if values["bottomDotsVisibility"] == nil, values["bottom"] != nil,
               let config = try? JSONDecoder().decode(LiveConfig.self, from: original!) {
                values["bottomDotsVisibility"] = config.bottomDotsVisibility.rawValue
            }
            values.removeValue(forKey: "bottom")
            error = ""; dirty = false
        } catch {
            if !FileManager.default.fileExists(atPath: LiveConfig.defaultURL.path) {
                original = nil; values = [:]; self.error = ""; dirty = false
            } else { self.error = "Could not read config: \(error.localizedDescription)" }
        }
    }
    func value(_ key: String, in object: [String: Any]) -> Any? {
        let parts = key.split(separator: ".").map(String.init)
        if parts.count == 2 { return (object[parts[0]] as? [String: Any])?[parts[1]] }
        return object[key]
    }
    func get(_ key: String) -> Any? { value(key, in: values) ?? value(key, in: defaults) }
    func set(_ key: String, _ value: Any?) {
        let parts = key.split(separator: ".").map(String.init)
        if parts.count == 2 {
            var group = values[parts[0]] as? [String: Any] ?? [:]
            group[parts[1]] = value; values[parts[0]] = group
        } else { values[key] = value }
        textDrafts.removeValue(forKey: key)
        dirty = true
    }
    func modified(_ key: String) -> Bool {
        let a = get(key) ?? NSNull(), b = value(key, in: defaults) ?? NSNull()
        return !NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
    }
    func save() {
        do {
            let current = try? Data(contentsOf: LiveConfig.defaultURL)
            guard current == original else { error = "The JSON file changed. Reopen Settings to load it before saving."; return }
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            let config = try JSONDecoder().decode(LiveConfig.self, from: data)
            let errors = HotKeyBindings.resolve(overrides: config.hotkeys).errors
            guard errors.isEmpty else { error = errors.joined(separator: "\n"); return }
            try FileManager.default.createDirectory(at: LiveConfig.defaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: LiveConfig.defaultURL, options: .atomic)
            original = data; dirty = false
            let reply = apply()
            error = reply["ok"] as? Bool == true ? "" : (reply["error"] as? String ?? "Could not apply settings")
        } catch { self.error = String(describing: error) }
    }
}

@MainActor final class SettingsWindow: NSWindowController {
    init(apply: @escaping () -> [String: Any], openJSON: @escaping () -> Void) {
        let view = SettingsView(model: SettingsModel(apply: apply), openJSON: openJSON)
        // Configure the chrome before hosting SwiftUI so we preserve the split
        // view's toolbar and sidebar integration with the system window style.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Paperi Settings"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Keep SwiftUI in charge of the floating sidebar and toolbar. A transparent
/// native view consumes divider interaction without replacing its delegate.
private struct NonresizableSettingsSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarDividerAnchor { SidebarDividerAnchor() }
    func updateNSView(_ view: SidebarDividerAnchor, context: Context) { view.scheduleInstallation() }
    static func dismantleNSView(_ view: SidebarDividerAnchor, coordinator: ()) { view.removeBlocker() }
}

private final class SidebarDividerAnchor: NSView {
    private var blocker: SidebarDividerBlocker?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeBlocker() } else { scheduleInstallation() }
    }

    func scheduleInstallation() {
        DispatchQueue.main.async { [weak self] in self?.installBlocker() }
    }

    func removeBlocker() {
        blocker?.removeFromSuperview()
        blocker = nil
    }

    private func installBlocker() {
        guard window != nil, blocker == nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical,
               let sidebar = split.arrangedSubviews.first, let container = split.superview {
                let blocker = SidebarDividerBlocker()
                blocker.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(blocker, positioned: .above, relativeTo: split)
                NSLayoutConstraint.activate([
                    blocker.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: split.dividerThickness / 2),
                    blocker.widthAnchor.constraint(equalToConstant: 12),
                    blocker.topAnchor.constraint(equalTo: split.topAnchor),
                    blocker.bottomAnchor.constraint(equalTo: split.bottomAnchor)
                ])
                self.blocker = blocker
                return
            }
            ancestor = view.superview
        }
    }
}

private final class SidebarDividerBlocker: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

private struct Setting: Identifiable {
    let id: String
    let title: String
    let detail: String
    var choices: [String] = []
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let openJSON: () -> Void
    private let gestureTabs = ["General", "Swipe Up", "Swipe Down", "Sensitivity"]
    private let categories = ["Layout", "Appearance", "Applications", "Gestures", "Shortcuts", "General"]
    private var settings: [(String, [Setting])] { [
        ("Layout", [Setting(id: "gap", title: "Window gap", detail: "Space between columns and stacked windows, in points."),
                    Setting(id: "outerGap", title: "Outer gap", detail: "Space around the layout, in points."),
                    Setting(id: "gapResize", title: "Gap resize", detail: "Drag the gap between two windows to resize both. A handle appears while the pointer is over the gap."),
                    Setting(id: "focusAfterClose", title: "Focus after close", detail: "Where focus moves when a tiled window closes.", choices: ["left", "right", "system"]),
                    Setting(id: "autoCenter", title: "Auto center", detail: "Center a sole column or a wide focused column, except at either end of the strip."),
                    Setting(id: "autoCenterThreshold", title: "Auto center threshold", detail: "Fraction of usable display width (0–1, excluding 0). Default: 0.75."),
                    Setting(id: "focusScrollDuration", title: "Focus animation", detail: "Duration in seconds (0–1). Use 0 to disable.")]),
        ("Appearance", [Setting(id: "bottomDotsVisibility", title: "Bottom dots visibility", detail: "Auto shows dots during horizontal swipes and briefly after the animation finishes.", choices: ["visible", "hidden", "auto"]),
                        Setting(id: "swapHighlight", title: "Swap highlight", detail: "Drag preview color: #RRGGBB or #RRGGBBAA.")]),
        ("Applications", [Setting(id: "include", title: "Managed applications", detail: "App bundle IDs, one per line. Empty means all regular apps."),
                          Setting(id: "exclude", title: "Excluded applications", detail: "App bundle IDs to skip, one per line."),
                          Setting(id: "singleton", title: "Singleton applications", detail: "App bundle IDs whose in-content tabs are treated as plain windows."),
                          Setting(id: "strictTabDetection", title: "Strict tab detection", detail: "App bundle IDs whose windows wait for complete native-tab evidence, as before the ribbon/empty-role rules. Use if an app's native tabs end up in separate columns. * applies to all apps."),
                          Setting(id: "float", title: "Floating windows", detail: "Match an app bundle ID and optionally part of its window title."),
                          Setting(id: "tile", title: "Additional tiled windows", detail: "Allow matching windows without a fullscreen button to tile.")]),
        ("Gestures", [Setting(id: "gesture.enabled", title: "Enable gestures", detail: "Navigate and manage windows with trackpad gestures."),
                      Setting(id: "gesture.fingers", title: "Fingers", detail: "Number of fingers used for gestures.", choices: ["3", "4"]),
                      Setting(id: "gesture.snapshotStyle", title: "Snapshot style", detail: "Appearance of windows during gestures.", choices: ["native", "simple"]),
                      Setting(id: "gesture.travel", title: "Vertical travel", detail: "Fraction of trackpad height for a full gesture (0–1)."),
                      Setting(id: "gesture.columnTravel", title: "Column travel", detail: "Fraction of trackpad width for a full column (0–1)."),
                      Setting(id: "gesture.commitThreshold", title: "Commit threshold", detail: "Progress required to commit a gesture (0–1)."),
                      Setting(id: "gesture.flickVelocity", title: "Flick velocity", detail: "Speed threshold for committing a quick flick."),
                      Setting(id: "gesture.invert", title: "Invert navigation", detail: "Reverse horizontal navigation."),
                      Setting(id: "gesture.swipeUpMode", title: "Swipe up mode", detail: "Window Animation closes the focused window. Directional Commands uses the assignments below.", choices: ["animation", "commands"]),
                      Setting(id: "gesture.tabCloseApps", title: "Close tabs in applications", detail: "In Window Animation mode, swipe up closes the current tab in these apps. App bundle IDs, one per line."),
                      Setting(id: "gesture.swipeUp", title: "Swipe up", detail: "Command for an upward swipe.", choices: actions),
                      Setting(id: "gesture.swipeUpRight", title: "Swipe up, then right", detail: "Command after turning right.", choices: actions),
                      Setting(id: "gesture.swipeUpLeft", title: "Swipe up, then left", detail: "Command after turning left.", choices: actions),
                      Setting(id: "gesture.swipeDownMode", title: "Swipe down mode", detail: "Window Animation minimizes the focused window. Directional Commands uses the assignments below.", choices: ["animation", "commands"]),
                      Setting(id: "gesture.swipeDown", title: "Swipe down", detail: "Action for a downward swipe.", choices: actions),
                      Setting(id: "gesture.swipeDownRight", title: "Swipe down, then right", detail: "Action after turning right.", choices: actions),
                      Setting(id: "gesture.swipeDownLeft", title: "Swipe down, then left", detail: "Action after turning left.", choices: actions),
                      Setting(id: "gesture.swipeDownApp", title: "Open application", detail: "App bundle ID shared by all openApp actions."),
                      Setting(id: "gesture.tap", title: "Tap", detail: "Action for a quick multi-finger tap.", choices: ["tray", "none"])])
    ] }
    /// Settings whose entries are app bundle IDs, one per line.
    private static let appListFields: Set<String> = ["include", "exclude", "singleton", "strictTabDetection", "gesture.tabCloseApps"]
    private var actions: [String] { ["newWindow", "closeTab", "minimize", "openApp", "none"] }
    private var categoryIcons: [String: String] {
        ["Layout": "rectangle.split.3x1", "Appearance": "paintpalette", "Applications": "app.badge",
         "Gestures": "hand.draw", "Shortcuts": "keyboard", "General": "gearshape"]
    }
    private var selection: Binding<String?> {
        Binding(get: { model.category }, set: { category in
            guard let category else { return }
            model.category = category
            model.search = ""
        })
    }
    private func visibleFields(in category: String, fields: [Setting]) -> [Setting] {
        fields.filter {
            model.search.isEmpty ? category == model.category :
                "\(category) \($0.title) \($0.id) \($0.detail)".localizedCaseInsensitiveContains(model.search)
        }
    }
    private var showsShortcuts: Bool {
        model.search.isEmpty ? model.category == "Shortcuts" :
            "shortcuts hotkeys keyboard".localizedCaseInsensitiveContains(model.search)
    }
    private var showsGeneral: Bool {
        model.search.isEmpty ? model.category == "General" :
            "general start at login".localizedCaseInsensitiveContains(model.search)
    }
    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(categories, id: \.self) { category in
                    Label(category, systemImage: categoryIcons[category] ?? "gearshape")
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .toolbar(removing: .sidebarToggle)
            .searchable(text: $model.search, prompt: "Search settings")
            // Keep the sidebar fixed rather than letting the split view choose a width.
            .frame(width: 180)
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
            .background(NonresizableSettingsSidebar())
        } detail: {
            Form {
                ForEach(settings, id: \.0) { category, fields in
                    let visible = visibleFields(in: category, fields: fields)
                    if !visible.isEmpty {
                        if category == "Gestures" && model.search.isEmpty {
                            gestureSettings(visible)
                        } else {
                            Section(category) {
                                ForEach(visible) { field in row(field) }
                            }
                        }
                    }
                }
                if showsShortcuts { shortcuts }
                if showsGeneral {
                    Section {
                        Toggle("Start at Login", isOn: Binding(get: { model.loginEnabled }, set: { enabled in
                            let reply = LoginAgent.command([enabled ? "on" : "off"])
                            model.loginEnabled = LoginAgent.isEnabled
                            if reply["ok"] as? Bool != true { model.error = reply["error"] as? String ?? "Could not update Start at Login" }
                        }))
                    } header: {
                        Text("General")
                    } footer: {
                        Text("Settings saved here apply to the JSON configuration. Launch flags can override application lists and runtime options.")
                    }
                }
                if !model.search.isEmpty && !showsShortcuts && !showsGeneral &&
                    settings.allSatisfy({ visibleFields(in: $0.0, fields: $0.1).isEmpty }) {
                    ContentUnavailableView.search(text: model.search)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.search.isEmpty ? model.category : "Search Results")
            .toolbar {
                ToolbarItem {
                    Button(action: openJSON) {
                        Label("Open config.json…", systemImage: "doc.text")
                    }
                    .help("Open config.json…")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Text(model.error.isEmpty ? (model.dirty ? "Unsaved changes" : "Settings are up to date") : model.error)
                        .font(.caption).foregroundStyle(model.error.isEmpty ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                    Spacer()
                    if settings.flatMap({ $0.1 }).contains(where: { model.modified($0.id) }) || model.modified("hotkeysEnabled") || !(model.values["hotkeys"] as? [String: Any] ?? [:]).isEmpty {
                        Button("Restore All Defaults") { model.values = [:]; model.textDrafts = [:]; model.dirty = true }
                    }
                    Button("Apply Changes") { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!model.dirty)
                }
                .padding()
                .background(.bar)
            }
        }
    }
    @ViewBuilder private func gestureSettings(_ fields: [Setting]) -> some View {
        Section {
            Picker("Gesture settings", selection: $model.gestureTab) {
                ForEach(gestureTabs, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if model.gestureTab == "General" {
            gestureSection("Trackpad", ids: ["enabled", "fingers", "tap"], fields: fields)
            gestureSection("Navigation and Appearance", ids: ["invert", "snapshotStyle"], fields: fields)
            gestureSection("Shared Command Options", ids: ["swipeDownApp"], fields: fields)
        } else if model.gestureTab == "Sensitivity" {
            gestureSection("Travel", ids: ["travel", "columnTravel"], fields: fields)
            gestureSection("Commit and Flick", ids: ["commitThreshold", "flickVelocity"], fields: fields)
        } else {
            let up = model.gestureTab == "Swipe Up"
            let prefix = up ? "swipeUp" : "swipeDown"
            let animation = model.get("gesture.\(prefix)Mode") as? String == "animation"
            gestureSection("Mode", ids: [prefix + "Mode"], fields: fields)
            if animation {
                Section("Window Animation") {
                    Label(up ? "Swipe up to close the focused window" : "Swipe down to minimize the focused window",
                          systemImage: up ? "arrow.up" : "arrow.down")
                    if up {
                        ForEach(fields.filter { $0.id == "gesture.tabCloseApps" }) { row($0) }
                    }
                }
            } else {
                gestureSection("Directional Commands", ids: [prefix, prefix + "Right", prefix + "Left"], fields: fields)
                Section {
                    Text("Swipe vertically, then turn left or right to use a directional command. Open Application commands share the app selected in General.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func gestureSection(_ title: String, ids: [String], fields: [Setting]) -> some View {
        Section(title) {
            ForEach(fields.filter { ids.contains(String($0.id.dropFirst("gesture.".count))) }) { row($0) }
        }
    }

    @ViewBuilder private func row(_ field: Setting) -> some View {
        let isMultiline = field.id == "float" || field.id == "tile" || model.get(field.id) is [String] || field.id == "include"
        if isMultiline {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    fieldLabel(field)
                    Spacer()
                    restoreButton(field)
                }
                control(field)
            }
        } else {
            LabeledContent {
                control(field)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .disabled(commandDisabled(field.id))
                restoreButton(field)
            } label: {
                fieldLabel(field)
            }
        }
    }
    private func commandDisabled(_ id: String) -> Bool {
        if ["gesture.swipeUp", "gesture.swipeUpRight", "gesture.swipeUpLeft"].contains(id) {
            return model.get("gesture.swipeUpMode") as? String != "commands"
        }
        if ["gesture.swipeDown", "gesture.swipeDownRight", "gesture.swipeDownLeft"].contains(id) {
            return model.get("gesture.swipeDownMode") as? String == "animation"
        }
        return false
    }
    private func fieldLabel(_ field: Setting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.title)
            Text(field.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func restoreButton(_ field: Setting) -> some View {
        if model.modified(field.id) {
            Button { model.set(field.id, nil) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Restore Default")
            .accessibilityLabel("Restore \(field.title) to default")
        }
    }
    @ViewBuilder private func control(_ field: Setting) -> some View {
        let value = model.get(field.id)
        if ["gesture.swipeUp", "gesture.swipeUpRight", "gesture.swipeUpLeft",
            "gesture.swipeDown", "gesture.swipeDownRight", "gesture.swipeDownLeft"].contains(field.id) {
            let selected = LiveConfig.SwipeDownAction(rawValue: value as? String ?? "none") ?? .none
            Menu {
                Button {
                    model.set(field.id, "none")
                } label: {
                    Label("None", systemImage: selected == .none ? "checkmark" : "minus")
                }
                Divider()
                ForEach(LiveConfig.SwipeDownAction.groups, id: \.0) { title, actions in
                    Menu(title) {
                        ForEach(actions, id: \.rawValue) { action in
                            Button {
                                model.set(field.id, action.rawValue)
                            } label: {
                                if selected == action {
                                    Label(action.title, systemImage: "checkmark")
                                } else {
                                    Text(action.title)
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(selected.title)
            }
            .accessibilityLabel(field.title)
        } else if !field.choices.isEmpty {
            Picker(field.title, selection: Binding(get: { value.map { String(describing: $0) } ?? "" }, set: { model.set(field.id, field.id == "gesture.fingers" ? Int($0) as Any? : $0) })) {
                ForEach(field.choices, id: \.self) { Text($0 == "animation" ? "Window Animation" : $0 == "commands" ? "Directional Commands" : $0).tag($0) }
            }.labelsHidden().accessibilityLabel(field.title)
        } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            Toggle(field.title, isOn: Binding(get: { number.boolValue }, set: { model.set(field.id, $0) })).labelsHidden().toggleStyle(.switch).accessibilityLabel(field.title)
        } else if field.id == "float" || field.id == "tile" {
            rules(field.id)
        } else if value is [String] || field.id == "include" {
            let current = model.get(field.id) as? [String] ?? []
            TextEditor(text: Binding(get: { model.textDrafts[field.id] ?? current.joined(separator: "\n") }, set: {
                let entries = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                model.set(field.id, field.id == "include" && entries.isEmpty ? nil : entries)
                model.textDrafts[field.id] = $0
            })).font(.system(.body, design: .monospaced)).frame(height: 75).border(Color.secondary.opacity(0.2))
            if Self.appListFields.contains(field.id) {
                AppPickerButton(title: "Add App…", excluded: Set(current)) { id in
                    let drafted = model.textDrafts[field.id].map {
                        $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    } ?? current
                    if !drafted.contains(id) { model.set(field.id, drafted + [id]) }
                }
            }
        } else if field.id == "gesture.swipeDownApp" {
            HStack {
                TextField(field.title, text: Binding(get: { model.get(field.id) as? String ?? "" }, set: { model.set(field.id, $0.isEmpty ? nil : $0) }), prompt: Text("App bundle ID"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                AppPickerButton(title: "Choose…") { model.set(field.id, $0) }
                    .labelStyle(.iconOnly)
            }
        } else {
            TextField(field.title, text: Binding(get: { model.get(field.id).map { String(describing: $0) } ?? "" }, set: {
                if model.value(field.id, in: model.defaults) is NSNumber { model.set(field.id, Double($0).map { $0 as Any } ?? $0) }
                else { model.set(field.id, $0.isEmpty ? nil : $0) }
            })).textFieldStyle(.roundedBorder)
        }
    }
    private func rules(_ key: String) -> some View {
        let rules = model.get(key) as? [[String: String]] ?? []
        return VStack {
            ForEach(rules.indices, id: \.self) { index in
                HStack {
                    ForEach(["app", "titleContains"], id: \.self) { part in
                        TextField(part == "app" ? "App bundle ID" : "Title contains (optional)", text: Binding(get: { rules[index][part] ?? "" }, set: { text in
                            var updated = rules; updated[index][part] = text.isEmpty ? nil : text; model.set(key, updated)
                        })).textFieldStyle(.roundedBorder)
                        if part == "app" {
                            AppPickerButton(title: "Choose App…") { id in
                                var updated = rules; updated[index]["app"] = id; model.set(key, updated)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    Button("Remove") { var updated = rules; updated.remove(at: index); model.set(key, updated) }
                }
            }
            Button("Add Rule") { model.set(key, rules + [["app": ""]]) }
        }
    }
    private var shortcuts: some View {
        let overrides = model.values["hotkeys"] as? [String: Any] ?? [:]
        let defaults = Dictionary(uniqueKeysWithValues: HotKeyBindings.defaultTable)
        let keys = Set(defaults.keys).union(overrides.keys).sorted()
        return Group {
            Section("Shortcuts") {
            row(Setting(id: "hotkeysEnabled", title: "Enable shortcuts", detail: "Enable all global keyboard shortcuts. Your bindings are kept when disabled. The --no-hotkeys launch flag overrides this setting."))
            Text("Edit a command, disable a binding, or add a shortcut such as ctrl-alt-j. Restore Default removes its override.").font(.caption).foregroundStyle(.secondary)
            ForEach(keys, id: \.self) { key in
                HStack(alignment: .center, spacing: 12) {
                    Text(key).font(.system(.caption, design: .monospaced)).frame(width: 170, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(HotKeyBindings.actionLabel(overrides[key] as? String ?? (overrides[key] == nil ? defaults[key] ?? "" : "Disabled")))
                            .font(.caption).foregroundStyle(.secondary)
                    TextField("Command", text: Binding(get: { overrides[key] as? String ?? (overrides[key] == nil ? defaults[key] ?? "" : "") }, set: { model.set("hotkeys.\(key)", $0.isEmpty ? NSNull() : $0 as Any) }), prompt: Text("Disabled"))
                        .labelsHidden()
                        .accessibilityLabel("Command for \(key)")
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Disable") { model.set("hotkeys.\(key)", NSNull()) }
                    if overrides[key] != nil { Button("Restore Default") { model.set("hotkeys.\(key)", nil) } }
                }
            }
            }
            Section("Optional Shortcuts") {
            DisclosureGroup("Advanced Layout") {
                Text("These shortcuts are off by default. Enabling one assigns its suggested key combination.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(HotKeyBindings.advancedTable, id: \.0) { key, command in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(HotKeyBindings.actionLabel(command))
                            Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if overrides[key] as? String == command {
                            Button("Disable") { model.set("hotkeys.\(key)", NSNull()) }
                        } else {
                            Button(overrides[key] is String ? "Replace Binding" : "Enable") {
                                model.set("hotkeys.\(key)", command)
                            }
                        }
                    }
                }
            }
            }
            Section("Add Shortcut") {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Key combination").font(.caption).foregroundStyle(.secondary)
                    TextField("Key combination", text: $model.newKey, prompt: Text("ctrl-alt-j"))
                        .labelsHidden()
                        .accessibilityLabel("Key combination")
                }
                .frame(width: 200)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command").font(.caption).foregroundStyle(.secondary)
                    TextField("Command", text: $model.newCommand, prompt: Text("focus left"))
                        .labelsHidden()
                        .accessibilityLabel("New shortcut command")
                }
                .frame(maxWidth: .infinity)
                Button("Add") {
                    guard let parsed = HotKeySpec.parse(model.newKey), LiveCommand.validate(model.newCommand.split(separator: " ").map(String.init)) == nil else { model.error = "Enter a valid shortcut and command."; return }
                    model.set("hotkeys.\(parsed.spec)", model.newCommand); model.newKey = ""; model.newCommand = ""; model.error = ""
                }.disabled(model.newKey.isEmpty || model.newCommand.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            }
        }
    }
}
