import SwiftUI

struct ContentView: View {
    @StateObject private var state = ProcessingState()
    @State private var showCancelConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar sits at the very top when processing
            if state.isProcessing {
                processingBar
            }

            HSplitView {
                // Left sidebar: Input Files + Output Images
                SidebarPanel(state: state)
                    .frame(minWidth: 190, idealWidth: 240, maxWidth: 300)

                // Right: dual image viewers
                DualImageViewer(state: state)
                    .frame(minWidth: 560)
            }
        }
        .sheet(isPresented: $state.showPreferences) {
            SettingsPanel(state: state)
                .frame(minWidth: 380, minHeight: 420)
        }
        .confirmationDialog(
            "Cancel focus stacking?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Processing", role: .destructive) { state.cancelProcessing() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The current stack will be discarded.")
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .focusedSceneValue(\.processingState, state)
    }

    // MARK: Processing bar — top of window, text-inside-bar design
    private var processingBar: some View {
        HStack(spacing: 8) {
            // Cancel button on the left
            Button(action: { showCancelConfirm = true }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .padding(.leading, 10)

            // Bar with embedded label
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 22)

                    // Fill
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(0, geo.size.width * state.progress), height: 22)
                        .animation(.linear(duration: 0.2), value: state.progress)

                    // Text inside bar — always readable
                    Text(state.progressMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 0)
                }
            }
            .frame(height: 22)
            .padding(.trailing, 10)
        }
        .frame(height: 34)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.97))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: Status bar
    private var statusBar: some View {
        HStack(spacing: 6) {
            if let err = state.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(err)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else if !state.isProcessing {
                // Don't repeat the progress message while the bar is visible at top
                Text(state.progressMessage)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("HeyFoS · Apple Silicon")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
