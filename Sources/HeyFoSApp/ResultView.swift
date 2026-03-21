import SwiftUI
import AppKit

/// Full-window result viewer shown as a sheet after processing completes.
struct ResultView: View {
    @ObservedObject var state: ProcessingState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus Stack Complete")
                        .font(.headline)
                    if let url = state.outputURL {
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Open in Preview") {
                    if let url = state.outputURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                Button("Reveal in Finder") {
                    if let url = state.outputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Image preview
            if let image = state.resultImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            minWidth: 400, maxWidth: .infinity,
                            minHeight: 300, maxHeight: .infinity
                        )
                        .padding()
                }
                .background(Color(NSColor.underPageBackgroundColor))
            } else {
                ContentUnavailableView(
                    "No preview available",
                    systemImage: "photo",
                    description: Text("The result was saved but could not be loaded for preview.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Stats footer
            HStack {
                Label("\(state.imageFiles.count) images stacked", systemImage: "photo.stack")
                    .foregroundStyle(.secondary)
                Spacer()
                if let url = state.outputURL,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    Text("Output size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 700, minHeight: 540)
    }
}
