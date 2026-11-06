import AppKit
import Observation
import SwiftUI
import TokeyyCore

@main
struct TokeyyApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--enable-login") {
            do {
                try LaunchAtLogin.setEnabled(true)
                print("Launch at login: \(LaunchAtLogin.statusDescription)")
                exit(LaunchAtLogin.requiresApproval ? 2 : 0)
            } catch {
                fputs("Could not enable launch at login: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--login-status") {
            print("Launch at login: \(LaunchAtLogin.statusDescription)")
            return
        }
        if CommandLine.arguments.contains("--check-openai") {
            Task {
                do {
                    let snapshot = try await UsageClient().fetch(.openai, includeResets: CommandLine.arguments.contains("--include-resets"))
                    let session = snapshot.session.map { "\($0.percentage)%" } ?? "not reported"
                    let weekly = snapshot.weekly.map { "\($0.percentage)%" } ?? "not reported"
                    print("OpenAI live check passed · session left: \(session) · weekly left: \(weekly)")
                    if CommandLine.arguments.contains("--include-resets") {
                        print(snapshot.resets.map { "Available resets: \($0.availableCount())" } ?? "Available resets: not reported")
                    }
                    exit(0)
                } catch {
                    fputs("OpenAI live check: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews") {
            let path = CommandLine.arguments.dropFirst(index + 1).first ?? "dist/previews"
            Task {
                do { try await PreviewRenderer.render(to: URL(fileURLWithPath: path)); exit(0) }
                catch { fputs("Preview rendering failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore(demo: CommandLine.arguments.contains("--demo"))
    private(set) var statusItem: NSStatusItem!
    private(set) var popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 57)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Tokeyy usage")
        }
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: OverlayView(store: store, openSettings: { [weak self] in self?.showSettings() }))
        observeStore()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
                await self?.store.refreshDue()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
                await self?.store.refreshAll()
            }
        }
        Task { await store.refreshAll() }
        if store.isDemo || !Provider.allCases.contains(where: { store.states[$0]?.connected == true }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.presentPopover() }
        }
        if CommandLine.arguments.contains("--smoke-test-ui") {
            Task { await smokeTest() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func observeStore() {
        withObservationTracking {
            _ = store.states
            _ = store.selected
            _ = store.period
            _ = store.appearance
            updateStatus()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func updateStatus() {
        let value = store.menuPercentage
        let image = Self.statusImage(percentage: value)
        statusItem?.button?.image = image
        let detail = value.map { "\($0)% \(store.period.title.lowercased()) remaining" } ?? "Usage unavailable"
        statusItem?.button?.toolTip = "Tokeyy · \(store.selected.name)\n\(detail)"
        statusItem?.button?.setAccessibilityValue(detail)
        popover.appearance = store.appearance.nsAppearance
        settingsWindow?.appearance = store.appearance.nsAppearance
    }

    static func statusImage(percentage: Int?) -> NSImage {
        let size = NSSize(width: 51, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let bounds = rect.insetBy(dx: 1, dy: 1.5)
            let outline = NSBezierPath(roundedRect: bounds, xRadius: 4.5, yRadius: 4.5)
            NSColor.black.withAlphaComponent(0.12).setFill()
            outline.fill()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY,
                                      width: bounds.width * Double(percentage ?? 0) / 100, height: bounds.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            outline.lineWidth = 0.8
            outline.stroke()
            let text = percentage.map { "\($0)%" } ?? ""
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.black,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            string.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = percentage.map { "\($0) percent remaining" } ?? "Usage unavailable"
        return image
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Tokeyy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown { popover.close() } else { presentPopover() }
    }

    private func presentPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.refreshAll() }
    }

    @objc func showSettings() {
        popover.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Tokeyy Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
            window.appearance = store.appearance.nsAppearance
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Exercises real AppKit windows without account access. Run with --demo.
    private func smokeTest() async {
        guard store.isDemo else {
            fputs("UI smoke test requires --demo.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        // WindowServer can register a new status item after the app finishes launching.
        for _ in 0..<50 {
            if let window = statusItem.button?.window, window.frame.height > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        presentPopover()
        if !popover.isShown {
            fputs("Popover unavailable: status window=\(String(describing: statusItem.button?.window?.frame)), visible=\(statusItem.button?.window?.isVisible ?? false), button=\(String(describing: statusItem.button?.bounds)), screen=\(String(describing: NSScreen.main?.frame))\n", stderr)
        }
        assert(popover.isShown, "Popover must open")
        let overlaySize = popover.contentViewController!.view.fittingSize
        assert(overlaySize.width == 280 && overlaySize.height < 280, "Overlay must remain compact")
        assert(popover.positioningRect == statusItem.button!.bounds)
        if let button = statusItem.button, let statusWindow = button.window {
            let statusFrame = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let overlayFrame = popover.contentViewController!.view.window!.frame
            let gap = statusFrame.minY - overlayFrame.maxY
            assert((-2...8).contains(gap), "Overlay must sit directly below the menu bar")
        }
        assert(store.menuPercentage == 69)
        assert(!store.showAvailableResets)
        store.showAvailableResets = true
        try? await Task.sleep(for: .milliseconds(150))
        assert(popover.contentViewController!.view.fittingSize.height > overlaySize.height)
        assert(store.current.snapshot?.resets?.availableCount() == 2)
        store.showAvailableResets = false
        store.selected = .anthropic
        assert(store.menuPercentage == 52)
        store.period = .weekly
        assert(store.menuPercentage == 62)
        store.appearance = .dark
        try? await Task.sleep(for: .milliseconds(150))
        assert(popover.appearance?.name == .darkAqua)
        showSettings()
        assert(settingsWindow?.isVisible == true)
        assert(settingsWindow?.contentViewController?.view.fittingSize == NSSize(width: 420, height: 460))
        try? await Task.sleep(for: .milliseconds(350))
        assert(settingsWindow?.contentView?.frame.size == NSSize(width: 420, height: 460))
        assert(!popover.isShown, "Popover must finish closing before settings")
        settingsWindow?.performClose(nil)
        store.appearance = .light
        store.selected = .openai
        store.period = .session
        presentPopover()
        assert(popover.isShown)
        popover.close()
        try? await Task.sleep(for: .milliseconds(350))
        assert(!popover.isShown)
        store.disconnect(.anthropic)
        assert(!store.shouldShowProviderSwitcher && store.selected == .openai)
        presentPopover()
        assert(popover.isShown)
        assert(popover.contentViewController!.view.fittingSize.height < overlaySize.height)
        popover.close()
        try? await Task.sleep(for: .milliseconds(350))
        store.disconnect(.openai)
        presentPopover()
        assert(popover.isShown && store.connectedProviders.isEmpty)
        assert(popover.contentViewController!.view.fittingSize.height < 140)
        popover.close()
        print("UI smoke test passed: popover, 0/1/2 connected providers, period switch, appearance, settings, close/reopen.")
        NSApp.terminate(nil)
    }
}

@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = UsageStore(defaults: nil, demo: true)
        for appearance in [Appearance.light, .dark] {
            store.appearance = appearance
            store.selected = .openai
            try save(OverlayView(store: store, openSettings: {}), name: "overlay-\(appearance.rawValue)", appearance: appearance, to: directory)
            store.showAvailableResets = true
            try save(OverlayView(store: store, openSettings: {}), name: "overlay-resets-\(appearance.rawValue)", appearance: appearance, to: directory)
            store.showAvailableResets = false
            for provider in Provider.allCases {
                let single = UsageStore(defaults: nil, demo: true)
                single.appearance = appearance
                single.disconnect(provider == .openai ? .anthropic : .openai)
                try save(OverlayView(store: single, openSettings: {}), name: "single-\(provider.rawValue)-\(appearance.rawValue)", appearance: appearance, to: directory)
            }
            let missing = UsageStore(defaults: nil, client: PreviewClient())
            missing.appearance = appearance
            await missing.connect(.openai)
            try save(OverlayView(store: missing, openSettings: {}), name: "missing-session-\(appearance.rawValue)", appearance: appearance, to: directory)
            store.selected = .anthropic
            try save(OverlayView(store: store, openSettings: {}), name: "anthropic-\(appearance.rawValue)", appearance: appearance, to: directory)
            try save(SettingsView(store: store), name: "settings-\(appearance.rawValue)", appearance: appearance, to: directory)
            let empty = UsageStore(defaults: nil)
            empty.appearance = appearance
            try save(OverlayView(store: empty, openSettings: {}), name: "welcome-\(appearance.rawValue)", appearance: appearance, to: directory)
            try save(SettingsView(store: empty), name: "settings-welcome-\(appearance.rawValue)", appearance: appearance, to: directory)
        }
        print("Rendered native previews to \(directory.path)")
    }

    private struct PreviewClient: UsageFetching {
        func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot {
            UsageSnapshot(session: nil, weekly: try UsageWindow(used: 16, resetsAt: .now.addingTimeInterval(86400)), plan: nil)
        }
    }

    private static func save<V: View>(_ view: V, name: String, appearance: Appearance, to directory: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .active))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.nsAppearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw UsageError.invalidResponse
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UsageError.invalidResponse }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
