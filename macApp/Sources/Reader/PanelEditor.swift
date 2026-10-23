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
    @State private var resetFailed = false
    @State private var confirmReset = false
    @State private var confirmDiscard = false
    // Captured like `page`: whether that page has saved edits for Reset to forget.
    @State private var edited: Bool
    // Each holds the boxes as they were before one change; the first undo is the page as the editor opened it.
    @State private var undos: [Snapshot] = []
    @State private var redos: [Snapshot] = []
    @FocusState private var focused: Bool

    private struct Snapshot { var panels: [Panel], selection: Set<Int>, drawn: Set<Panel> }

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
        _edited = State(initialValue: model.pageEdited)
    }

    private var single: Int? { selection.count == 1 ? selection.first : nil }
    private var changed: Bool { panels != (undos.first?.panels ?? panels) }

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
        .alert("Could not reset the panels", isPresented: $resetFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The page keeps its edited panels. Try Reset again, or Cancel to leave the page as it was.")
        }
        .confirmationDialog("Forget this page's edited panels?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Forget and Detect Again", role: .destructive) {
                if model.resetPanels(page: page) { onClose() } else { resetFailed = true }
            }
        } message: {
            Text("Chika detects the page's panels again, and it leaves the training export. This cannot be undone.")
        }
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onClose() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The changes to this page's panels are not saved.")
        }
        .background {
            // Off the crowded toolbar: Redo and Select All (to merge or delete an over-split page at once).
            Button("Redo") { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redos.isEmpty || drag != nil)
                .opacity(0)
                .accessibilityHidden(true)
            Button("Select All") { selection = Set(panels.indices) }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // Its own key focus, so Delete reaches it whatever was pressed before.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in deleteSelection(); return .handled }
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
                    .zIndex(2)
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
            record()
            panels.append(Panel(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75))
            selection = [panels.count - 1]
        }
        .position(x: area.width / 2, y: area.height / 2)
    }

    private func box(_ i: Int, in size: CGSize) -> some View {
        let p = panels[i], selected = selection.contains(i)
        let color = selected || dropTarget == i ? Chika.ochre : Chika.crimson
        let w = CGFloat(p.width) * size.width, h = CGFloat(p.height) * size.height
        let percent = { (v: Float) in Int((v * 100).rounded()) }
        let place = "\(percent(p.left))% from the left, \(percent(p.top))% from the top, \(percent(p.width))% wide, \(percent(p.height))% high"
        let shape = Rectangle()
            .fill(color.opacity(selected ? 0.18 : 0.08))
            .overlay(Rectangle().strokeBorder(color, lineWidth: selected ? 3 : 2))
            .overlay(alignment: .topLeading) {
                Text("\(i + 1)").font(.anton(15)).foregroundColor(color == Chika.ochre ? Chika.ink : Chika.cream)
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
            .zIndex(selected ? 1 : 0)   // over its neighbours' borders, so its number and handles stay clear
            .help(selected ? "Panel \(i + 1): drag to move it, a corner to resize, or its number onto another box to reorder"
                           : "Panel \(i + 1): click to select, Shift-click to add, drag its number onto another box to reorder")
            .accessibilityElement()
            .accessibilityLabel("Panel \(i + 1)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            // Toggles, so a VoiceOver user can gather two or more panels for Merge.
            .accessibilityAction { selection.formSymmetricDifference([i]) }
        // VoiceOver's way to move and resize, which are pointer drags otherwise: 2% of the page a step.
        let d: Float = 0.02
        return shape
            .accessibilityValue(place)
            .accessibilityAction(named: "Move left") { nudge(i) { PanelEditing.moved($0, dx: -d, dy: 0) } }
            .accessibilityAction(named: "Move right") { nudge(i) { PanelEditing.moved($0, dx: d, dy: 0) } }
            .accessibilityAction(named: "Move up") { nudge(i) { PanelEditing.moved($0, dx: 0, dy: -d) } }
            .accessibilityAction(named: "Move down") { nudge(i) { PanelEditing.moved($0, dx: 0, dy: d) } }
            .accessibilityAction(named: "Grow") { nudge(i) { PanelEditing.resized($0, by: d) } }
            .accessibilityAction(named: "Shrink") { nudge(i) { PanelEditing.resized($0, by: -d) } }
    }

    private func nudge(_ i: Int, _ change: (Panel) -> Panel) {
        guard panels.indices.contains(i), drag == nil else { return }
        record()
        replace(i, with: change(panels[i]))
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
            if let drawing { record(); panels.append(drawing); drawn.insert(drawing); selection = [panels.count - 1] }
        case .reorder(let i):
            // Takes the target's place in the reading order; the boxes between shift by one.
            if let target = dropTarget {
                record()
                panels = PanelEditing.reordered(panels, moving: i, by: target - i)
                selection = [target]
            }
        case .move, .resize:
            if undos.last?.panels == panels { undos.removeLast() }   // recorded on grabbing, but nothing moved
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
                    record()
                    return .resize(i, anchorX: ax, anchorY: ay)
                }
            }
        }
        // The number badge: about 34 x 26 pt in the box's top-leading corner. Topmost first, as drawn:
        // selected boxes over the rest, later boxes over earlier ones.
        let drawOrder = panels.indices.filter { !selection.contains($0) } + selection.sorted()
        if let i = drawOrder.last(where: { i in
            let p = panels[i]
            return x >= p.left && y >= p.top && x <= p.left + Float(34 / size.width) && y <= p.top + Float(26 / size.height)
        }) {
            selection = [i]
            return .reorder(i)
        }
        if let i = PanelEditing.hit(panels, x: x, y: y, among: selection) { record(); return .move(i, from: panels[i]) }
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
                Text("Page \(page + 1) · "
                     + (panels.isEmpty ? "0 panels: the page is read whole" : "\(panels.count) panel\(panels.count == 1 ? "" : "s")")
                     + (edited ? " · edited" : ""))
                    .font(.archivo(9)).tracking(1.4).foregroundColor(Chika.creamMuted).lineLimit(1)
                Text("Drag to draw · Shift-click to add · Return saves")
                    .font(.archivo(9)).foregroundColor(Chika.creamMuted).lineLimit(1)
            }
            Spacer()
            tool("Undo", "arrow.uturn.backward", "Undo the last change (⌘Z)", enabled: !undos.isEmpty && drag == nil) { undo() }
                .keyboardShortcut("z", modifiers: .command)
            tool("Earlier", "arrowshape.backward", "Read the selected panel earlier", enabled: (single ?? 0) > 0) { reorder(-1) }
            tool("Later", "arrowshape.forward", "Read the selected panel later",
                 enabled: single.map { $0 < panels.count - 1 } ?? false) { reorder(1) }
            tool("Merge", "arrow.triangle.merge", "Merge the selected panels into one", enabled: selection.count > 1) {
                record()
                panels = PanelEditing.merged(panels, selection)
                selection = [selection.min()!]
            }
            tool("Split across", "rectangle.split.1x2", "Split the selected panel into top and bottom halves",
                 enabled: single != nil) { split(across: true) }
            tool("Split down", "rectangle.split.2x1", "Split the selected panel into side-by-side halves",
                 enabled: single != nil) { split(across: false) }
            tool("Delete", "trash", "Delete the selected panels (Delete)", enabled: !selection.isEmpty && drag == nil) { deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
            tool("Auto order", "list.number",
                 "Put the panels in reading order, \(model.rightToLeft ? "right to left" : "left to right")",
                 enabled: panels.count > 1) {
                record()
                panels = PanelOrdering.order(panels, rightToLeft: model.rightToLeft)
                selection = []
            }
            // Not the undo arrow it once was: this forgets saved edits for good, so it asks first.
            tool("Reset to detected", "wand.and.stars",
                 edited ? "Forget this page's saved panels and detect them again" : "Only a page with saved panels can be reset",
                 enabled: edited && drag == nil) { confirmReset = true }
            Button { if changed { confirmDiscard = true } else { onClose() } } label: { pill("Cancel", Chika.cream.opacity(0.12)) }
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
        record()
        panels = PanelEditing.reordered(panels, moving: i, by: delta)
        selection = [min(max(i + delta, 0), panels.count - 1)]
    }

    private func split(across: Bool) {
        guard let i = single else { return }
        let halves = PanelEditing.split(panels, at: i, across: across, rightToLeft: model.rightToLeft)
        guard halves.count > panels.count else { NSSound.beep(); return }   // too small to halve
        record()
        panels = halves
        selection = [i, i + 1]
    }

    private func deleteSelection() {
        // Not mid-drag: the drag holds a panel index that deleting would make stale.
        guard !selection.isEmpty, drag == nil else { return }
        record()
        panels.remove(atOffsets: IndexSet(selection))
        selection = []
    }

    // MARK: - Undo

    /// Called before each change to the boxes, so ⌘Z can take it back.
    private func record() {
        undos.append(Snapshot(panels: panels, selection: selection, drawn: drawn))
        redos.removeAll()
    }

    private func undo() {
        guard drag == nil, let last = undos.popLast() else { return }
        redos.append(Snapshot(panels: panels, selection: selection, drawn: drawn))
        (panels, selection, drawn) = (last.panels, last.selection, last.drawn)
    }

    private func redo() {
        guard drag == nil, let next = redos.popLast() else { return }
        undos.append(Snapshot(panels: panels, selection: selection, drawn: drawn))
        (panels, selection, drawn) = (next.panels, next.selection, next.drawn)
    }

    private func save() {
        if model.savePanels(panels, page: page, drawn: panels.allSatisfy(drawn.contains)) { onClose() } else { saveFailed = true }
    }
}
