import SwiftUI

/// Alembic visual identity 2.0 — holographic HUD ("distillation lab meets JARVIS").
/// Cyan hologram = distilled/clean; amber = raw data being processed.
/// Liquid-glass surfaces: material + specular border + soft cyan bloom.
enum Theme {
    // Hologram primaries
    static let holo = Color(red: 0.34, green: 0.88, blue: 0.96)        // #56E1F5
    static let holoBright = Color(red: 0.55, green: 0.95, blue: 1.00)  // #8DF2FF
    static let holoDeep = Color(red: 0.12, green: 0.61, blue: 0.77)    // #1E9CC4
    static let abyss = Color(red: 0.016, green: 0.045, blue: 0.078)

    // Raw-data warmth (kept from v1 — amber means "raw / touched")
    static let copper = Color(red: 0.85, green: 0.53, blue: 0.28)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.35)
    static let distilledTeal = Color(red: 0.25, green: 0.78, blue: 0.72)
    static let deepTeal = Color(red: 0.10, green: 0.45, blue: 0.45)
    static let danger = Color(red: 0.92, green: 0.38, blue: 0.33)

    /// Primary action gradient — holographic cyan.
    static let accentGradient = LinearGradient(
        colors: [holoBright, holo, holoDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Secondary gradient — distilled teal (RAG/augment accents).
    static let distillGradient = LinearGradient(
        colors: [distilledTeal, holoDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Raw-data gradient — amber, used where data is still "crude".
    static let rawGradient = LinearGradient(
        colors: [amber, copper],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // Diff highlights
    static let cellModified = amber.opacity(0.26)
    static let rowAdded = distilledTeal.opacity(0.18)
    static let rowDropped = danger.opacity(0.15)

    /// Specular edge for glass surfaces.
    static let glassEdge = LinearGradient(
        colors: [Color.white.opacity(0.35), holo.opacity(0.10), Color.white.opacity(0.04), holo.opacity(0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Aurora background (slow-drifting holographic blobs over abyss)

struct AuroraBackground: View {
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isAnimated: Bool { animated && !reduceMotion }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.045, green: 0.075, blue: 0.115),
                         Color(red: 0.028, green: 0.055, blue: 0.09),
                         Theme.abyss],
                startPoint: .top, endPoint: .bottom)
            if isAnimated {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    blobs(t: t)
                }
            } else {
                blobs(t: 0)
            }
            // faint scanline texture
            ScanlineOverlay()
                .opacity(0.05)
        }
        .ignoresSafeArea()
    }

    func blobs(t: TimeInterval) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Circle()
                    .fill(Theme.holoDeep)
                    .frame(width: w * 0.7)
                    .position(x: w * (0.75 + 0.06 * sin(t * 0.11)),
                              y: h * (0.15 + 0.05 * cos(t * 0.09)))
                    .opacity(0.16)
                    .blur(radius: 110)
                Circle()
                    .fill(Theme.deepTeal)
                    .frame(width: w * 0.6)
                    .position(x: w * (0.12 + 0.05 * cos(t * 0.07)),
                              y: h * (0.85 + 0.04 * sin(t * 0.13)))
                    .opacity(0.18)
                    .blur(radius: 100)
                Circle()
                    .fill(Theme.copper)
                    .frame(width: w * 0.35)
                    .position(x: w * (0.28 + 0.05 * sin(t * 0.05 + 2)),
                              y: h * (0.25 + 0.06 * cos(t * 0.08 + 1)))
                    .opacity(0.07)
                    .blur(radius: 90)
            }
        }
    }
}

/// Ultra-subtle horizontal scanlines, HUD flavor.
struct ScanlineOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                         with: .color(Theme.holo.opacity(0.5)))
                y += 4
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Liquid glass card

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var glow = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.holo.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.glassEdge, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .shadow(color: glow ? Theme.holo.opacity(0.18) : .clear, radius: 24)
    }
}

// MARK: - Buttons

/// Primary action button — holographic gradient, bloom, hover lift.
/// (contentShape covers the full rounded rect — the glass-button gotcha.)
struct DistillButtonStyle: ButtonStyle {
    var prominent = true
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.accentGradient)
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        prominent ? AnyShapeStyle(Color.white.opacity(hovering ? 0.55 : 0.3))
                                  : AnyShapeStyle(Theme.glassEdge),
                        lineWidth: 1)
            )
            .foregroundStyle(prominent ? Theme.abyss : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: prominent ? Theme.holo.opacity(hovering ? 0.55 : 0.3) : .clear,
                    radius: hovering ? 18 : 10, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1))
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Small components

struct Pill: View {
    let text: String
    var color: Color = Theme.holo

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
            .foregroundStyle(color)
    }
}

struct CardHeader: View {
    let icon: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 28)
                .shadow(color: Theme.holo.opacity(0.5), radius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Holographic HUD hero (animated welcome centerpiece)

/// The app icon, alive: rotating tick rings, sweeping scan beam, a data lattice
/// whose ghost nodes phase in as they're "assembled", drifting particles.
struct HoloHUDView: View {
    var size: CGFloat = 220
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    canvas(t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // Static frame — a settled, legible pose of the HUD
                canvas(t: 8.2)
            }
        }
        .accessibilityLabel("Alembic — holographic data scanner")
    }

    func canvas(t: TimeInterval) -> some View {
        Canvas { ctx, canvasSize in
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let s = min(canvasSize.width, canvasSize.height)
            draw(in: &ctx, center: c, scale: s / 220.0, t: t)
        }
        .frame(width: size, height: size)
    }

    func draw(in ctx: inout GraphicsContext, center c: CGPoint, scale k: CGFloat, t: TimeInterval) {
        let holo = Theme.holo
        let bright = Theme.holoBright

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: c.x + x * k, y: c.y + y * k)
        }

        // Core bloom
        let bloom = Path(ellipseIn: CGRect(x: c.x - 70 * k, y: c.y - 70 * k, width: 140 * k, height: 140 * k))
        ctx.fill(bloom, with: .radialGradient(
            Gradient(colors: [holo.opacity(0.25), .clear]),
            center: c, startRadius: 0, endRadius: 70 * k))

        // Outer tick ring (rotates slowly)
        var ring = ctx
        ring.translateBy(x: c.x, y: c.y)
        ring.rotate(by: .radians(t * 0.25))
        ring.translateBy(x: -c.x, y: -c.y)
        let tickCircle = Path(ellipseIn: CGRect(x: c.x - 100 * k, y: c.y - 100 * k, width: 200 * k, height: 200 * k))
        ring.stroke(tickCircle, with: .color(holo.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 3 * k, dash: [1.5 * k, 8 * k]))

        // Arc segments (counter-rotate)
        var arcs = ctx
        arcs.translateBy(x: c.x, y: c.y)
        arcs.rotate(by: .radians(-t * 0.5))
        arcs.translateBy(x: -c.x, y: -c.y)
        for (start, len, opacity) in [(0.0, 1.5, 0.95), (2.4, 0.9, 0.6), (4.2, 1.2, 0.75)] {
            var arc = Path()
            arc.addArc(center: c, radius: 88 * k,
                       startAngle: .radians(start), endAngle: .radians(start + len), clockwise: false)
            arcs.stroke(arc, with: .color(bright.opacity(opacity)),
                        style: StrokeStyle(lineWidth: 2.5 * k, lineCap: .round))
        }

        // Scan beam sweep
        let beamAngle = t * 0.8
        var beam = ctx
        beam.translateBy(x: c.x, y: c.y)
        beam.rotate(by: .radians(beamAngle))
        beam.translateBy(x: -c.x, y: -c.y)
        var wedge = Path()
        wedge.move(to: c)
        wedge.addArc(center: c, radius: 96 * k, startAngle: .radians(-0.5), endAngle: .radians(0), clockwise: false)
        wedge.closeSubpath()
        beam.fill(wedge, with: .linearGradient(
            Gradient(colors: [holo.opacity(0.30), .clear]),
            startPoint: pt(96, 0), endPoint: pt(30, -48)))
        var beamLine = Path()
        beamLine.move(to: c)
        beamLine.addLine(to: pt(96, 0))
        beam.stroke(beamLine, with: .color(bright.opacity(0.85)), style: StrokeStyle(lineWidth: 1.6 * k))

        // Lattice
        let nodes: [(CGFloat, CGFloat)] = [(0, -44), (38, -22), (38, 22), (0, 44), (-38, 22), (-38, -22)]
        var lattice = Path()
        for (i, n) in nodes.enumerated() {
            lattice.move(to: c)
            lattice.addLine(to: pt(n.0, n.1))
            let next = nodes[(i + 1) % nodes.count]
            lattice.move(to: pt(n.0, n.1))
            lattice.addLine(to: pt(next.0, next.1))
        }
        ctx.stroke(lattice, with: .color(holo.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5 * k))

        // Nodes (breathing)
        let breathe = 1 + 0.08 * sin(t * 2)
        for (i, n) in nodes.enumerated() {
            let p = pt(n.0, n.1)
            let r = 5.5 * k * breathe
            let color = i == 4 ? Theme.amber : holo
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(color))
        }
        // Ghost nodes phasing in
        let phase = (sin(t * 1.2) + 1) / 2
        for g in [(62.0, -32.0), (-58.0, 40.0), (0.0, -70.0)] {
            let p = pt(g.0, g.1)
            let r = 4.5 * k
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                       with: .color(Theme.holoBright.opacity(0.25 + 0.5 * phase)),
                       style: StrokeStyle(lineWidth: 1.2 * k, dash: [2.5 * k, 2.5 * k]))
        }
        // Core
        let coreR = 9 * k * breathe
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
                 with: .color(bright))

        // Drifting particles
        for i in 0..<14 {
            let seed = Double(i) * 1.7
            let px = sin(t * 0.3 + seed * 2.1) * 95
            let py = cos(t * 0.22 + seed * 1.3) * 95
            let dist = (px * px + py * py).squareRoot()
            guard dist > 55 else { continue }
            let p = pt(px, py)
            let r = (1.2 + (i % 3 == 0 ? 1.0 : 0)) * k
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(holo.opacity(0.35 + 0.3 * sin(t + seed))))
        }
    }
}

// MARK: - Distillation run indicator (animated drip while pipeline runs)

struct RunPulseView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let w = size.width
                let midY = size.height / 2
                // flowing line
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: w, y: midY))
                ctx.stroke(path, with: .color(Theme.holo.opacity(0.25)), style: StrokeStyle(lineWidth: 2))
                // moving pulses
                for i in 0..<3 {
                    let progress = ((t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                    let x = progress * w
                    let r: CGFloat = 3.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: midY - r, width: r * 2, height: r * 2)),
                             with: .color(Theme.holoBright.opacity(1 - progress * 0.5)))
                }
            }
        }
        .frame(height: 10)
        .allowsHitTesting(false)
    }
}
