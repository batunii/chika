import Testing
import ChikaCore

// Positional shorthand so the ported cases read like the Kotlin `Panel(l, t, r, b)`.
extension Panel {
    init(_ l: Float, _ t: Float, _ r: Float, _ b: Float) { self.init(left: l, top: t, right: r, bottom: b) }
}

func near(_ expected: Float, _ actual: Float, _ tol: Float = 0.01, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(expected - actual) <= tol, "expected \(expected) ± \(tol), got \(actual)", sourceLocation: sourceLocation)
}
