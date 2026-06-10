import SwiftUI
import ChikaShared

/// Phase-1 scaffold screen: drives the real shared Kotlin pipeline (PanelPipeline → ordering +
/// merge/divide planning, computePageDraw → camera framing) over a sample page layout, with the
/// same tap-to-step interaction as the Android reader. Replaced by the real reader once archive
/// import and ML detection land on iOS.
struct ContentView: View {

    // Chika palette.
    private let ink = Color(red: 0.10, green: 0.09, blue: 0.08)
    private let cream = Color(red: 0.96, green: 0.93, blue: 0.86)
    private let crimson = Color(red: 0.79, green: 0.15, blue: 0.15)
    private let ochre = Color(red: 0.85, green: 0.60, blue: 0.20)

    // Logical page size the normalized panels map onto (2:3 portrait, like a comic page).
    private let pageW: Int32 = 1000
    private let pageH: Int32 = 1500

    // Sample layout exercising the planner: a wide top panel with two bubble groups (divides with
    // a bubble-aware cut), a strip of two small panels (merges), a lone small panel, two normal
    // panels, and a short footer panel.
    private let rawPanels = [
        Panel(left: 0.02, top: 0.02, right: 0.98, bottom: 0.30),
        Panel(left: 0.02, top: 0.33, right: 0.25, bottom: 0.48),
        Panel(left: 0.28, top: 0.33, right: 0.51, bottom: 0.48),
        Panel(left: 0.55, top: 0.33, right: 0.98, bottom: 0.48),
        Panel(left: 0.02, top: 0.52, right: 0.48, bottom: 0.78),
        Panel(left: 0.52, top: 0.52, right: 0.98, bottom: 0.78),
        Panel(left: 0.02, top: 0.81, right: 0.98, bottom: 0.98),
    ]
    private let bubbles = [
        Panel(left: 0.06, top: 0.06, right: 0.30, bottom: 0.16),
        Panel(left: 0.70, top: 0.14, right: 0.94, bottom: 0.26),
    ]

    @State private var rightToLeft = false
    @State private var step = -1 // -1 = whole page, 0..<n = zoom region index

    private var regions: [Panel] {
        PanelPipeline.shared.zoomRegions(
            panels: rawPanels, bubbles: bubbles,
            pageW: pageW, pageH: pageH, rightToLeft: rightToLeft
        )
    }

    private var camera: Panel {
        let regions = self.regions
        return (step >= 0 && step < regions.count) ? regions[step] : Panel.companion.FULL_PAGE
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            GeometryReader { geo in
                pageView(container: geo.size)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            let forward = value.location.x > geo.size.width / 2
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                if forward {
                                    step = step + 1 >= regions.count ? -1 : step + 1
                                } else {
                                    step = step <= -1 ? regions.count - 1 : step - 1
                                }
                            }
                        }
                    )
            }
            footer
        }
        .padding()
        .background(ink.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("CHIKA")
                .font(.system(size: 28, weight: .black))
                .foregroundColor(cream)
            Text("iOS core demo")
                .font(.caption)
                .foregroundColor(ochre)
            Spacer()
            Toggle(isOn: $rightToLeft.animation()) {
                Text("RTL").font(.caption.bold()).foregroundColor(cream)
            }
            .toggleStyle(.switch)
            .tint(crimson)
            .fixedSize()
        }
    }

    private var footer: some View {
        Text(step < 0
             ? "Whole page — tap right side to step into panel 1 of \(regions.count)"
             : "Zoom region \(step + 1) of \(regions.count) — left = back, right = next")
            .font(.footnote)
            .foregroundColor(cream.opacity(0.8))
            .frame(maxWidth: .infinity)
    }

    /// Renders the page positioned by the shared camera math: computePageDraw returns where the
    /// page "bitmap" must be drawn so the current camera region fills the container.
    private func pageView(container: CGSize) -> some View {
        let draw = CameraTransformKt.computePageDraw(
            camera: camera,
            bitmapW: pageW, bitmapH: pageH,
            containerW: Float(container.width), containerH: Float(container.height),
            fill: 0.96
        )
        let w = CGFloat(draw.scaledWidth)
        let h = CGFloat(draw.scaledHeight)
        let regions = self.regions

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(cream)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ink, lineWidth: 2))

            ForEach(rawPanels.indices, id: \.self) { i in
                panelRect(rawPanels[i], pageSize: CGSize(width: w, height: h))
                    .stroke(ink.opacity(0.55), lineWidth: 1.5)
            }
            ForEach(bubbles.indices, id: \.self) { i in
                panelRect(bubbles[i], pageSize: CGSize(width: w, height: h))
                    .fill(ochre.opacity(0.35))
            }
            ForEach(regions.indices, id: \.self) { i in
                let isActive = i == step
                let rect = cgRect(regions[i], pageSize: CGSize(width: w, height: h))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isActive ? crimson : crimson.opacity(0.25),
                            lineWidth: isActive ? 3 : 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .overlay(
                        Text("\(i + 1)")
                            .font(.system(size: 13, weight: .black))
                            .foregroundColor(cream)
                            .padding(4)
                            .background(Circle().fill(isActive ? crimson : ink.opacity(0.5)))
                            .offset(x: rect.minX + 4, y: rect.minY + 4),
                        alignment: .topLeading
                    )
            }
        }
        .frame(width: w, height: h)
        .offset(x: CGFloat(draw.left), y: CGFloat(draw.top))
    }

    private func cgRect(_ p: Panel, pageSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(p.left) * pageSize.width,
            y: CGFloat(p.top) * pageSize.height,
            width: CGFloat(p.width) * pageSize.width,
            height: CGFloat(p.height) * pageSize.height
        )
    }

    private func panelRect(_ p: Panel, pageSize: CGSize) -> Path {
        Path(cgRect(p, pageSize: pageSize))
    }
}
