import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct ScrollCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppDelegate.saveToFileKey) private var saveToFile = false

    var body: some Scene {
        MenuBarExtra {
            if let status = appDelegate.status { Text(status) }
            Button(appDelegate.busy ? "Przerwij" : "Zrób zrzut przewijany  ⌃⌥⌘S") { appDelegate.trigger() }
            Toggle("Zapisuj do pliku", isOn: $saveToFile)
            Toggle("Uruchamiaj przy logowaniu", isOn: Binding(get: { appDelegate.launchAtLogin },
                                                               set: { appDelegate.setLaunchAtLogin($0) }))
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
        } label: {
            Group {
                if appDelegate.busy { Image(systemName: "arrow.down.circle.fill") } else { Image("MenuBarIcon") }
            }
            .accessibilityLabel("ScrollCapture")
        }
    }
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated static let saveToFileKey = "saveToFile"
    /// Outcome of the last capture; nothing before the first one.
    var status: String?
    var busy: Bool { task != nil }
    private var task: Task<Void, Never>?
    /// Mirrors `SMAppService` (not observable itself); `.requiresApproval` counts as on, as in Glosso.
    private(set) var launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    @ObservationIgnored private var hotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        hotkey = GlobalHotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.trigger()
        }
        _ = Self.permissionsGranted(prompt: true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Nie udało się zmienić autostartu: \(error.localizedDescription)"
        }
        launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    /// Pressing the hotkey again while a capture runs cancels it.
    func trigger() {
        if let task { task.cancel(); return }
        guard Self.permissionsGranted(prompt: true) else {
            status = "Brak uprawnień: Dostępność i Nagrywanie ekranu"
            NSSound.beep()
            return
        }
        status = "Przewijam… (⌃⌥⌘S przerywa)"
        task = Task {
            defer { task = nil }
            do {
                let image = try await ScrollCapturer().capture()
                status = try deliver(image)
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                status = "Przerwano"
            } catch {
                status = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    private func deliver(_ image: CGImage) throws -> String {
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        let size = "\(image.width)×\(image.height) px"
        guard UserDefaults.standard.bool(forKey: Self.saveToFileKey) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            return "Skopiowano do schowka (\(size))"
        }
        // Same folder as the system screenshot tool, Desktop by default.
        let folder = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
        let name = "Scroll Capture \(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png"
        let url = folder.appending(path: name)
        try png.write(to: url)
        return "Zapisano \(url.lastPathComponent) (\(size))"
    }

    /// Accessibility posts the scroll events; Screen Recording takes the screenshots.
    private static func permissionsGranted(prompt: Bool) -> Bool {
        let ax = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        let screen = CGPreflightScreenCaptureAccess() || (prompt && CGRequestScreenCaptureAccess())
        return ax && screen
    }
}

/// Carbon hot key: needs no permission and swallows the chord, unlike an NSEvent global monitor.
@MainActor
final class GlobalHotkey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotkey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5343_5054), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
