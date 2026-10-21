import SwiftUI

// MARK: - Signature texture & motifs (ported from ChikaBrand.kt)

/// Low-opacity halftone dot wash drawn behind content. Keep alpha subtle (0.05–0.22).
struct Halftone: View {
    var color: Color = Chika.ink
    var alpha: Double = 0.06
    var spacing: CGFloat = 9
    var radius: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, size in
            let dot = Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            var y: CGFloat = 0
            while y < size.height + spacing {
                var x: CGFloat = 0
                while x < size.width + spacing {
                    ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(color.opacity(alpha)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Halftone dot wash layered behind the view.
    func halftone(color: Color = Chika.ink, alpha: Double = 0.06) -> some View {
        background(Halftone(color: color, alpha: alpha))
    }

    /// Hard offset comic shadow (no blur) peeking bottom-right.
    func comicShadow(offset: CGFloat = 5, color: Color = .black.opacity(0.7), corner: CGFloat = 0) -> some View {
        background(
            RoundedRectangle(cornerRadius: corner)
                .fill(color)
                .offset(x: offset, y: offset)
        )
    }
}

/// The 20-point comic action-burst (same control points as the Android StarburstShape).
struct StarburstShape: Shape {
    private static let pts: [CGFloat] = [
        0.50, 0.00, 0.60, 0.16, 0.78, 0.09, 0.74, 0.28, 0.95, 0.30,
        0.80, 0.46, 0.98, 0.62, 0.77, 0.64, 0.80, 0.86, 0.60, 0.74,
        0.52, 0.96, 0.42, 0.75, 0.22, 0.88, 0.23, 0.65, 0.02, 0.64,
        0.18, 0.46, 0.04, 0.30, 0.25, 0.28, 0.21, 0.09, 0.40, 0.16,
    ]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = Self.pts
        p.move(to: CGPoint(x: pts[0] * rect.width, y: pts[1] * rect.height))
        var i = 2
        while i < pts.count {
            p.addLine(to: CGPoint(x: pts[i] * rect.width, y: pts[i + 1] * rect.height))
            i += 2
        }
        p.closeSubpath()
        return p
    }
}

/// Four L-shaped reticle corner brackets, drawn as an overlay.
struct Reticle: View {
    var color: Color = Chika.cream
    var inset: CGFloat = 8
    var length: CGFloat = 14
    var stroke: CGFloat = 2.5

    var body: some View {
        Canvas { ctx, size in
            let i = inset, l = length, w = size.width, h = size.height
            func bracket(_ a: CGPoint, _ b: CGPoint) {
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .square))
            }
            bracket(CGPoint(x: i, y: i + l), CGPoint(x: i, y: i)); bracket(CGPoint(x: i, y: i), CGPoint(x: i + l, y: i))
            bracket(CGPoint(x: w - i - l, y: i), CGPoint(x: w - i, y: i)); bracket(CGPoint(x: w - i, y: i), CGPoint(x: w - i, y: i + l))
            bracket(CGPoint(x: i, y: h - i - l), CGPoint(x: i, y: h - i)); bracket(CGPoint(x: i, y: h - i), CGPoint(x: i + l, y: h - i))
            bracket(CGPoint(x: w - i - l, y: h - i), CGPoint(x: w - i, y: h - i)); bracket(CGPoint(x: w - i, y: h - i), CGPoint(x: w - i, y: h - i - l))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Logo system

/// The Chika three-panel "C" mark on its maroon ground, with a hard drop shadow.
struct ChikaMark: View {
    var size: CGFloat
    var body: some View {
        Image("ChikaMark")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .comicShadow(offset: 3, color: .black.opacity(0.6), corner: size * 0.22)
    }
}

/// "CHI·KA / CHITRA KATHA" lockup (cream + crimson Anton over an Archivo kicker).
struct ChikaWordmark: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text("CHI").foregroundColor(Chika.cream) + Text("KA").foregroundColor(Chika.crimson))
                .font(.anton(28))
            KickerText("Chitra Katha", size: 8.5)
                .tracking(2.6)
        }
    }
}

/// The rotated ochre "kicker" banner (e.g. YOUR LIBRARY) with ink frame + hard shadow.
struct OchreBadge: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.anton(15))
            .tracking(0.6)
            .foregroundColor(Chika.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Chika.ochre)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Chika.ink, lineWidth: 2.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .comicShadow(offset: 3, color: .black.opacity(0.6), corner: 3)
            .rotationEffect(.degrees(-1.5))
    }
}

/// Ochre starburst page coin showing "page / total".
struct PageCoin: View {
    let page: Int
    let total: Int
    var size: CGFloat = 58
    var body: some View {
        ZStack {
            StarburstShape().fill(Chika.ink).frame(width: size, height: size)
            StarburstShape().fill(Chika.ochre).frame(width: size - 6, height: size - 6)
            VStack(spacing: -7) {
                Text("\(page)").font(.anton(20)).foregroundColor(Chika.ink)
                Text("\(total)").font(.anton(9)).foregroundColor(Chika.ink.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
    }
}

/// RoundedRectangle alias matching Android's RoundedCornerShape naming, for readability.
struct RoundedCornerShape: Shape {
    var cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}
