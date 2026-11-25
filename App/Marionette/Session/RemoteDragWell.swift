// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import UIKit
import MarionetteKit

/// The target for copying files dragged on the remote computer to this device.
///
/// Shown over the remote picture while such a drag is under way. The remote pointer cannot leave
/// the picture, so the well lies within its visible part; it lights up while the pointer is over it,
/// and letting go there copies the files. The dragging finger belongs to the remote computer, so the
/// well takes no touches.
///
/// Serves both the device's stage and an attached monitor: with the picture only on the monitor,
/// the pointer is watched, and the well shown, there.
struct RemoteDragWell: View {
    let session: SessionModel
    let surface: PictureSurface
    /// How much larger than on the device the well is drawn: a monitor is looked at from further away.
    var magnification: CGFloat = 1

    @Environment(\.foldContext) private var fold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The surface's coordinate space, as the well's frame is reported in it.
    private nonisolated static let space = "remote-drag-well"

    /// The files being dragged, if this surface is the one to say so.
    private var drag: RemoteFileDrag? {
        session.dropWellSurface == surface ? session.fileDrags.remoteDrag : nil
    }

    var body: some View {
        let drag = drag
        ZStack(alignment: .topLeading) {
            Color.clear
            if let drag, let region = region {
                Magnified(factor: magnification) {
                    Well(drag: drag, isTargeted: session.fileDrags.isPointerOverDropWell)
                        .scaleEffect(magnification)
                }
                // For hit-testing the remote pointer. Only plain layout lies between here and the
                // surface, so this is the frame as drawn.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                    session.fileDrags.setDropWellFrame(ViewRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
                }
                .onDisappear { session.fileDrags.setDropWellFrame(nil) }
                .padding(12)
                .frame(width: region.width, height: region.height, alignment: .top)
                .padding(.leading, region.minX)
                .padding(.top, region.minY)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .coordinateSpace(.named(Self.space))
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: drag != nil)
        .allowsHitTesting(false)
    }

    /// The part of the surface the well may use: the visible picture, and of that the side after
    /// the fold when the device is held like a book, where the other floating controls are too.
    private var region: CGRect? {
        guard var region = session.visiblePicture(on: surface).map(CGRect.init) else { return nil }
        if surface == .device, fold.pose == .book, let division = fold.division {
            let after = region.intersection(CGRect(x: division.maxX + 8, y: region.minY, width: max(0, region.maxX - division.maxX - 8), height: region.height))
            if !after.isNull, after.width >= 160 { region = after }
        }
        return region
    }
}

/// Gives its content, drawn `factor` times its size, that much room. A bare `scaleEffect` draws
/// larger but takes the room of the original, which would put the well's frame at odds with what
/// is seen.
private struct Magnified: Layout {
    var factor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 / factor }, height: proposal.height.map { $0 / factor }))
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: bounds.width / factor, height: bounds.height / factor)
        )
    }
}

private struct Well: View {
    let drag: RemoteFileDrag
    let isTargeted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var picture: UIImage?

    private var device: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private var contents: String {
        guard drag.paths.count == 1, let name = drag.paths[0].split(separator: "/").last else { return String(localized: "\(drag.paths.count) Items") }
        return String(name)
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: drag.paths.count == 1 ? "doc" : "doc.on.doc")
                        .font(.title2)
                }
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Copy to \(device)")
                    .font(.headline)
                Text(contents)
                    .font(.subheadline)
                    .foregroundStyle(isTargeted ? .primary : .secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.middle)
            }
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(isTargeted ? .primary : .secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(minWidth: 220, minHeight: 64)
        // Takes no touches, so no large content viewer; it grows with the text as far as its place
        // at the top of the picture allows.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .glassEffect(isTargeted ? .regular.tint(.prominentFill) : .regular, in: .rect(cornerRadius: 24))
        // Dashed while waiting; solid and tinted while the pointer is over it, when letting go copies.
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: isTargeted ? [] : [7, 5]))
                .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.55))
        }
        .scaleEffect(isTargeted && !reduceMotion ? 1.04 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isTargeted)
        // Like the bars, this floats over a picture whose surround is black.
        .environment(\.colorScheme, .dark)
        .task(id: drag.previewPNG) {
            picture = drag.previewPNG.flatMap(UIImage.init(data:))
        }
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "Files are being dragged on the remote computer.")).post()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copy to \(device)")
        .accessibilityValue(isTargeted ? String(localized: "\(contents), let go to copy") : contents)
        .accessibilityHint("Carry the files here and let go to copy them to this \(device).")
        .accessibilityIdentifier("remote-drag-well")
    }
}
