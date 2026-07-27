import AppKit
import SwiftUI

@main
struct MacEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            Image(systemName: model.activeCount > 0
                ? "slider.horizontal.3"
                : "slider.horizontal.below.square.filled.and.square")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if model.editingBundleID == nil {
                Text("Pick an app to equalise.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                if let status = model.status(for: model.editingBundleID),
                   let error = status.error {
                    errorBox(error, isPermissionFailure: status.isPermissionFailure)
                }
                bands
                Divider()
                footer
            }

            Divider()
            statusLine
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.userApps) { appRow($0) }

                if model.showSystemProcesses, !model.systemProcesses.isEmpty {
                    Divider()
                    ForEach(model.systemProcesses) { appRow($0) }
                }

                Divider()
                Toggle("Show system processes", isOn: $model.showSystemProcesses)

                // Forgetting from here rather than from the selected app, because
                // selecting an app is what creates its profile in the first place.
                if !model.configuredApps.isEmpty {
                    Menu("Discard saved settings for…") {
                        ForEach(model.configuredApps) { app in
                            Button(app.name) { model.forget(app.bundleID) }
                        }
                    }
                }
                if model.activeCount > 0 {
                    Button("Turn all off") { model.turnOffAll() }
                }
            } label: {
                HStack(spacing: 6) {
                    appIcon(model.editingBundleID)
                    Text(model.targetName).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { model.profile.enabled },
                set: { model.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(model.editingBundleID == nil)
            .help(model.profile.enabled ? "Equalising this app" : "Not equalising this app")
        }
    }

    /// A row is ticked when that app is being equalised, whether or not it is the app
    /// currently open in the panel.
    private func appRow(_ app: AudioProcess) -> some View {
        Button {
            model.select(bundleID: app.bundleID)
        } label: {
            let title = [
                model.isEqualised(app.bundleID) ? "✓" : nil,
                app.name,
                app.isPlaying ? "♪" : nil,
            ].compactMap { $0 }.joined(separator: "  ")

            if let icon = model.icon(for: app.bundleID) {
                Label {
                    Text(title)
                } icon: {
                    Image(nsImage: icon)
                }
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String?) -> some View {
        if let icon = model.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 16, height: 16)
        }
    }

    private var bands: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.profile.bands.enumerated()), id: \.element.id) { index, band in
                sliderRow(
                    label: band.freqLabel,
                    value: Binding(
                        get: { model.profile.bands[index].gainDB },
                        set: { model.setGain(band: index, to: $0) }
                    ),
                    range: Profile.gainRange
                )
            }

            sliderRow(
                label: "Preamp",
                value: Binding(get: { model.profile.preampDB }, set: { model.setPreamp($0) }),
                range: Profile.preampRange
            )
            .padding(.top, 4)
        }
        .opacity(model.profile.enabled ? 1 : 0.4)
        .disabled(!model.profile.enabled)
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .monospacedDigit()
                .frame(width: 54, alignment: .leading)

            Slider(value: value, in: range, step: 0.5)

            Text(String(format: "%+.1f", value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value.wrappedValue = 0 }
        .help("Double-click to reset \(label) to 0 dB")
    }

    private var footer: some View {
        HStack {
            Menu(model.matchingPreset?.name ?? "Custom") {
                ForEach(Preset.all) { preset in
                    Button(preset.name) { model.apply(preset: preset) }
                }
            }
            .frame(width: 150)

            Spacer(minLength: 8)

            Button("Reset all") { model.resetAll() }
                .disabled(model.matchingPreset?.name == "Flat")
        }
    }

    private var statusLine: some View {
        HStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Quit") { model.quit() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        guard model.activeCount > 0 else { return "Nothing being equalised" }
        let apps = model.activeCount == 1 ? "1 app" : "\(model.activeCount) apps"
        return "\(apps) · \(model.pool.outputDeviceName) · \(Int(model.pool.sampleRate / 1000)) kHz"
    }

    private func errorBox(_ message: String, isPermissionFailure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            if isPermissionFailure {
                Text("MacEQ needs Audio Recording permission to read another app's audio.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { model.openPrivacySettings() }
                    .font(.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
