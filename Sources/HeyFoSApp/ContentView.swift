import SwiftUI

struct ContentView: View {
    @StateObject private var state = ProcessingState()

    var body: some View {
        HSplitView {
            // Left: file drop / file list
            DropZoneView(state: state)
                .frame(minWidth: 400)

            // Right: settings
            SettingsPanel(state: state)
                .frame(minWidth: 260, maxWidth: 320)
        }
        // Progress overlay while processing
        .overlay {
            if state.isProcessing {
                processingOverlay
            }
        }
        // Result sheet
        .sheet(isPresented: $state.showResult) {
            ResultView(state: state)
        }
        // Status bar
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !state.imageFiles.isEmpty && !state.isProcessing {
                    Button {
                        state.clearAll()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .help("Clear all images and start over")
                }
            }
        }
    }

    // MARK: Processing overlay
    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 320)
                    .tint(.accentColor)

                Text(state.progressMessage)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("\(Int(state.progress * 100))%")
                    .font(.system(.title, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))

                Button("Cancel") {
                    state.cancelProcessing()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
        }
    }

    // MARK: Status bar
    private var statusBar: some View {
        HStack {
            if let err = state.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(err).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            } else {
                Text(state.progressMessage).foregroundStyle(.secondary)
            }
            Spacer()
            Text("HeyFoS v1.0.0 · Apple Silicon")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
