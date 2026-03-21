import SwiftUI
import UniformTypeIdentifiers

/// Left panel: drop zone when empty, file list when images are loaded.
struct DropZoneView: View {
    @ObservedObject var state: ProcessingState
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if state.imageFiles.isEmpty {
                emptyDropZone
            } else {
                fileList
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .padding(4)
        )
    }

    // MARK: Empty drop zone
    private var emptyDropZone: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Drop Images or Folder Here")
                .font(.title2)
                .fontWeight(.medium)
            Text("Supports RAW (CR2, CR3, NEF, ARW, DNG…), TIFF, JPEG, PNG")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(action: openFilePanel) {
                    Label("Add Files…", systemImage: "plus")
                }
                Button(action: openFolderPanel) {
                    Label("Open Folder…", systemImage: "folder")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                )
        )
        .padding()
    }

    // MARK: File list
    private var fileList: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Image(systemName: "photo.stack.fill")
                    .foregroundStyle(Color.accentColor)
                Text("\(state.imageFiles.count) images loaded")
                    .font(.headline)
                Spacer()
                Button(action: openFilePanel) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Button(action: { state.clearAll() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            List {
                ForEach(Array(state.imageFiles.enumerated()), id: \.element) { idx, url in
                    HStack(spacing: 10) {
                        fileIcon(for: url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("#\(idx + 1)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { state.removeImages(at: $0) }
            }
            .listStyle(.inset)
        }
    }

    private func fileIcon(for url: URL) -> some View {
        let ext = url.pathExtension.lowercased()
        let isRaw = ["cr2","cr3","nef","arw","dng","rw2","orf"].contains(ext)
        return Image(systemName: isRaw ? "camera.aperture" : "photo")
            .foregroundStyle(isRaw ? Color.orange : Color.accentColor)
            .frame(width: 20)
    }

    // MARK: File picking
    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .tiff, .jpeg, .png,
            UTType(filenameExtension: "cr2")!, UTType(filenameExtension: "cr3")!,
            UTType(filenameExtension: "nef")!, UTType(filenameExtension: "arw")!,
            UTType(filenameExtension: "dng")!, UTType(filenameExtension: "rw2")!,
            UTType(filenameExtension: "orf")!]
        panel.begin { response in
            if response == .OK { state.addImages(from: panel.urls) }
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            if response == .OK { state.addImages(from: panel.urls) }
        }
    }

    // MARK: Drop handling
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) { state.addImages(from: urls) }
        return true
    }
}
