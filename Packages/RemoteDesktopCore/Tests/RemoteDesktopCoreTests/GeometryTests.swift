// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import Testing

@Suite struct GeometryTests {
    @Test func rectIntersectionAndUnion() {
        let a = PixelRect(x: 0, y: 0, width: 10, height: 10)
        let b = PixelRect(x: 5, y: 5, width: 10, height: 10)
        #expect(a.intersection(b) == PixelRect(x: 5, y: 5, width: 5, height: 5))
        #expect(a.union(b) == PixelRect(x: 0, y: 0, width: 15, height: 15))
        #expect(a.intersects(b))
        #expect(!a.intersects(PixelRect(x: 10, y: 0, width: 5, height: 5)))
        #expect(a.intersection(PixelRect(x: 20, y: 20, width: 1, height: 1)).isEmpty)
    }

    @Test func emptyRectContributesNothingToUnion() {
        let a = PixelRect(x: 3, y: 4, width: 5, height: 6)
        let empty = PixelRect(x: 100, y: 100, width: 0, height: 9)
        #expect(a.union(empty) == a)
        #expect(empty.union(a) == a)
    }

    @Test func damageDropsContainedRectangles() {
        var damage = DamageRegion(PixelRect(x: 0, y: 0, width: 100, height: 100))
        damage.add(PixelRect(x: 10, y: 10, width: 5, height: 5))
        #expect(damage.rectangles.count == 1)

        var other = DamageRegion(PixelRect(x: 10, y: 10, width: 5, height: 5))
        other.add(PixelRect(x: 0, y: 0, width: 100, height: 100))
        #expect(other.rectangles == [PixelRect(x: 0, y: 0, width: 100, height: 100)])
    }

    @Test func damageCollapsesToBoundsWhenLarge() {
        var damage = DamageRegion()
        for index in 0..<(DamageRegion.maximumRectangles + 1) {
            damage.add(PixelRect(x: index * 10, y: index * 10, width: 4, height: 4))
        }
        #expect(damage.rectangles.count == 1)
        let last = DamageRegion.maximumRectangles * 10
        #expect(damage.bounds == PixelRect(x: 0, y: 0, width: last + 4, height: last + 4))
    }

    @Test func damageIgnoresEmptyAndClips() {
        var damage = DamageRegion()
        damage.add(PixelRect(x: 0, y: 0, width: 0, height: 10))
        #expect(damage.isEmpty)
        damage.add(PixelRect(x: -10, y: -10, width: 30, height: 30))
        let clipped = damage.clipped(to: PixelRect(x: 0, y: 0, width: 10, height: 10))
        #expect(clipped.rectangles == [PixelRect(x: 0, y: 0, width: 10, height: 10)])
        #expect(damage.clipped(to: PixelRect(x: 500, y: 500, width: 10, height: 10)).isEmpty)
    }

    @Test func layoutFindsDisplayUnderPoint() {
        let left = RemoteDisplay(id: DisplayID(1), name: "L", kind: .physical, frameInDesktop: PixelRect(x: 0, y: 0, width: 100, height: 50))
        let right = RemoteDisplay(id: DisplayID(2), name: "R", kind: .physical, frameInDesktop: PixelRect(x: 100, y: 0, width: 200, height: 80))
        let layout = DesktopLayout(generation: 1, displays: [left, right])
        #expect(layout.bounds == PixelRect(x: 0, y: 0, width: 300, height: 80))
        #expect(layout.display(at: PixelPoint(x: 99.5, y: 10))?.id == DisplayID(1))
        #expect(layout.display(at: PixelPoint(x: 100, y: 10))?.id == DisplayID(2))
        #expect(layout.display(at: PixelPoint(x: 50, y: 60)) == nil)
        #expect(layout[DisplayID(2)]?.name == "R")
    }

    @Test func modifierHelpersTreatSidesAlike() {
        #expect(KeyModifiers.rightCommand.hasCommand)
        #expect(!KeyModifiers.leftOption.hasCommand)
        #expect(KeyCode.rightShift.modifier == .rightShift)
        #expect(KeyCode.a.modifier == nil)
    }
}
