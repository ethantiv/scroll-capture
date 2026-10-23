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
            // The capture takes the window under the cursor, which a menu click leaves over the menu: start it with the hotkey only.
            if appDelegate.busy { Button("Przerwij") { appDelegate.trigger() } } else { Text("Zrzut przewijany: ⌃⌥⌘S nad oknem") }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let registered = GlobalHotkey.register(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.trigger()
        }
        if !registered { status = "Nie udało się zarejestrować skrótu ⌃⌥⌘S" }
        _ = Self.permissionsGranted()
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
        guard Self.permissionsGranted() else {
            status = "Brak uprawnień: Dostępność i Nagrywanie ekranu"
            NSSound.beep()
            return
        }
        status = "Przewijam… (⌃⌥⌘S przerywa)"
        task = Task {
            defer { task = nil }
            do {
                let image = try await ScrollCapturer().capture()
                status = deliver(image)
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                status = "Przerwano"
            } catch {
                status = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    /// A failed file write (folder on an unplugged disk) falls back to the clipboard rather than losing the capture.
    private func deliver(_ image: CGImage) -> String {
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        let size = "\(image.width)×\(image.height) px"
        var failure = ""
        if UserDefaults.standard.bool(forKey: Self.saveToFileKey) {
            // Same folder as the system screenshot tool, Desktop by default.
            let folder = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
            let name = "Scroll Capture \(Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png"
            let url = folder.appending(path: name)
            do {
                try png.write(to: url)
                return "Zapisano \(url.lastPathComponent) (\(size))"
            } catch {
                failure = "Nie zapisano pliku (\(error.localizedDescription)). "
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        return "\(failure)Skopiowano do schowka (\(size))"
    }

    /// Accessibility posts the scroll events; Screen Recording takes the screenshots.
    private static func permissionsGranted() -> Bool {
        let ax = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        return ax && screen
    }
}

/// Carbon hot key: needs no permission and swallows the chord, unlike an NSEvent global monitor.
/// Stays registered until the app quits; false when the system refuses the chord.
@MainActor
enum GlobalHotkey {
    private static var action: (() -> Void)?

    static func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotkey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        return RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5343_5054), id: 1),
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
