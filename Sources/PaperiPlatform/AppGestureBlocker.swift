import CoreGraphics
import Foundation
import PaperiBridge

/// Decides which app-facing trackpad events to withhold while the swipe
/// gesture's fingers are down, so scrolling, pinching, rotating and page
/// swipes in the focused app do not run alongside a strip swipe.
///
/// A touch sequence is claimed once exactly `fingers` contacts are down and
/// stays claimed until every finger has lifted, so lifting fingers one at a
/// time does not leak a two-finger scroll at the end of a swipe.
///
/// Before swipe motion is established, more than `fingers` contacts belongs to the
/// system (four-finger Spaces/Mission Control swipes, four- and five-finger
/// pinches, delivered to the Dock as these same gesture events). It is
/// released at once and left alone until every finger lifts. Fingers land a
/// few milliseconds apart, so such a gesture briefly passes through exactly
/// `fingers` contacts and is claimed for those frames.
///
/// macOS still emits ordinary phased scroll events while three fingers move,
/// and apps can also drive gestures from raw touch frames, so both are
/// withheld. Paperi's own touch tap sits ahead of this filter and still sees
/// the touch frames. Whatever an app saw begin (scroll, gesture bracket) is
/// allowed to end, so no app is left mid-gesture.
///
/// Finger counts come from the trackpad itself (`fingers(down:)`), not from
/// parsing touch events, so deciding is cheap and never waits on AppKit.
struct AppGestureFilter: Equatable {
    enum Input: Equatable {
        /// Current number of fingers on the trackpad, and seconds from the
        /// first of them touching an empty trackpad to the latest landing.
        /// Never dropped.
        case fingers(down: Int, landingSpread: Double = 0)
        /// A touch (NSEventTypeGesture) frame.
        case touchFrame
        /// A scroll wheel event. Phases use CGScrollPhase / CGMomentumScrollPhase values.
        case scroll(phase: Int64, momentum: Int64, continuous: Bool)
        /// Magnify, rotate, swipe or smart-magnify.
        case gesture
        /// Begin/end gesture bracket events.
        case gestureBegin
        case gestureEnd
    }

    static let phaseBegan: Int64 = 1
    static let phaseChanged: Int64 = 2
    static let phaseEnded: Int64 = 4
    static let phaseCancelled: Int64 = 8
    static let phaseMayBegin: Int64 = 128
    static let momentumEnd: Int64 = 3

    let fingers: Int
    private(set) var claimed = false
    var swipeEstablished = false
    /// More fingers than the swipe uses were down in this sequence.
    private(set) var systemSequence = false
    /// The swipe's fingers came together too slowly to be one hand placing
    /// them (e.g. a scroll joined by the other hand). Like the touch source,
    /// leave the sequence to apps until every finger lifts.
    private(set) var staggeredSequence = false
    /// Momentum from a scroll that was cut off by a claimed sequence.
    private(set) var swallowMomentum = false
    /// The app has seen a scroll begin without its end.
    private(set) var appScrollOpen = false
    /// The app has seen a begin-gesture without its end.
    private(set) var appGestureOpen = false

    init(fingers: Int) { self.fingers = fingers }

    /// Returns true when the event should be dropped.
    mutating func shouldDrop(_ input: Input) -> Bool {
        switch input {
        case .fingers(let down, let landingSpread):
            if down == 0 {
                claimed = false
                systemSequence = false
                staggeredSequence = false
            } else if down > fingers, !swipeEstablished {
                claimed = false
                systemSequence = true
            } else if down == fingers, !claimed, !systemSequence, !staggeredSequence,
                      landingSpread > EventTapTouchSource.swipeLandingSpread {
                staggeredSequence = true
            } else if down == fingers, !claimed, !systemSequence, !staggeredSequence {
                claimed = true
                swallowMomentum = true
            }
            return false

        case .touchFrame:
            return claimed

        case .gesture:
            return claimed

        case .gestureBegin:
            if claimed { return true }
            appGestureOpen = true
            return false

        case .gestureEnd:
            if appGestureOpen {
                appGestureOpen = false
                return false
            }
            return claimed

        case .scroll(let phase, let momentum, let continuous):
            // Mouse wheels are never part of a trackpad gesture.
            guard continuous else { return false }
            if claimed {
                // Let an already-open app scroll close cleanly.
                if appScrollOpen, phase == Self.phaseEnded || phase == Self.phaseCancelled {
                    appScrollOpen = false
                    return false
                }
                return true
            }
            if momentum != 0, swallowMomentum {
                if momentum == Self.momentumEnd { swallowMomentum = false }
                return true
            }
            if phase == Self.phaseBegan || phase == Self.phaseMayBegin {
                swallowMomentum = false
            }
            if phase == Self.phaseBegan || phase == Self.phaseChanged {
                appScrollOpen = true
            } else if phase == Self.phaseEnded || phase == Self.phaseCancelled {
                appScrollOpen = false
            }
            return false
        }
    }
}

/// An active session event tap, serviced on its own thread so a busy main
/// thread never delays scrolling, that withholds app gestures while the
/// swipe gesture's fingers are down. See `AppGestureFilter`.
final class AppGestureBlocker: @unchecked Sendable {
    private let fingers: Int
    private let verbose: Bool
    private let lock = NSLock()
    // Accessed only on the tap thread once started.
    private var establishedSwipe = false
    private var filter: AppGestureFilter
    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var droppedThisSequence = 0

    private static let gestureTypes: [UInt32] = [
        18, // rotate
        30, // magnify
        31, // swipe
        32  // smart magnify
    ]
    private static let touchType: UInt32 = 29
    private static let beginGestureType: UInt32 = 19
    private static let endGestureType: UInt32 = 20

    init(fingers: Int, verbose: Bool) {
        self.fingers = fingers
        self.verbose = verbose
        self.filter = AppGestureFilter(fingers: fingers)
    }

    func setSwipeEstablished(_ established: Bool) {
        lock.lock()
        establishedSwipe = established
        lock.unlock()
    }

    func start() {
        let trackpads = paperi_mt_start()
        guard trackpads > 0 else {
            if verbose { FileHandle.standardError.write(Data("[paperi] no trackpad finger source; app gestures are not blocked\n".utf8)) }
            return
        }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [self] in
            self.runTap(ready: ready)
        }
        t.name = "paperi.app-gesture-blocker"
        t.qualityOfService = .userInteractive
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        thread = t
        lock.unlock()
        // The tap thread takes `lock` to publish its port, so never wait while holding it.
        t.start()
        ready.wait()
    }

    func stop() {
        lock.lock()
        let port = machPort, loop = runLoop
        machPort = nil; runLoop = nil; thread = nil
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
        paperi_mt_stop()
    }

    private func runTap(ready: DispatchSemaphore) {
        var mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        mask |= CGEventMask(1) << CGEventMask(Self.touchType)
        mask |= CGEventMask(1) << CGEventMask(Self.beginGestureType)
        mask |= CGEventMask(1) << CGEventMask(Self.endGestureType)
        for type in Self.gestureTypes { mask |= CGEventMask(1) << CGEventMask(type) }
        let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let blocker = Unmanaged<AppGestureBlocker>.fromOpaque(userInfo).takeUnretainedValue()
                return blocker.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let port else {
            if verbose { FileHandle.standardError.write(Data("[paperi] failed to create app gesture blocking tap\n".utf8)) }
            ready.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.lock()
        machPort = port
        runLoop = loop
        lock.unlock()
        ready.signal()
        if verbose { FileHandle.standardError.write(Data("[paperi] blocking app gestures during \(fingers)-finger swipes\n".utf8)) }
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, .commonModes)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = machPort; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let input: AppGestureFilter.Input
        if type == .scrollWheel {
            input = .scroll(
                phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            )
        } else if type.rawValue == Self.touchType {
            input = .touchFrame
        } else if type.rawValue == Self.beginGestureType {
            input = .gestureBegin
        } else if type.rawValue == Self.endGestureType {
            input = .gestureEnd
        } else if Self.gestureTypes.contains(type.rawValue) {
            input = .gesture
        } else {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        filter.swipeEstablished = establishedSwipe
        lock.unlock()
        let wasClaimed = filter.claimed
        _ = filter.shouldDrop(.fingers(down: Int(paperi_mt_fingers_down()), landingSpread: paperi_mt_landing_spread()))
        let drop = filter.shouldDrop(input)
        if drop { droppedThisSequence += 1 }
        if verbose, wasClaimed != filter.claimed {
            if filter.claimed {
                FileHandle.standardError.write(Data("[paperi] app gestures blocked (\(fingers) fingers down)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("[paperi] app gestures released (dropped \(droppedThisSequence) events)\n".utf8))
                droppedThisSequence = 0
            }
        }
        return drop ? nil : Unmanaged.passUnretained(event)
    }
}
