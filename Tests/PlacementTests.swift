import CoreGraphics
import Testing
@testable import Shiftly

// The desk these tests model: a wide 3440x1440 primary with a 30pt menu
// bar and a dock, and a 1692x3008 portrait display on its left with the same top edge.
let band: Range<CGFloat> = 0..<30
let wide = SnapScreen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                      area: CGRect(x: 0, y: 30, width: 3440, height: 1359))
let tall = SnapScreen(frame: CGRect(x: -1692, y: 0, width: 1692, height: 3008),
                      area: snapArea(visible: CGRect(x: -1692, y: 0, width: 1692, height: 3008), menuBarBand: band))
let desk = [wide, tall]

/// A window that is in no snap position on the wide display.
let loose = CGRect(x: 400, y: 200, width: 1000, height: 700)

func press(_ start: CGRect, _ steps: [(Layer, Direction)], screens: [SnapScreen] = desk) -> Placement {
    var placement = Placement(window: start, layer: steps.first?.0 ?? .halves, screens: screens)
    for (layer, direction) in steps { placement.press(direction, layer: layer) }
    return placement
}

func expectRect(_ actual: CGRect, _ expected: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual.matches(expected, tolerance: 0.5), "got \(actual), want \(expected)", sourceLocation: sourceLocation)
}

func half(_ area: CGRect, _ side: Direction) -> CGRect {
    switch side {
    case .left: return CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
    case .right: return CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
    case .up: return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
    case .down: return CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
    }
}

@Suite struct GeometryTests {
    @Test func snapAreaStartsBelowTheMenuBarLine() {
        expectRect(tall.area, CGRect(x: -1692, y: 30, width: 1692, height: 2978))
    }

    @Test func snapAreaLeavesOtherDisplaysAlone() {
        // The primary already starts at the line, and a display above it never reaches the band.
        expectRect(snapArea(visible: wide.area, menuBarBand: band), wide.area)
        let above = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        expectRect(snapArea(visible: above, menuBarBand: band), above)
        let lower = CGRect(x: 3440, y: 400, width: 1920, height: 1080)
        expectRect(snapArea(visible: lower, menuBarBand: band), lower)
        // A hidden menu bar gives an empty band.
        expectRect(snapArea(visible: tall.frame, menuBarBand: 0..<0), tall.frame)
    }

    @Test func transposeIsItsOwnInverse() {
        #expect(loose.transposed.transposed == loose)
        for direction in [Direction.left, .right, .up, .down] {
            #expect(direction.transposed.transposed == direction)
        }
    }

    @Test func screenIndexFindsTheDisplayOrTheNearest() {
        #expect(screenIndex(containing: loose, in: desk) == 0)
        #expect(screenIndex(containing: CGRect(x: -900, y: 2000, width: 100, height: 100), in: desk) == 1)
        // Below the wide display, nearer to it than to the tall one.
        #expect(screenIndex(containing: CGRect(x: 2000, y: 1600, width: 100, height: 100), in: desk) == 0)
    }

    @Test func adjacentScreenFollowsTheArrangement() {
        #expect(adjacentScreen(from: 0, direction: .left, in: desk) == 1)
        #expect(adjacentScreen(from: 1, direction: .right, in: desk) == 0)
        #expect(adjacentScreen(from: 0, direction: .right, in: desk) == nil)
        #expect(adjacentScreen(from: 1, direction: .left, in: desk) == nil)
    }

    @Test func adjacentScreenPrefersAnOverlappingDisplay() {
        // Above-left is closer by centre, but only the far right display shares rows with the source.
        let source = SnapScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), area: .zero)
        let aboveLeft = SnapScreen(frame: CGRect(x: -900, y: -1200, width: 1000, height: 1000), area: .zero)
        let farLeft = SnapScreen(frame: CGRect(x: -3000, y: 0, width: 1000, height: 1000), area: .zero)
        #expect(adjacentScreen(from: 0, direction: .left, in: [source, aboveLeft, farLeft]) == 2)
    }

    @Test func proportionalRectKeepsTheFraction() {
        expectRect(proportionalRect(half(wide.area, .left), from: wide.area, to: tall.area), half(tall.area, .left))
        expectRect(proportionalRect(wide.area, from: wide.area, to: tall.area), tall.area)
    }
}

@Suite struct HalvesTests {
    let area = wide.area

    @Test func arrowsSnapToHalvesMaximizeAndCenter() {
        expectRect(press(loose, [(.halves, .left)]).preview, half(area, .left))
        expectRect(press(loose, [(.halves, .right)]).preview, half(area, .right))
        expectRect(press(loose, [(.halves, .up)]).preview, area)
        let center = press(loose, [(.halves, .down)]).preview
        #expect(abs(center.width - area.width * centerScale) < 0.5)
        #expect(abs(center.midX - area.midX) < 0.5 && abs(center.midY - area.midY) < 0.5)
    }

    @Test func twoArrowsMakeAQuarter() {
        let quarter = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2)
        expectRect(press(loose, [(.halves, .left), (.halves, .up)]).preview, quarter)
        let bottomRight = CGRect(x: area.midX, y: area.midY, width: area.width / 2, height: area.height / 2)
        expectRect(press(loose, [(.halves, .right), (.halves, .down)]).preview, bottomRight)
    }

    @Test func pushingIntoACoveredEdgeMaximizes() {
        expectRect(press(loose, [(.halves, .left), (.halves, .left)]).preview, area)
        expectRect(press(half(area, .left), [(.halves, .left)]).preview, area)
    }

    @Test func upTwiceGivesTheTopHalf() {
        expectRect(press(loose, [(.halves, .up), (.halves, .up)]).preview, half(area, .up))
    }

    @Test func walkingBackReturnsToTheStart() {
        let placement = press(loose, [(.halves, .left), (.halves, .right)])
        expectRect(placement.preview, loose)
    }

    @Test func aSnappedWindowSkipsTheUnsnapRung() {
        // From the left half, Right goes straight to the right half.
        expectRect(press(half(area, .left), [(.halves, .right)]).preview, half(area, .right))
    }

    @Test func everyPressFromASnapPositionChangesSomething() {
        let starts = [area, half(area, .left), half(area, .right), half(area, .up), half(area, .down),
                      CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2),
                      CGRect(x: area.midX, y: area.midY, width: area.width / 2, height: area.height / 2)]
        for start in starts {
            for direction in [Direction.left, .right, .up, .down] {
                let preview = press(start, [(.halves, direction)]).preview
                #expect(!preview.matches(start, tolerance: 0.5), "\(direction) from \(start) did nothing")
            }
        }
    }
}

@Suite struct ThirdsTests {
    @Test func landscapeWalksColumns() {
        let area = wide.area
        let third = area.width / 3
        expectRect(press(loose, [(.thirds, .left)]).preview,
                   CGRect(x: area.minX, y: area.minY, width: third, height: area.height))
        expectRect(press(loose, [(.thirds, .left), (.thirds, .right)]).preview,
                   CGRect(x: area.minX, y: area.minY, width: third * 2, height: area.height))
        expectRect(press(loose, [(.thirds, .left), (.thirds, .right), (.thirds, .right)]).preview,
                   CGRect(x: area.minX + third, y: area.minY, width: third, height: area.height))
        expectRect(press(loose, [(.thirds, .right)]).preview,
                   CGRect(x: area.minX + third * 2, y: area.minY, width: third, height: area.height))
    }

    @Test func walkingOffAnEndGoesFullscreen() {
        expectRect(press(loose, [(.thirds, .left), (.thirds, .left)]).preview, wide.area)
        expectRect(press(loose, [(.thirds, .right), (.thirds, .right)]).preview, wide.area)
    }

    @Test func landscapeSixthsSplitTheColumn() {
        let area = wide.area
        let topLeft = CGRect(x: area.minX, y: area.minY, width: area.width / 3, height: area.height / 2)
        expectRect(press(loose, [(.thirds, .left), (.thirds, .up)]).preview, topLeft)
        let bottomLeft = topLeft.offsetBy(dx: 0, dy: area.height / 2)
        expectRect(press(loose, [(.thirds, .left), (.thirds, .down)]).preview, bottomLeft)
    }

    @Test func aSixthDoesNotWalkIntoAnEndcap() {
        let placement = press(loose, [(.thirds, .left), (.thirds, .up), (.thirds, .left)])
        #expect(placement.preview.height < wide.area.height)
    }

    @Test func aSixthKeepsItsHalfAcrossANewGesture() {
        let area = wide.area
        let topLeftSixth = CGRect(x: area.minX, y: area.minY, width: area.width / 3, height: area.height / 2)
        let next = press(topLeftSixth, [(.thirds, .right)]).preview
        expectRect(next, CGRect(x: area.minX, y: area.minY, width: area.width * 2 / 3, height: area.height / 2))
    }

    @Test func portraitWalksRows() {
        let area = tall.area
        let row = area.height / 3
        let inside = CGRect(x: -1500, y: 400, width: 900, height: 900)
        expectRect(press(inside, [(.thirds, .up)]).preview,
                   CGRect(x: area.minX, y: area.minY, width: area.width, height: row))
        expectRect(press(inside, [(.thirds, .down)]).preview,
                   CGRect(x: area.minX, y: area.minY + row * 2, width: area.width, height: row))
        expectRect(press(inside, [(.thirds, .up), (.thirds, .down)]).preview,
                   CGRect(x: area.minX, y: area.minY, width: area.width, height: row * 2))
        expectRect(press(inside, [(.thirds, .up), (.thirds, .up)]).preview, area)
    }

    @Test func portraitSixthsAreNearlySquare() {
        let area = tall.area
        let inside = CGRect(x: -1500, y: 400, width: 900, height: 900)
        let topLeft = press(inside, [(.thirds, .up), (.thirds, .left)]).preview
        expectRect(topLeft, CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 3))
        let ratio = topLeft.width / topLeft.height
        #expect(ratio > 0.8 && ratio < 1.25, "sixth is \(topLeft.size)")

        let middleRight = press(inside, [(.thirds, .up), (.thirds, .down), (.thirds, .down), (.thirds, .right)]).preview
        expectRect(middleRight, CGRect(x: area.midX, y: area.minY + area.height / 3,
                                       width: area.width / 2, height: area.height / 3))
    }

    @Test func portraitSixthResumesInANewGesture() {
        let area = tall.area
        let topLeft = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 3)
        expectRect(press(topLeft, [(.thirds, .down)]).preview,
                   CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height * 2 / 3))
    }
}

@Suite struct DisplayTests {
    @Test func sendingKeepsTheRelativeRect() {
        let placement = press(half(wide.area, .left), [(.displays, .left)])
        expectRect(placement.preview, half(tall.area, .left))
        #expect(placement.screen == 1)
    }

    @Test func noDisplayThatWayIsReportedAndChangesNothing() {
        var placement = Placement(window: loose, layer: .displays, screens: desk)
        #expect(placement.press(.right, layer: .displays) == false)
        expectRect(placement.preview, loose)
    }

    @Test func aLayerAfterADisplayMoveActsOnTheNewDisplay() {
        // Left half on the wide display, sent left, then Up: the top-left quarter of the tall one.
        let placement = press(loose, [(.halves, .left), (.displays, .left), (.halves, .up)])
        let area = tall.area
        expectRect(placement.preview, CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2))
    }

    @Test func thirdsAfterADisplayMoveUseTheNewOrientation() {
        let placement = press(loose, [(.displays, .left), (.thirds, .up), (.thirds, .right)])
        let area = tall.area
        expectRect(placement.preview, CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height / 3))
    }

    @Test func maximizeAfterADisplayMoveFillsTheNewDisplay() {
        let placement = press(loose, [(.displays, .left), (.halves, .up)])
        expectRect(placement.preview, tall.area)
    }

    @Test func aBlockedPressAfterASnapStillLeavesAChangeToCommit() {
        // The commit compares against `start`. A layer change moves `original` to the preview.
        let placement = press(loose, [(.halves, .left), (.displays, .right)])
        expectRect(placement.preview, half(wide.area, .left))
        #expect(!placement.preview.matches(placement.start, tolerance: 0.5))
    }
}

@Suite struct FuzzTests {
    /// Deterministic, so a failure reproduces.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func previewsStayOnADisplay() {
        var rng = SplitMix(state: 42)
        let layers: [Layer] = [.halves, .thirds, .displays]
        let directions: [Direction] = [.left, .right, .up, .down]
        for _ in 0..<2000 {
            let start = Bool.random(using: &rng) ? half(wide.area, .right) : half(tall.area, .down)
            var placement = Placement(window: start, layer: .halves, screens: desk)
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                placement.press(directions.randomElement(using: &rng)!, layer: layers.randomElement(using: &rng)!)
                let preview = placement.preview
                let onSomeDisplay = desk.contains { $0.area.insetBy(dx: -0.5, dy: -0.5).contains(preview) }
                #expect(onSomeDisplay, "preview \(preview) left every display")
                #expect(preview.width >= 1 && preview.height >= 1)
            }
        }
    }
}
