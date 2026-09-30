import XCTest
@testable import VestalCore

final class PinchGestureTests: XCTestCase {
    func testDirectionWaitsForTheDeadZone() {
        XCTAssertNil(PinchMath.direction(ratio: 1))
        XCTAssertNil(PinchMath.direction(ratio: 0.97))
        XCTAssertNil(PinchMath.direction(ratio: 1.03))
        XCTAssertEqual(PinchMath.direction(ratio: 0.95), .together)
        XCTAssertEqual(PinchMath.direction(ratio: 1.05), .apart)
    }

    func testProgressFollowsTheRatio() {
        XCTAssertEqual(PinchMath.progress(.together, ratio: 1), 0, accuracy: 1e-6)
        XCTAssertEqual(PinchMath.progress(.together, ratio: 0.86), 0.5, accuracy: 1e-5)
        XCTAssertEqual(PinchMath.progress(.together, ratio: PinchMath.togetherFullRatio), 1, accuracy: 1e-6)
        XCTAssertEqual(PinchMath.progress(.together, ratio: 0.3), 1)
        XCTAssertEqual(PinchMath.progress(.together, ratio: 1.2), 0)
        XCTAssertEqual(PinchMath.progress(.apart, ratio: 1), 0, accuracy: 1e-6)
        XCTAssertEqual(PinchMath.progress(.apart, ratio: 1.175), 0.5, accuracy: 1e-5)
        XCTAssertEqual(PinchMath.progress(.apart, ratio: PinchMath.apartFullRatio), 1, accuracy: 1e-6)
        XCTAssertEqual(PinchMath.progress(.apart, ratio: 2), 1)
        XCTAssertEqual(PinchMath.progress(.apart, ratio: 0.8), 0)
    }

    func testCommitPastHalfOrOnAFlick() {
        XCTAssertTrue(PinchMath.shouldCommit(progress: 0.6, velocity: 0))
        XCTAssertFalse(PinchMath.shouldCommit(progress: 0.4, velocity: 0))
        XCTAssertFalse(PinchMath.shouldCommit(progress: 0.4, velocity: -3))
        XCTAssertTrue(PinchMath.shouldCommit(progress: 0.2, velocity: PinchMath.flickVelocity + 1))
    }
}
