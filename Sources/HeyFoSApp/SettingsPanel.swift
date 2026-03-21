import SwiftUI
import AppKit

/// Right-hand settings panel + Process button.
struct SettingsPanel: View {
    @ObservedObject var state: ProcessingState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Focus Detection")
                Form {
                    Picker("Method:", selection: $state.method) {
                        ForEach(ProcessingState.FocusMethod.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .formStyle(.grouped)
                .padding(.bottom, 4)

                sectionHeader("Blending")
                Form {
                    Toggle("Pyramid Blending", isOn: $state.usePyramidBlending)
                    if state.usePyramidBlending {
                        Stepper("Levels: \(state.pyramidLevels)",
                                value: $state.pyramidLevels, in: 3...8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Blur radius: \(state.blurRadius, specifier: "%.1f") px")
                                .font(.body)
                            Slider(value: $state.blurRadius, in: 0.5...6.0, step: 0.5)
                        }
                    }
                }
                .formStyle(.grouped)
                .padding(.bottom, 4)

                sectionHeader("Quality")
                Form {
                    Toggle("Alignment Correction", isOn: $state.useAlignment)
                }
                .formStyle(.grouped)
                .padding(.bottom, 4)

                sectionHeader("Output")
                outputPathRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                processButton
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                if let err = state.errorMessage {
                    errorBanner(err)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(minWidth: 260, maxWidth: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private var outputPathRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save result to:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Output path", text: $state.outputPath)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "heyfos_result.tiff"
                    panel.allowedContentTypes = [.tiff]
                    panel.begin { resp in
                        if resp == .OK, let url = panel.url {
                            state.outputPath = url.path
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var processButton: some View {
        Button {
            if state.isProcessing { state.cancelProcessing() }
            else { state.startProcessing() }
        } label: {
            HStack {
                if state.isProcessing {
                    ProgressView().scaleEffect(0.7)
                    Text("Processing… \(Int(state.progress * 100))%")
                } else {
                    Image(systemName: "play.fill")
                    Text("Process Stack (\(state.imageFiles.count) images)")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(state.imageFiles.isEmpty)
        .tint(state.isProcessing ? Color.red : Color.accentColor)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(4)
        }
        .padding(10)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
