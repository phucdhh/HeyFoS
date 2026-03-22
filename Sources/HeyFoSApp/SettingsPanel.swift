import SwiftUI
import AppKit

/// Options / Preferences sheet — triggered from the Options menu.
/// Mimics ZereneStacker's "Options > Preferences…" dialog.
struct SettingsPanel: View {
    @ObservedObject var state: ProcessingState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Sheet title bar
            HStack {
                Text("Preferences")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Focus Detection Method")
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
                        Toggle("Pyramid Blending (PMax mode)", isOn: $state.usePyramidBlending)
                        if state.usePyramidBlending {
                            Stepper("Pyramid levels: \(state.pyramidLevels)",
                                    value: $state.pyramidLevels, in: 3...8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Blur radius: \(state.blurRadius, specifier: "%.1f") px")
                                Slider(value: $state.blurRadius, in: 0.5...6.0, step: 0.5)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .padding(.bottom, 4)

                    sectionHeader("Alignment")
                    Form {
                        Toggle("Alignment correction (X/Y translation)", isOn: $state.useAlignment)
                        Text("Disable for macro stacks to prevent scaling artifacts.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                    .padding(.bottom, 4)

                    sectionHeader("Output")
                    outputPathRow
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }

    private var outputPathRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default output folder:")
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
}
