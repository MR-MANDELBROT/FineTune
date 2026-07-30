// FineTune/Views/Components/PlayPauseButton.swift
import SwiftUI

/// Playback state plus the action that toggles it, bundled so rows can pass a single
/// optional prop. `nil` means the app offers nothing to control, and no button is drawn.
struct PlaybackControl {
    let state: PlaybackState
    let toggle: () -> Void
}

/// Transport button shown next to apps whose playback FineTune can reach.
/// Matches MuteButton's press, hover and pulse behaviour so the control strip reads
/// as one row of buttons.
struct PlayPauseButton: View {
    let state: PlaybackState
    let action: () -> Void

    @State private var isPulsing = false
    @State private var isHovered = false

    private var isPlaying: Bool { state == .playing }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Keeps the width stable across the icon swap.
                Image(systemName: "pause.fill")
                    .opacity(0)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .font(.system(size: 13))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(buttonColor)
            .scaleEffect(isPulsing ? 1.1 : 1.0)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayPauseButtonPressStyle())
        .onHover { isHovered = $0 }
        .help(isPlaying ? "Pause" : "Play")
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: isPulsing)
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .onChange(of: state) { _, _ in
            isPulsing = true
            Task {
                try? await Task.sleep(for: .seconds(0.25))
                isPulsing = false
            }
        }
    }

    private var buttonColor: Color {
        isHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault
    }
}

private struct PlayPauseButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("Play/Pause Button States") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                PlayPauseButton(state: .playing) {}
                Text("Playing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack {
                PlayPauseButton(state: .paused) {}
                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
