import AppKit
import SwiftUI
import TokeyyCore

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct UsageBar: View {
    let remaining: Double?
    private var tint: Color { (remaining ?? 100) <= 10 ? .red : (remaining ?? 100) <= 25 ? .orange : .accentColor }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: geometry.size.width * min(1, max(0, (remaining ?? 0) / 100)))
            }
        }
        .frame(height: 4)
        .accessibilityLabel(remaining.map { "\(Int($0)) percent remaining" } ?? "Usage unavailable")
    }
}

struct OverlayView: View {
    @Bindable var store: UsageStore
    var openSettings: () -> Void
    var openDashboard: (Provider) -> Void = { NSWorkspace.shared.open($0.dashboard) }

    var body: some View {
        VStack(spacing: 18) {
            if store.shouldShowProviderSwitcher {
                Picker("Provider", selection: $store.selected) {
                    ForEach(store.connectedProviders) { provider in Text(provider.name).tag(provider) }
                }
                .pickerStyle(.segmented).controlSize(.small).labelsHidden()
                .accessibilityLabel("Usage provider")
            }

            if store.current.connected {
                connectedContent
            } else {
                emptyContent
            }

            if !store.connectedProviders.isEmpty { footer }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(width: 280)
        .background(.regularMaterial)
        .preferredColorScheme(store.appearance.colorScheme)
    }

    @ViewBuilder private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            window(store.current.snapshot?.session, period: .session)
            window(store.current.snapshot?.weekly, period: .weekly)
        }
        if let error = store.current.error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.current.isLoading && store.current.snapshot == nil {
            Text("Reading your usage…").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 8) {
            ForEach(Provider.allCases) { provider in
                Button { Task { await store.connect(provider) } } label: {
                    Text("Connect \(provider.name)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Read your existing \(provider.product) sign-in on this Mac")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func window(_ value: UsageWindow?, period: UsagePeriod) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(period.title).font(.system(size: 12, weight: .medium))
                Spacer()
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(value.percentage)%")
                            .font(.system(size: 24, weight: .regular)).monospacedDigit().tracking(-0.7)
                        Text("left").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            UsageBar(remaining: value?.remaining)
            if let value {
                Text(value.resetDescription()).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .opacity(store.current.error == nil ? 1 : 0.55)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 13) {
            if let snapshot = store.current.snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updateLabel(snapshot, now: context.date))
                        if store.showAvailableResets, store.current.error == nil,
                           !snapshot.isStale(now: context.date, maximumAge: max(600, store.refreshInterval.seconds * 2)),
                           let resets = snapshot.resets {
                            let count = resets.availableCount(at: context.date)
                            Text("\(count) \(count == 1 ? "reset" : "resets") available")
                        }
                    }
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if store.current.connected {
                Button { openDashboard(store.selected) } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11)).frame(width: 14, height: 14)
                }
                .help("Open \(store.selected.product) settings")
                .accessibilityLabel("Open \(store.selected.product) settings")
                refreshButton
            }
            Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 14, height: 14) }
                .help("Settings…").accessibilityLabel("Open settings")
                .keyboardShortcut(",", modifiers: .command)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
    }

    private var refreshButton: some View {
        Button { Task { await store.refresh(store.selected) } } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 14, height: 14)
                .opacity(store.current.isLoading ? 0.35 : 1)
        }
        .disabled(store.current.isLoading || (store.current.retryAfter.map { $0 > .now } ?? false))
        .help("Refresh usage").accessibilityLabel("Refresh usage")
        .keyboardShortcut("r", modifiers: .command)
    }

    private func updateLabel(_ snapshot: UsageSnapshot, now: Date) -> String {
        if store.isDemo { return "Preview · sample data" }
        let minutes = max(0, Int(now.timeIntervalSince(snapshot.fetchedAt) / 60))
        let time = minutes == 0 ? "just now" : "\(minutes)m ago"
        return store.current.error == nil ? "Updated \(time)" : "Last success \(time)"
    }
}

struct SettingsView: View {
    @Bindable var store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Subscriptions") {
                        VStack(spacing: 18) {
                            ForEach(Provider.allCases) { provider in accountRow(provider) }
                        }
                    }

                    section("Menu bar") {
                        settingRow("Provider") {
                            Picker("Provider", selection: $store.selected) {
                                ForEach(store.connectedProviders.isEmpty ? Provider.allCases : store.connectedProviders) {
                                    Text($0.name).tag($0)
                                }
                            }
                        }
                        settingRow("Remaining usage") {
                            Picker("Remaining usage", selection: $store.period) {
                                ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        settingRow("Check usage every") {
                            Picker("Check usage every", selection: $store.refreshInterval) {
                                ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        HStack {
                            Text("Show available resets").font(.system(size: 12))
                            Spacer()
                            Toggle("Show available resets", isOn: $store.showAvailableResets)
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .onChange(of: store.showAvailableResets) { _, enabled in
                            if enabled { Task { await store.refreshAll(minimumAge: 0) } }
                        }
                        HStack {
                            Text("Launch at login").font(.system(size: 12))
                            Spacer()
                            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                                do {
                                    try LaunchAtLogin.setEnabled(enabled)
                                    loginError = nil
                                } catch { loginError = error.localizedDescription }
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .disabled(store.isDemo || !LaunchAtLogin.canConfigure)
                        }
                        if launchAtLogin && LaunchAtLogin.requiresApproval {
                            Button("Allow in System Settings", action: LaunchAtLogin.openSettings)
                                .buttonStyle(.borderless).font(.system(size: 10))
                        }
                        if let loginError {
                            Text(loginError).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    section("Appearance") {
                        settingRow("Theme") {
                            Picker("Theme", selection: $store.appearance) {
                                ForEach(Appearance.allCases) { Text($0 == .system ? "Follow macOS" : $0.title).tag($0) }
                            }
                        }
                        Text("Uses your system accent color.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.vertical, 18)
        }
        .frame(width: 420, height: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = LaunchAtLogin.isEnabled
        }
        .background(.regularMaterial)
        .preferredColorScheme(store.appearance.colorScheme)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.system(size: 10, weight: .medium))
                .tracking(1).foregroundStyle(.secondary)
            content()
        }
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            control().labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 140, alignment: .trailing)
        }
    }

    private func accountRow(_ provider: Provider) -> some View {
        let state = store.states[provider] ?? ProviderState()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.system(size: 12, weight: .medium))
                    Text(state.isLoading ? "Connecting…" : state.error != nil ? "Needs attention" : state.connected ? "Connected via \(provider.product)" : "\(provider.product) subscription")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if state.isLoading { ProgressView().controlSize(.small) }
                if state.connected {
                    if state.error != nil {
                        Button("Retry") { Task { await store.refresh(provider, allowKeychainPrompt: true) } }
                            .controlSize(.small)
                            .disabled(state.isLoading || (state.retryAfter.map { $0 > .now } ?? false))
                    }
                    Button("Disconnect") { store.disconnect(provider) }.controlSize(.small)
                } else {
                    Button("Connect") { Task { await store.connect(provider) } }
                        .controlSize(.small).disabled(state.isLoading)
                        .help("Read the existing \(provider.product) sign-in on this Mac")
                }
            }
            if let error = state.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
