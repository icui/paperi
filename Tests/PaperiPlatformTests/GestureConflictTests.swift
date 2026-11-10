import Foundation
import Testing
@testable import PaperiPlatform

struct GestureConflictTests {
    let cleanThreeFinger: [String: [String: Any]] = [
        "com.apple.AppleMultitouchTrackpad": [
            "TrackpadThreeFingerHorizSwipeGesture": 0,
            "TrackpadThreeFingerVertSwipeGesture": 0,
            "TrackpadThreeFingerDrag": 0,
            "TrackpadThreeFingerTapGesture": 2
        ],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [
            "TrackpadThreeFingerHorizSwipeGesture": 0,
            "TrackpadThreeFingerVertSwipeGesture": 0,
            "TrackpadThreeFingerDrag": 0,
            "TrackpadThreeFingerTapGesture": 2
        ]
    ]

    @Test func cleanSettingsHaveNoConflicts() {
        let conflicts = GestureConflict.conflicts(in: cleanThreeFinger, fingers: 3)
        #expect(conflicts.isEmpty)
    }

    @Test func horizontalSwipeConflictDetected() {
        var prefs = cleanThreeFinger
        prefs["com.apple.AppleMultitouchTrackpad"]?["TrackpadThreeFingerHorizSwipeGesture"] = 1
        let conflicts = GestureConflict.conflicts(in: prefs, fingers: 3)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].contains("TrackpadThreeFingerHorizSwipeGesture = 1"))
    }

    @Test func verticalSwipeConflictDetected() {
        var prefs = cleanThreeFinger
        prefs["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?["TrackpadThreeFingerVertSwipeGesture"] = 2
        let conflicts = GestureConflict.conflicts(in: prefs, fingers: 3)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].contains("TrackpadThreeFingerVertSwipeGesture = 2"))
    }

    @Test func threeFingerDragConflictDetected() {
        var prefs = cleanThreeFinger
        prefs["com.apple.AppleMultitouchTrackpad"]?["TrackpadThreeFingerDrag"] = 1
        let conflicts = GestureConflict.conflicts(in: prefs, fingers: 3)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].contains("TrackpadThreeFingerDrag = 1"))
    }

    @Test func tapGestureIsHarmless() {
        var prefs = cleanThreeFinger
        prefs["com.apple.AppleMultitouchTrackpad"]?["TrackpadThreeFingerTapGesture"] = 1
        let conflicts = GestureConflict.conflicts(in: prefs, fingers: 3)
        #expect(conflicts.isEmpty)
    }

    @Test func missingKeyTreatedAsConflict() {
        var prefs = cleanThreeFinger
        prefs["com.apple.AppleMultitouchTrackpad"]?.removeValue(forKey: "TrackpadThreeFingerHorizSwipeGesture")
        let conflicts = GestureConflict.conflicts(in: prefs, fingers: 3)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].contains("TrackpadThreeFingerHorizSwipeGesture missing"))
    }

    @Test func fourFingerSettingsCheckedWhenConfigured() {
        let prefs: [String: [String: Any]] = [
            "com.apple.AppleMultitouchTrackpad": [
                "TrackpadFourFingerHorizSwipeGesture": 2,
                "TrackpadFourFingerVertSwipeGesture": 0
            ]
        ]
        let conflicts = GestureConflict.conflicts(in: prefs, fingers: 4)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].contains("TrackpadFourFingerHorizSwipeGesture = 2"))
    }
}
