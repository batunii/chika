import SwiftUI
import AppKit
import ChikaCore

/// The panel editor (⌘E, Panels mode): the whole page with its panels as numbered boxes in reading
/// order. Drag on the page to draw a panel; click a box to select it (Shift-click adds); drag a
/// selected box to move it, or its corners to resize; drag a box's number onto another box to take
/// its place in the reading order. Saving stores the page's panels in place of detection. All pointer input is one drag gesture on the page, hit-tested here, so a drag across
/// an unselected box still draws.
struct PanelEditor: View {
    @ObservedObject var model: ReaderModel
    let onClose: () -> Void
    @EnvironmentObject private var settings: ChikaSettings
    // Captured on entry, so the peek window turning the page cannot move the edit to another page.
    @State private var page: Int
    @State private var image: CGImage?
    @State private var panels: [Panel]
    @State private var selection: Set<Int> = []
    @State private var drag: Drag?
    @State private var drawing: Panel?
    @State private var dropTarget: Int?   // the box under a dragged number
    // Boxes drawn by hand (by value, so reordering and deleting need no bookkeeping; a move or resize
    // carries the mark along). Only a page made of these is training data.
    // shortcut: the database keeps one flag per page, so reopening a page drawn only in part forgets which
    // boxes were drawn; store a flag per box if people correct pages over several sittings.
    @State private var drawn: Set<Panel>
    @State private var saveFailed = false

    private enum Drag { case draw(x: Float, y: Float), move(Int, from: Panel), resize(Int, anchorX: Float, anchorY: Float), reorder(Int) }

    init(model: ReaderModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _page = State(initialValue: model.slots.page)
        _image = State(initialValue: model.image)
        let regions = model.slots.regions ?? []
        // [.fullPage] means "no panels" (detection found none, or saved empty): as a box it would catch every click and drag.
        let panels = regions == [.fullPage] ? [] : regions
        _panels = State(initialValue: panels)
        _drawn = State(initialValue: model.pageEdited && ReadingProgress.panelsDrawn(model.comicURL, page: model.slots.page) ? Set(panels) : [])
    }

    private var single: Int? { selection.count == 1 ? selection.first : nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                if let image { canvas(image, in: geo.size) }
            }
        }
        .alert("Could not save the panels", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your edits are still open. Try Save again, or Cancel to leave the page as it was.")
        }
    }

    private func canvas(_ image: CGImage, in area: CGSize) -> some View {
        let draw = computePageDraw(camera: .fullPage, bitmapW: image.width, bitmapH: image.height,
                                   containerW: Float(area.width), containerH: Float(area.height), fill: 0.96)
        let size = CGSize(width: CGFloat(draw.scaledWidth), height: CGFloat(draw.scaledHeight))
        return ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable()
                .modifier(NightFilterEffect(filter: settings.nightFilter))
            ForEach(panels.indices, id: \.self) { box($0, in: size) }
            if let drawing {
                Rectangle().stroke(Chika.ochre, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: CGFloat(drawing.width) * size.width, height: CGFloat(drawing.height) * size.height)
                    .offset(x: CGFloat(drawing.left) * size.width, y: CGFloat(drawing.top) * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { dragged($0, size) }
            .onEnded { dropped($0, size) })
        .help("Drag on the page to draw a panel. Click a box to select it, Shift-click to add one; drag a selected box to move it, or its corners to resize; drag a box's number onto another box to reorder.")
        // The boxes stay their own elements; Add panel is VoiceOver's way to draw one.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(page + 1)")
        .accessibilityAction(named: "Add panel") {
            panels.append(Panel(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75))
            selection = [panels.count - 1]
        }
        .position(x: area.width / 2, y: area.height / 2)
    }

    private func box(_ i: Int, in size: CGSize) -> some View {
        let p = panels[i], selected = selection.contains(i)
        let color = selected || dropTarget == i ? Chika.ochre : Chika.crimson
        let w = CGFloat(p.width) * size.width, h = CGFloat(p.height) * size.height
        return Rectangle()
            .fill(color.opacity(selected ? 0.18 : 0.08))
            .overlay(Rectangle().strokeBorder(color, lineWidth: selected ? 3 : 2))
            .overlay(alignment: .topLeading) {
                Text("\(i + 1)").font(.anton(15)).foregroundColor(Chika.cream)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(color).clipShape(Capsule()).padding(4)
            }
            .overlay {
                if selected {   // resize handles
                    ForEach(0..<4, id: \.self) { corner in
                        Rectangle().fill(Chika.cream).border(Chika.ink).frame(width: 9, height: 9)
                            .position(x: corner % 2 == 0 ? 0 : w, y: corner < 2 ? 0 : h)
                    }
                }
            }
            .frame(width: w, height: h)
            .offset(x: CGFloat(p.left) * size.width, y: CGFloat(p.top) * size.height)
            .help(selected ? "Panel \(i + 1): drag to move it, a corner to resize, or its number onto another box to reorder"
                           : "Panel \(i + 1): click to select, Shift-click to add, drag its number onto another box to reorder")
            .accessibilityElement()
            .accessibilityLabel("Panel \(i + 1)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            // Toggles, so a VoiceOver user can gather two or more panels for Merge.
            .accessibilityAction { selection.formSymmetricDifference([i]) }
    }

    // MARK: - Pointer

    private func dragged(_ value: DragGesture.Value, _ size: CGSize) {
        // Until the pointer has moved a little this may still be a click.
        guard drag != nil || hypot(value.translation.width, value.translation.height) >= 3 else { return }
        if drag == nil { drag = grab(value.startLocation, size) }
        let x = Float(value.location.x / size.width), y = Float(value.location.y / size.height)
        switch drag {
        case .draw(let ax, let ay): drawing = PanelEditing.rect(ax, ay, x, y)
        case .move(let i, let start):
            replace(i, with: PanelEditing.moved(start, dx: Float(value.translation.width / size.width),
                                                dy: Float(value.translation.height / size.height)))
        case .resize(let i, let ax, let ay): replace(i, with: PanelEditing.rect(ax, ay, x, y))
        case .reorder: dropTarget = PanelEditing.hit(panels, x: x, y: y)
        case nil: break
        }
    }

    /// Box `i` becomes `panel`, still counted as drawn by hand if it was.
    private func replace(_ i: Int, with panel: Panel) {
        if drawn.remove(panels[i]) != nil { drawn.insert(panel) }
        panels[i] = panel
    }

    private func dropped(_ value: DragGesture.Value, _ size: CGSize) {
        switch drag {
        case nil: click(value.location, size)
        case .draw:
            if let drawing { panels.append(drawing); drawn.insert(drawing); selection = [panels.count - 1] }
        case .reorder(let i):
            // Takes the target's place in the reading order; the boxes between shift by one.
            if let target = dropTarget { panels = PanelEditing.reordered(panels, moving: i, by: target - i); selection = [target] }
        case .move, .resize: break
        }
        drag = nil
        drawing = nil
        dropTarget = nil
    }

    /// What a drag starting at `point` takes: a selected box's corner (resize), a box's number (reorder),
    /// a selected box's body (move), else a new panel.
    private func grab(_ point: CGPoint, _ size: CGSize) -> Drag {
        let x = Float(point.x / size.width), y = Float(point.y / size.height)
        let reachX = Float(8 / size.width), reachY = Float(8 / size.height)   // 8 pt around a handle
        for i in selection.sorted(by: { panels[$0].area < panels[$1].area }) {   // smallest first, as hit()
            let p = panels[i]
            for (cx, ax) in [(p.left, p.right), (p.right, p.left)] {
                for (cy, ay) in [(p.top, p.bottom), (p.bottom, p.top)] where abs(x - cx) <= reachX && abs(y - cy) <= reachY {
                    return .resize(i, anchorX: ax, anchorY: ay)
                }
            }
        }
        // The number badge: about 34 x 26 pt in the box's top-leading corner.
        if let i = panels.indices.last(where: { i in   // last: drawn on top
            let p = panels[i]
            return x >= p.left && y >= p.top && x <= p.left + Float(34 / size.width) && y <= p.top + Float(26 / size.height)
        }) {
            selection = [i]
            return .reorder(i)
        }
        if let i = PanelEditing.hit(panels, x: x, y: y, among: selection) { return .move(i, from: panels[i]) }
        return .draw(x: x, y: y)
    }

    private func click(_ point: CGPoint, _ size: CGSize) {
        let x = Float(point.x / size.width), y = Float(point.y / size.height)
        let hit = PanelEditing.hit(panels, x: x, y: y)
        if NSEvent.modifierFlags.contains(.shift) {
            if let hit { selection.formSymmetricDifference([hit]) }
        } else {
            selection = hit.map { [$0] } ?? []
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit panels").font(.archivo(14, weight: 800)).foregroundColor(Chika.cream).lineLimit(1)
                Text("Page \(page + 1) · \(panels.count) panel\(panels.count == 1 ? "" : "s")")
                    .font(.archivo(9)).tracking(1.4).foregroundColor(Chika.creamMuted).lineLimit(1)
            }
            Spacer()
            tool("Earlier", "arrowshape.backward", "Read the selected panel earlier", enabled: (single ?? 0) > 0) { reorder(-1) }
            tool("Later", "arrowshape.forward", "Read the selected panel later",
                 enabled: single.map { $0 < panels.count - 1 } ?? false) { reorder(1) }
            tool("Merge", "arrow.triangle.merge", "Merge the selected panels into one", enabled: selection.count > 1) {
                panels = PanelEditing.merged(panels, selection)
                selection = [selection.min()!]
            }
            tool("Split across", "rectangle.split.1x2", "Split the selected panel into top and bottom halves",
                 enabled: single != nil) { split(across: true) }
            tool("Split down", "rectangle.split.2x1", "Split the selected panel into side-by-side halves",
                 enabled: single != nil) { split(across: false) }
            // Not mid-drag: the drag holds a panel index that deleting would make stale.
            tool("Delete", "trash", "Delete the selected panels (Delete)", enabled: !selection.isEmpty && drag == nil) {
                panels.remove(atOffsets: IndexSet(selection))
                selection = []
            }
            .keyboardShortcut(.delete, modifiers: [])
            tool("Auto order", "list.number",
                 "Put the panels in reading order, \(model.rightToLeft ? "right to left" : "left to right")",
                 enabled: panels.count > 1) {
                panels = PanelOrdering.order(panels, rightToLeft: model.rightToLeft)
                selection = []
            }
            tool("Reset to detected", "arrow.counterclockwise", "Forget this page's edited panels and detect them again",
                 enabled: true) {
                model.resetPanels(page: page)
                onClose()
            }
            Button { onClose() } label: { pill("Cancel", Chika.cream.opacity(0.12)) }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close without saving (Esc)")
                .accessibilityLabel("Cancel")
            Button { save() } label: { pill("Save", Chika.crimson) }
                .keyboardShortcut(.return, modifiers: [])
                .help("Save these panels for this page (Return)")
                .accessibilityLabel("Save")
        }
        .buttonStyle(.plain)
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 8)
        .background(Chika.ink.opacity(0.94))
    }

    private func tool(_ title: String, _ icon: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundColor(Chika.cream)
                .frame(width: 32, height: 34)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(title)
    }

    private func pill(_ title: String, _ fill: Color) -> some View {
        Text(title).font(.archivo(12, weight: 700)).foregroundColor(Chika.cream)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(fill).clipShape(Capsule())
    }

    private func reorder(_ delta: Int) {
        guard let i = single else { return }
        panels = PanelEditing.reordered(panels, moving: i, by: delta)
        selection = [min(max(i + delta, 0), panels.count - 1)]
    }

    private func split(across: Bool) {
        guard let i = single else { return }
        let before = panels.count
        panels = PanelEditing.split(panels, at: i, across: across, rightToLeft: model.rightToLeft)
        if panels.count > before { selection = [i, i + 1] } else { NSSound.beep() }   // too small to halve
    }

    private func save() {
        if model.savePanels(panels, page: page, drawn: panels.allSatisfy(drawn.contains)) { onClose() } else { saveFailed = true }
    }
}
