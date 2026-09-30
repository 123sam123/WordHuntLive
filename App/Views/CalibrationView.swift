import SwiftUI
import WordHuntCore

/// Drag a rectangle around the 4x4 board on a captured frame; the grid preview shows how
/// the app will split it into 16 tiles.
struct CalibrationView: View {
    let request: AppModel.CalibrationRequest
    let onConfirm: (BoardCalibration) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Normalized (0…1, top-left origin) selection.
    @State private var selection: CGRect?
    @State private var dragStart: CGPoint?
    @State private var tileInset: Double = 0.08
    @State private var lockSquare = true

    init(request: AppModel.CalibrationRequest, onConfirm: @escaping (BoardCalibration) -> Void) {
        self.request = request
        self.onConfirm = onConfirm
        _selection = State(initialValue: request.initial?.boardRect)
        _tileInset = State(initialValue: request.initial?.tileInset ?? 0.08)
    }

    private var imageAspect: CGFloat { CGFloat(request.image.width) / CGFloat(request.image.height) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calibrate board").font(.title2.bold())
            Text("Drag a box around the 4×4 letter grid — edge of the top-left tile to edge of the bottom-right tile.")
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let size = fitted(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: request.image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: size.width, height: size.height)
                    if let sel = selection {
                        GridOverlay(rect: denormalize(sel, size), inset: tileInset)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    if dragStart == nil { dragStart = v.startLocation }
                    selection = normalize(from: v.startLocation, to: v.location, size)
                }.onEnded { _ in dragStart = nil })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 420)
            HStack(spacing: 16) {
                Toggle("Square board", isOn: $lockSquare)
                HStack {
                    Text("Tile inset")
                    Slider(value: $tileInset, in: 0...0.3).frame(width: 140)
                    Text(String(format: "%.0f%%", tileInset * 100)).monospacedDigit().frame(width: 36)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirm grid") {
                    guard let sel = selection else { return }
                    onConfirm(.fromSelection(sel, sourceID: request.sourceID, sourceName: request.sourceName, tileInset: tileInset))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((selection?.width ?? 0) < 0.02)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 620, idealHeight: 760)
    }

    private func fitted(in avail: CGSize) -> CGSize {
        let w = min(avail.width, avail.height * imageAspect)
        return CGSize(width: w, height: w / imageAspect)
    }

    private func normalize(from a: CGPoint, to b: CGPoint, _ size: CGSize) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if lockSquare {
            let side = max(abs(dx), abs(dy))
            dx = side * (dx < 0 ? -1 : 1)
            dy = side * (dy < 0 ? -1 : 1)
        }
        let r = CGRect(x: a.x, y: a.y, width: dx, height: dy).standardized
        return CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
    }

    private func denormalize(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }
}

/// Board outline, 4x4 cell lines and the inset tile regions that get sampled.
struct GridOverlay: View {
    let rect: CGRect
    let inset: Double
    var rows = 4
    var columns = 4

    var body: some View {
        Canvas { ctx, _ in
            let geo = BoardGeometry(rows: rows, columns: columns, boardRect: rect, tileInset: inset)
            ctx.stroke(Path(rect), with: .color(Theme.path), lineWidth: 2)
            for r in 0..<rows {
                for c in 0..<columns {
                    let coord = GridCoord(r, c)
                    ctx.stroke(Path(geo.cellRect(coord)), with: .color(Theme.path.opacity(0.5)), lineWidth: 1)
                    ctx.fill(Path(geo.tileRect(coord)), with: .color(Theme.path.opacity(0.12)))
                    ctx.stroke(Path(geo.tileRect(coord)), with: .color(Theme.pathStart.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
