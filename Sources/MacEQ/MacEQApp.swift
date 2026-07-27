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
            Image(systemName: model.engine.isRunning && model.profile.enabled
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

            if model.targetBundleID == nil {
                Text("Pick an app to equalise.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                if let error = model.engine.lastError {
                    errorBox(error)
                }
                bands
                Divider()
                footer
            }

            Divider()
            HStack {
                Text(model.engine.isRunning
                    ? "Out: \(model.engine.outputDeviceName) · \(Int(model.engine.sampleRate / 1000)) kHz"
                    : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { model.quit() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                if model.targetBundleID != nil {
                    Button("Stop equalising") { model.select(bundleID: nil) }
                }
            } label: {
                HStack(spacing: 6) {
                    appIcon(model.targetBundleID)
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
            .disabled(model.targetBundleID == nil)
        }
    }

    private func appRow(_ app: AudioProcess) -> some View {
        Button {
            model.select(bundleID: app.bundleID)
        } label: {
            // Menu rows render the icon only when it comes through as a Label image,
            // so hand SwiftUI the NSImage directly rather than styling it here.
            if let icon = model.icon(for: app.bundleID) {
                Label {
                    Text(app.isPlaying ? "\(app.name)  ♪" : app.name)
                } icon: {
                    Image(nsImage: icon)
                }
            } else {
                Text(app.isPlaying ? "\(app.name)  ♪" : app.name)
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

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            if model.engine.looksLikePermissionFailure {
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
