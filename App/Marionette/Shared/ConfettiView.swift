// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One burst of confetti that falls from the top edge of the view it covers, starting when the
/// view appears. Decoration only: lay it over content, and take it away again after ``duration``.
///
/// Drawn in a `Canvas`: over a sheet, a `CAEmitterLayer` started the same way each time draws its
/// pieces on some presentations and nothing on others.
struct ConfettiView: View {
    /// How long new pieces keep coming, in seconds.
    static let emissionTime = 2.0
    /// How long a piece is drawn, in seconds: the slowest falls about 1400 pt in that time, the
    /// height of a tall sheet.
    static let fallTime = 4.5
    /// From the first piece appearing to the last one having gone, in seconds.
    static let duration = emissionTime + fallTime
    /// Downward acceleration, in pt/s².
    private static let gravity = 110.0

    private static let pieces = Piece.burst(count: 220)
    private static let colours: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]
    fileprivate static let colourCount = colours.count

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in Self.pieces {
                    let age = elapsed - piece.delay
                    guard age >= 0, age <= Self.fallTime else { continue }
                    let y = -12 + piece.speed * age + Self.gravity * age * age / 2
                    guard y < size.height + 12 else { continue }
                    var layer = context
                    layer.translateBy(x: piece.x * size.width + piece.drift * age, y: y)
                    layer.rotate(by: .radians(piece.turn + piece.spin * age))
                    // Turning over as it falls: seen edge on, a piece is a line.
                    layer.scaleBy(x: 1, y: cos(piece.turn + piece.tumble * age))
                    let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2, width: piece.size.width, height: piece.size.height)
                    layer.fill(piece.isRound ? Path(ellipseIn: rect) : Path(rect), with: .color(Self.colours[piece.colour]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// How one piece of confetti moves.
private struct Piece {
    /// Where along the top edge it starts, 0 to 1.
    var x: Double
    /// When it starts, in seconds after the burst.
    var delay: Double
    /// Its speed downwards and sideways at the start, in pt/s.
    var speed: Double
    var drift: Double
    /// Its angle at the start, and how fast it spins and turns over, in radians and rad/s.
    var turn: Double
    var spin: Double
    var tumble: Double
    var size: CGSize
    var isRound: Bool
    var colour: Int

    /// Round and oblong pieces by turns, in each colour by turns, and otherwise at random.
    static func burst(count: Int) -> [Piece] {
        (0..<count).map { index in
            let isRound = index.isMultiple(of: 2)
            let scale = Double.random(in: 0.7...1.3)
            return Piece(
                x: .random(in: 0...1),
                delay: .random(in: 0...ConfettiView.emissionTime),
                speed: .random(in: 70...250),
                drift: .random(in: -70...70),
                turn: .random(in: 0...(2 * .pi)),
                spin: .random(in: -4...4),
                tumble: .random(in: 2...7),
                size: isRound ? CGSize(width: 8 * scale, height: 8 * scale) : CGSize(width: 10 * scale, height: 6 * scale),
                isRound: isRound,
                colour: index % ConfettiView.colourCount
            )
        }
    }
}
