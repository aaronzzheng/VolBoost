import SwiftUI

struct PopoverView: View {
    @ObservedObject var manager: AudioTapManager
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if manager.apps.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.apps) { app in
                            AppRow(app: app, manager: manager)
                            if app.id != manager.apps.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("VolBoost").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(manager.apps.count) playing")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No apps are playing audio")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct AppRow: View {
    let app: AudioTapManager.AudioApp
    let manager: AudioTapManager

    private var maxPercent: Double {
        app.boostEnabled ? AudioTapManager.maxBoostPercent : 100
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                icon
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                // Tinted while a tap pipeline is live, i.e. VolBoost is in this app's path.
                Text("\(Int(app.gainPercent.rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(percentStyle)
                    .frame(width: 38, alignment: .trailing)

                boostToggle
            }

            HStack(spacing: 8) {
                Button {
                    manager.toggleMute(for: app)
                } label: {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .frame(width: 16)
                        .foregroundStyle(app.isMuted ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(app.isMuted ? "Unmute" : "Mute")

                Slider(value: Binding(
                    get: { min(app.gainPercent, maxPercent) },
                    set: { manager.setGainPercent($0, for: app) }
                ), in: 0...maxPercent)
                .controlSize(.small)
                .disabled(app.isMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var percentStyle: AnyShapeStyle {
        if app.isMuted { return AnyShapeStyle(.tertiary) }
        return app.isControlled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }

    private var icon: some View {
        Group {
            if let nsImage = app.icon {
                Image(nsImage: nsImage).resizable()
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .frame(width: 16, height: 16)
    }

    private var boostToggle: some View {
        Button {
            manager.setBoostEnabled(!app.boostEnabled, for: app)
        } label: {
            Image(systemName: app.boostEnabled ? "bolt.fill" : "bolt")
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(app.boostEnabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(app.boostEnabled
              ? "Boost on — slider goes to \(Int(AudioTapManager.maxBoostPercent))%"
              : "Enable boost above 100%")
    }
}
