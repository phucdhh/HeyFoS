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
        VStack(spacing: 0) {
            // Phase step strip
            pipelineStepStrip

            // Progress row
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.7)
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .frame(minWidth: 160)
                    .tint(.accentColor)
                Text(state.progressMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { state.cancelProcessing() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.97))
        .shadow(radius: 4, y: -2)
    }

    /// Compact step indicator strip — highlights the current pipeline phase.
    private var pipelineStepStrip: some View {
        let steps: [(icon: String, label: String, threshold: Double)] = [
            ("arrow.down.circle",     "Load",      0.05),
            ("scope",                 "Focus map", 0.20),
            ("arrow.triangle.2.circlepath", "Align / Normalize", 0.40),
            ("square.stack.3d.up",    "Blend",     0.60),
            ("square.and.arrow.down", "Save",      0.95),
        ]
        // Active step = last step whose threshold ≤ current progress
        let activeIdx = steps.indices.last { steps[$0].threshold <= state.progress } ?? 0

        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                let done    = i < activeIdx
                let current = i == activeIdx
                HStack(spacing: 4) {
                    Image(systemName: done ? "checkmark.circle.fill" : step.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(done ? .green : current ? Color.accentColor : .secondary.opacity(0.4))
                    Text(step.label)
                        .font(.system(size: 10, weight: current ? .semibold : .regular))
                        .foregroundStyle(done ? Color.secondary : current ? Color.primary : Color.secondary.opacity(0.4))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(current ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                if i < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 1, height: 10)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
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
