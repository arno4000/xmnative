import SwiftUI
import AppKit
import HeadphoneKit

@main
struct XMNativeApp: App {
    @ViewState private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("XMNative", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 820, height: 600)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if model.showBatteryInMenuBar, let pct = model.batterySummary {
                Text("\(pct)%").monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        guard model.connection == .connected else { return "headphones" }
        switch model.state?.noiseControl?.mode {
        case .noiseCancelling?: return "headphones.circle.fill"
        case .ambient?: return "ear"
        case .windReduction?: return "wind"
        default: return "headphones"
        }
    }

    private var accessibilityText: String {
        guard model.connection == .connected else { return "XMNative, not connected" }
        var s = model.displayName
        if let m = model.state?.noiseControl?.mode { s += ", \(m.title)" }
        if let b = model.batterySummary { s += ", battery \(b) percent" }
        return s
    }
}

enum AppActions {
    @MainActor static func openMainWindow(_ openWindow: OpenWindowAction) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The macOS 27 SDK turns `@State` into a macro whose plugin only ships with Xcode.
/// Using the underlying property wrapper through an alias keeps the app buildable with
/// the Command Line Tools alone.
typealias ViewState<Value> = SwiftUI.State<Value>
