import Foundation
import SwiftUI

/// Status on the home screen and the loop-status sheet.
/// Hidden while Rheos is Aus. Scharf can be returned to Schatten with one tap.
struct RheosModeBanner: View {
    @State private var mode = RheosModeStore.current

    var body: some View {
        Group {
            switch mode {
            case .aus:
                EmptyView()
            case .schatten:
                Text("Rheos Schatten · nur Vorschlag, keine Wirkung")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            case .scharf:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rheos Scharf · ISF, KH-Faktor und Basal im Band. SMB und UAM laufen normal.")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Zurück zu Schatten") {
                        RheosModeStore.set(.schatten)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .onAppear { mode = RheosModeStore.current }
        .onReceive(
            Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name.rheosModeDidChange)
        ) { (_: Foundation.Notification) in
            mode = RheosModeStore.current
        }
    }
}

/// Small Rheos capsule over the top-left of the home chart. One tap opens the Rheos sheet,
/// where the mode, the chat and the meal help live. It takes no row of its own.
struct RheosHomeChip: View {
    let onOpen: () -> Void
    @State private var mode = RheosModeStore.current

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .fontDesign(.rounded)
            }
            .foregroundStyle(mode == .scharf ? Color.purple : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Rheos öffnen, Modus \(label)"))
        .onAppear { mode = RheosModeStore.current }
        .onReceive(
            Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name.rheosModeDidChange)
        ) { (_: Foundation.Notification) in
            mode = RheosModeStore.current
        }
    }

    private var label: String {
        switch mode {
        case .aus: return "Rheos"
        case .schatten: return "Rheos · Schatten"
        case .scharf: return "Rheos · Scharf"
        }
    }
}
