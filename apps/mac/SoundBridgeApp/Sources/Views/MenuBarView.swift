import SwiftUI
import AppKit

// Cache font lookup once at launch
private let soundbridgeFont: Font = {
    let size: CGFloat = 22
    let possibleNames = [
        "SignPainterHouseScript",
        "SignPainter-HouseScript",
        "SignPainter House Script",
        "SignPainter"
    ]
    for name in possibleNames {
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
    }
    return .system(size: size, weight: .bold)
}()

struct MenuBarView: View {
    @StateObject private var volumeController = VolumeController.shared
    @StateObject private var eqController = EQController(deviceUID: "default")

    var body: some View {
        VStack(spacing: 0) {
            // 1. Output device picker, always visible
            SectionLabel(title: "Output")

            DeviceListSection(
                devices: volumeController.allDevices,
                activeUID: volumeController.activeDeviceUID,
                onSelect: { device in
                    volumeController.switchDevice(to: device)
                }
            )

            Divider()
                .padding(.horizontal, 12)

            // 2. Volume slider (only for fixed-volume devices)
            if volumeController.isFixedVolumeDevice {
                VolumeSliderRow(
                    volume: Binding(
                        get: { volumeController.currentVolume },
                        set: { volumeController.setVolume($0) }
                    ),
                    isMuted: volumeController.isMuted,
                    onToggleMute: {
                        volumeController.setMute(!volumeController.isMuted)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Text("This device supports native volume control")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            Divider()
                .padding(.horizontal, 12)

            // 2.5 EQ controls
            BasicEQView(eqController: eqController)

            Divider()
                .padding(.horizontal, 12)

            // 3. Reconnect audio + Footer
            ReconnectAudioButton()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            FooterBar()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .transaction { $0.animation = nil }
        .onReceive(volumeController.$activeDeviceUID) { uid in
            guard !uid.isEmpty else { return }
            eqController.attachSharedMemory(for: uid)
        }
    }
}

// MARK: - Section Label

struct SectionLabel: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

// MARK: - Volume Slider

struct VolumeSliderRow: View {
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleMute) {
                Image(systemName: muteIcon)
                    .font(.system(size: 12))
                    .foregroundColor(isMuted ? .red : .secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Slider(value: Binding(
                get: { Double(volume) },
                set: { volume = Float($0) }
            ), in: 0...1)

            Text("\(Int(volume * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var muteIcon: String {
        if isMuted || volume <= 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Device List

struct DeviceListSection: View {
    let devices: [OutputDevice]
    let activeUID: String
    let onSelect: (OutputDevice) -> Void

    var body: some View {
        let names = displayNames
        VStack(spacing: 2) {
            if devices.isEmpty {
                Text("No output devices")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            ForEach(devices) { device in
                DeviceRow(
                    device: device,
                    title: names[device.uid] ?? device.name,
                    isActive: device.uid == activeUID,
                    onSelect: { onSelect(device) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// Identical monitors report identical names; number repeats so rows stay distinguishable.
    private var displayNames: [String: String] {
        var totals: [String: Int] = [:]
        for device in devices { totals[device.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var result: [String: String] = [:]
        for device in devices {
            guard totals[device.name, default: 0] > 1 else {
                result[device.uid] = device.name
                continue
            }
            let index = seen[device.name, default: 0] + 1
            seen[device.name] = index
            result[device.uid] = "\(device.name) (\(index))"
        }
        return result
    }
}

struct DeviceRow: View {
    let device: OutputDevice
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isActive ? .accentColor : .secondary)

                Text(title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if device.isFixedVolume {
                    Text("Fixed")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Reconnect Audio

struct ReconnectAudioButton: View {
    @State private var isBouncing = false
    @State private var showDone = false

    var body: some View {
        Button(action: reconnect) {
            HStack(spacing: 6) {
                if isBouncing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: showDone ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(showDone ? .green : .secondary)
                }
                Text(showDone ? "Reconnected" : "Reconnect Audio")
                    .font(.system(size: 11))
                    .foregroundColor(showDone ? .green : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isBouncing)
    }

    private func reconnect() {
        isBouncing = true
        VolumeController.shared.bounceDevice()
        // Show feedback after bounce completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isBouncing = false
            showDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showDone = false
            }
        }
    }
}

// MARK: - Footer

struct FooterBar: View {
    var body: some View {
        HStack(spacing: 8) {
            UninstallButton()
            Spacer()
            QuitButton()
        }
    }
}

struct UninstallButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: performUninstall) {
            Text("Uninstall Driver")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isHovered ? .white : .red.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.red : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }

    private func performUninstall() {
        UninstallCoordinator.run()
    }
}

struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NSApp.terminate(nil)
        }) {
            Text("Quit SoundBridge")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isHovered ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}
