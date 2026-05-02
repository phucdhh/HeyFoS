import SwiftUI
import AppKit

// MARK: - Dual Image Viewer (ZereneStacker-style main canvas)

/// Shows two image viewer panels side-by-side: left = selected input, right = selected output.
/// Collapses to a single panel until output images are available.
struct DualImageViewer: View {
    @ObservedObject var state: ProcessingState

    private var leftTitle: String {
        guard let idx = state.selectedInputIndex, idx < state.imageFiles.count else {
            return state.imageFiles.first?.path ?? ""
        }
        return state.imageFiles[idx].path
    }

    private var rightTitle: String {
        if state.isProcessing, let idx = state.currentStackingIndex {
            let total = state.totalStackingImages
            return "Live Preview — image \(idx + 1) / \(total)"
        }
        guard let idx = state.selectedOutputIndex, idx < state.outputImages.count else {
            return state.outputImages.last?.url.path ?? ""
        }
        return state.outputImages[idx].url.path
    }

    private var rightImage: NSImage? {
        // During processing, show the live incremental result
        if state.isProcessing, let live = state.livePreviewImage {
            return live
        }
        if let idx = state.selectedOutputIndex, idx < state.outputImages.count {
            return state.outputImages[idx].nsImage
        }
        return state.outputImages.last?.nsImage
    }

    // True whenever the right panel should be visible (either final output or live preview)
    private var showDualPanel: Bool {
        !state.outputImages.isEmpty || (state.isProcessing && state.livePreviewImage != nil)
    }

    var body: some View {
        if !showDualPanel {
            // Single panel — shows selected input thumbnail or empty hint
            ImageViewerPanel(
                title: leftTitle,
                image: state.inputThumbnail,
                placeholder: state.imageFiles.isEmpty
                    ? "Use File > Add Files… or drag images onto the sidebar\nto load a focus stack"
                    : "Select a file from Input Files list to preview it"
            )
        } else {
            HSplitView {
                ImageViewerPanel(
                    title: leftTitle,
                    image: state.inputThumbnail,
                    placeholder: "Select a file in Input Files"
                )
                ImageViewerPanel(
                    title: rightTitle,
                    image: rightImage,
                    placeholder: "Select an output image",
                    isLivePreview: state.isProcessing && state.livePreviewImage != nil
                )
            }
        }
    }
}

// MARK: - Single image viewer panel

struct ImageViewerPanel: View {
    let title: String
    let image: NSImage?
    let placeholder: String
    var isLivePreview: Bool = false

    @State private var scale: PanelScale = .fitWindow
    @State private var isMaximized = false
    // Pinch / scroll-wheel zoom (multiplied on top of the scale picker)
    @State private var magnifyScale: CGFloat = 1.0

    enum PanelScale: String, CaseIterable, Identifiable {
        case fitWindow = "Fit window"
        case p25  = "25%"
        case p50  = "50%"
        case p100 = "100%"
        case p200 = "200%"
        var id: String { rawValue }

        var factor: CGFloat? {
            switch self {
            case .fitWindow: return nil
            case .p25:  return 0.25
            case .p50:  return 0.5
            case .p100: return 1.0
            case .p200: return 2.0
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            imageArea
            Divider()
            scaleBar
        }
        .background(Color(NSColor.windowBackgroundColor))
        // Reset magnify when picker changes
        .onChange(of: scale) { _, _ in magnifyScale = 1.0 }
    }

    // MARK: Title bar (mimics ZereneStacker's MDI title bar)
    private var titleBar: some View {
        HStack(spacing: 6) {
            Text(title.isEmpty ? "(no file)" : title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            // Minimise-like icon
            Button {
                isMaximized.toggle()
            } label: {
                Image(systemName: isMaximized
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(isMaximized ? "Restore" : "Maximise")
            // External open icon
            Button {
                if !title.isEmpty {
                    NSWorkspace.shared.open(URL(fileURLWithPath: title))
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Open in Preview")
            .disabled(title.isEmpty)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Image area
    private var imageArea: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.08, green: 0.08, blue: 0.08)
                .ignoresSafeArea()

            if let img = image {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width:  imageWidth(img: img, in: geo),
                                height: imageHeight(img: img, in: geo)
                            )
                            // Keep image centred when smaller than the scroll view
                            .frame(
                                minWidth: geo.size.width,
                                minHeight: geo.size.height
                            )
                    }
                    // Pinch-to-zoom (trackpad) — clamp to reasonable range
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                magnifyScale = min(max(value.magnification, 0.1), 20)
                            }
                            .onEnded { value in
                                magnifyScale = min(max(value.magnification, 0.1), 20)
                            }
                    )
                }
            } else {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .padding(24)
            }

            // LIVE badge — shown while stacking is in progress
            if isLivePreview {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func imageWidth(img: NSImage, in geo: GeometryProxy) -> CGFloat {
        if scale == .fitWindow {
            return geo.size.width * magnifyScale
        }
        let factor = scale.factor ?? 1.0
        return img.size.width * factor * magnifyScale
    }

    private func imageHeight(img: NSImage, in geo: GeometryProxy) -> CGFloat {
        if scale == .fitWindow {
            return geo.size.height * magnifyScale
        }
        let factor = scale.factor ?? 1.0
        return img.size.height * factor * magnifyScale
    }

    // MARK: Scale bar (bottom strip, exactly like ZereneStacker)
    private var scaleBar: some View {
        HStack(spacing: 6) {
            Text("Scale")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: $scale) {
                ForEach(PanelScale.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 116)
            .font(.system(size: 11))

            if magnifyScale != 1.0 {
                Text("× \(magnifyScale, specifier: "%.2f")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Reset") { magnifyScale = 1.0 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()
            if let img = image {
                Text("\(Int(img.size.width)) × \(Int(img.size.height))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// Keep old name so any lingering reference compiles.
typealias ResultView = DualImageViewer
