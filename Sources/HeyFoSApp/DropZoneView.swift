import SwiftUI
import UniformTypeIdentifiers

/// Left sidebar panel — Input Files (top) + Output Images (bottom).
/// Mimics the ZereneStacker two-list sidebar layout.
struct SidebarPanel: View {
    @ObservedObject var state: ProcessingState
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 0) {
            inputFilesSection
            Divider()
            outputImagesSection
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { handleDrop($0) }
        .overlay(
            isDragging
                ? Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                : nil
        )
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Input Files section

    private var inputFilesSection: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 4) {
                Text("Input Files")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Toggle(isOn: $state.showAsAdjusted) {
                    Text("Show as adjusted")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if state.imageFiles.isEmpty {
                emptyDropHint
            } else {
                inputFileList
            }
        }
        .frame(minHeight: 120)
    }

    private var emptyDropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Drop images or folder here")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Button("Add Files…") { state.showAddFilesPanel() }
                    .controlSize(.small)
                Button("Folder…") { state.showAddFolderPanel() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var inputFileList: some View {
        List(selection: $state.selectedInputIndex) {
            ForEach(Array(state.imageFiles.enumerated()), id: \.offset) { idx, url in
                HStack(spacing: 5) {
                    // Stacking progress indicator
                    if let cur = state.currentStackingIndex {
                        if idx == cur {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        } else if idx < cur {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                    Text(url.lastPathComponent)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .tag(idx)
                .help(url.path)
                .contextMenu {
                    Button("Remove from List") {
                        state.imageFiles.remove(at: idx)
                    }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: state.selectedInputIndex) { _, new in state.loadThumbnail(at: new) }
        // Footer: file count + add button
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                Text("\(state.imageFiles.count) file\(state.imageFiles.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                Spacer()
                Button {
                    state.showAddFilesPanel()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 6)
                Button {
                    state.clearInputFiles()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red.opacity(0.8))
                .disabled(state.imageFiles.isEmpty)
                .padding(.trailing, 6)
            }
            .frame(height: 22)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Divider(), alignment: .top)
        }
    }

    // MARK: - Output Images section

    private var outputImagesSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Output Images")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Button {
                    guard let idx = state.selectedOutputIndex else { return }
                    state.outputImages.remove(at: idx)
                    if state.outputImages.isEmpty {
                        state.selectedOutputIndex = nil
                    } else {
                        state.selectedOutputIndex = min(idx, state.outputImages.count - 1)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red.opacity(0.8))
                .disabled(state.selectedOutputIndex == nil)
                .help("Remove selected output image from list")
                .padding(.trailing, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if state.outputImages.isEmpty {
                Text("No output yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
            } else {
                List(selection: $state.selectedOutputIndex) {
                    ForEach(Array(state.outputImages.enumerated()), id: \.offset) { idx, entry in
                        Text(entry.displayName)
                            .font(.system(size: 11))
                            .tag(idx)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .help(entry.url.path)
                            .contextMenu {
                                Button("Open in Preview") {
                                    NSWorkspace.shared.open(entry.url)
                                }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                                }
                                Divider()
                                Button("Remove from List") {
                                    state.outputImages.remove(at: idx)
                                    if state.selectedOutputIndex == idx {
                                        state.selectedOutputIndex = state.outputImages.isEmpty ? nil : max(0, idx - 1)
                                    }
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minHeight: 80)
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) { state.addImages(from: urls) }
        return true
    }
}

// Keep DropZoneView as a typealias so any existing references still compile.
typealias DropZoneView = SidebarPanel
