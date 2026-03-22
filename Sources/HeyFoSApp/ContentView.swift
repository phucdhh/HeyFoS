import SwiftUI

struct ContentView: View {
    @StateObject private var state = ProcessingState()

    var body: some View {
        HSplitView {
            // Left sidebar: Input Files + Output Images
            SidebarPanel(state: state)
                .frame(minWidth: 190, idealWidth: 240, maxWidth: 300)

            // Right: dual image viewers
            DualImageViewer(state: state)
                .frame(minWidth: 560)
        }
        .overlay(alignment: .bottom) {
            if state.isProcessing {
                processingBar
            }
        }
        .sheet(isPresented: $state.showPreferences) {
            SettingsPanel(state: state)
                .frame(minWidth: 380, minHeight: 420)
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .focusedObject(state)
    }

    // MARK: Processing bar (inline, not full overlay)
    private var processingBar: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .frame(width: 200)
                .tint(.accentColor)
            Text(state.progressMessage)
                .font(.system(size: 11))
                .foregroundStyle(.white)
            Spacer()
            Button("Cancel") { state.cancelProcessing() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        .shadow(radius: 4, y: -2)
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
            } else {
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
