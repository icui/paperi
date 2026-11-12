import AppKit
import CoreGraphics
import PaperiCore

public enum TouchEvent: Equatable, Sendable {
    case begin(time: Double)
    case move(dx: Double, dy: Double, time: Double)
    case end(time: Double)
    case cancel
    /// A quick tap of all `fingers`, reported after every finger has lifted
    /// (and after the sequence's `.end`, if it began).
    case tap(time: Double)
}

@MainActor
public protocol TouchSource: AnyObject {
    var onEvent: ((TouchEvent) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
public final class EventTapTouchSource: TouchSource {
    public var onEvent: ((TouchEvent) -> Void)?
    public let fingers: Int
    public let verbose: Bool
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeTouches: [AnyHashable: CGPoint] = [:]
    private var tracking = false
    private var swipeTravel = 0.0
    private var ignoredContacts: Set<AnyHashable> = []
    private var establishedSwipe = false
    static let fingerUpGrace = 0.060
    /// Longest time from the first finger touching an empty trackpad to all
    /// swipe fingers down. One hand placing fingers lands them within about
    /// 10–50 ms (100 ms when sloppy); a scroll or resting finger joined by
    /// the other hand takes far longer and must not start a swipe.
    nonisolated public static let swipeLandingSpread = 0.15
    /// When each finger now on the trackpad was first seen down. Frames list
    /// every current touch, so fingers missing from a frame are dropped even
    /// if their lift was never reported.
    private var landedAt: [AnyHashable: Double] = [:]
    /// This sequence's fingers came together too slowly; no swipe starts
    /// until every finger lifts.
    private var staggered = false
    private var pendingReleaseTime: Double?
    private var releaseTask: Task<Void, Never>?
    private var appGestureBlocker: AppGestureBlocker?
    private static var activeInstance: EventTapTouchSource?
    /// Report `.tap` for quick taps of all `fingers`.
    public var recognizesTaps = false
    private var taps: TapRecognizer<AnyHashable>

    public init(fingers: Int = 3, verbose: Bool = false) {
        self.fingers = fingers
        self.verbose = verbose
        self.taps = TapRecognizer(fingers: fingers)
    }

    private func touchID(_ identity: any NSCopying) -> AnyHashable {
        if let h = identity as? AnyHashable { return h }
        return AnyHashable(ObjectIdentifier(identity as AnyObject))
    }

    public func start() {
        guard machPort == nil else { return }
        Self.activeInstance = self
        // Head-inserted taps run newest-first: start the app gesture blocker
        // before this tap so touch frames reach us before it withholds them.
        let blocker = AppGestureBlocker(fingers: fingers, verbose: verbose)
        blocker.start()
        appGestureBlocker = blocker
        let mask = CGEventMask(1 << 29)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = EventTapTouchSource.activeInstance?.machPort {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type.rawValue == 29 else { return Unmanaged.passUnretained(event) }
                if let nsEvent = NSEvent(cgEvent: event) {
                    let touches = nsEvent.allTouches()
                    let timestamp = nsEvent.timestamp
                    EventTapTouchSource.activeInstance?.processTouches(touches, at: timestamp)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            blocker.stop()
            appGestureBlocker = nil
            if verbose { FileHandle.standardError.write(Data("[paperi] failed to create gesture event tap\n".utf8)) }
            return
        }
        self.machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        if verbose { FileHandle.standardError.write(Data("[paperi] gesture event tap active for \(fingers) fingers\n".utf8)) }
    }

    public func stop() {
        appGestureBlocker?.stop()
        appGestureBlocker = nil
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                self.runLoopSource = nil
            }
            CFMachPortInvalidate(port)
            self.machPort = nil
        }
        clearPendingRelease()
        resetSwipeOwnership()
        if tracking {
            tracking = false
            activeTouches.removeAll()
            onEvent?(.cancel)
        }
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }

    struct Contact {
        let id: AnyHashable
        let position: CGPoint
        let phase: NSTouch.Phase
        /// Trackpad size in points (1/72 inch); converts positions to millimetres.
        var deviceSize = Self.typicalDeviceSize
        /// A 14-inch MacBook Pro trackpad, about 160 × 100 mm.
        static let typicalDeviceSize = CGSize(width: 454, height: 283)
    }

    private func clearPendingRelease() {
        releaseTask?.cancel()
        releaseTask = nil
        pendingReleaseTime = nil
    }

    // Keep the original lift time for release velocity, rather than the timer's
    // delayed delivery time. No further touch frames are required to finish.
    func finishPendingRelease(at timestamp: Double) {
        guard let liftedAt = pendingReleaseTime,
              timestamp >= liftedAt + Self.fingerUpGrace else { return }
        finish(.end(time: liftedAt))
    }

    private func resetSwipeOwnership() {
        establishedSwipe = false
        swipeTravel = 0
        ignoredContacts.removeAll()
        appGestureBlocker?.setSwipeEstablished(false)
    }

    private func finish(_ event: TouchEvent) {
        resetSwipeOwnership()
        clearPendingRelease()
        tracking = false
        activeTouches.removeAll()
        onEvent?(event)
    }

    func processTouches(_ touches: Set<NSTouch>, at timestamp: Double) {
        processContacts(touches.map {
            Contact(id: touchID($0.identity), position: $0.normalizedPosition, phase: $0.phase,
                    deviceSize: $0.deviceSize.width > 0 && $0.deviceSize.height > 0 ? $0.deviceSize : Contact.typicalDeviceSize)
        }, at: timestamp)
    }

    func processContacts(_ contacts: [Contact], at timestamp: Double, clicked: Bool = NSEvent.pressedMouseButtons != 0) {
        // Empty generic gesture frames are not evidence of a lift.
        guard !contacts.isEmpty else { return }
        guard recognizesTaps else { trackSwipe(contacts, at: timestamp); return }
        let mm = 25.4 / 72
        let tap = taps.observe(contacts.map {
            .init(id: $0.id, x: $0.position.x * $0.deviceSize.width * mm, y: $0.position.y * $0.deviceSize.height * mm,
                  down: $0.phase != .ended && $0.phase != .cancelled)
        }, at: timestamp, clicked: clicked, cancelled: contacts.contains { $0.phase == .cancelled })
        trackSwipe(contacts, at: timestamp)
        guard let (sample, verdict) = tap else { return }
        if verbose {
            let outcome = verdict == .tap ? "accepted" : { if case .rejected(let why) = verdict { return "rejected (\(why))" }; return "" }()
            FileHandle.standardError.write(Data("[paperi] tap \(outcome): \(sample.summary)\n".utf8))
        }
        guard verdict == .tap else { return }
        // Every finger is up: end the sequence now rather than after the
        // dropout grace, so the tap's effect follows the swipe's cleanup.
        if tracking, let liftedAt = pendingReleaseTime { finish(.end(time: liftedAt)) }
        onEvent?(.tap(time: timestamp))
    }

    private func trackSwipe(_ contacts: [Contact], at timestamp: Double) {
        let downIDs = contacts.filter { $0.phase != .ended && $0.phase != .cancelled }.map(\.id)
        landedAt = Dictionary(uniqueKeysWithValues: downIDs.map { ($0, landedAt[$0] ?? timestamp) })
        if downIDs.isEmpty { staggered = false }
        // Once motion establishes a swipe, newly appearing contacts are not
        // participants. Remember them through lifts so their cancellation or
        // continued presence cannot affect the original fingers' release.
        if tracking, establishedSwipe {
            for contact in contacts where activeTouches[contact.id] == nil && pendingReleaseTime == nil {
                ignoredContacts.insert(contact.id)
            }
        }
        let participants = contacts.filter { !ignoredContacts.contains($0.id) }
        let down = participants.filter { $0.phase != .ended && $0.phase != .cancelled }
        if tracking {
            if participants.contains(where: { $0.phase == .cancelled }) || down.count > fingers {
                finish(.cancel)
                return
            }
            if let liftedAt = pendingReleaseTime,
               timestamp >= liftedAt + Self.fingerUpGrace {
                finishPendingRelease(at: timestamp)
                return
            }
            if down.count < fingers {
                if pendingReleaseTime == nil {
                    pendingReleaseTime = timestamp
                    releaseTask = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .milliseconds(60)) }
                        catch { return }
                        self?.finishPendingRelease(at: timestamp + Self.fingerUpGrace)
                    }
                }
                return
            }
            if pendingReleaseTime != nil {
                // Contacts may return with new identities and positions. Resume
                // from this frame without counting the missing interval as motion.
                clearPendingRelease()
                activeTouches = Dictionary(uniqueKeysWithValues: down.map { ($0.id, $0.position) })
                if verbose { FileHandle.standardError.write(Data("[paperi] recovered brief finger dropout\n".utf8)) }
                return
            }

            guard down.allSatisfy({ activeTouches[$0.id] != nil }) else {
                finish(.cancel)
                return
            }
            var totalDx = 0.0
            var totalDy = 0.0
            var anyMoved = false
            for contact in down {
                let previous = activeTouches[contact.id]!
                let dx = contact.position.x - previous.x
                let dy = contact.position.y - previous.y
                totalDx += dx
                totalDy += dy
                if contact.phase == .moved || abs(dx) > 1e-5 || abs(dy) > 1e-5 { anyMoved = true }
                activeTouches[contact.id] = contact.position
            }
            if anyMoved {
                swipeTravel += hypot(totalDx / Double(down.count), totalDy / Double(down.count))
                if !establishedSwipe, swipeTravel >= 0.01 {
                    establishedSwipe = true
                    appGestureBlocker?.setSwipeEstablished(true)
                }
                onEvent?(.move(dx: totalDx / Double(down.count), dy: totalDy / Double(down.count), time: timestamp))
            }
        } else if down.count == fingers && down.count == contacts.count && !staggered {
            if let first = landedAt.values.min(), timestamp - first > Self.swipeLandingSpread {
                staggered = true
                if verbose {
                    let ms = Int((timestamp - first) * 1000)
                    FileHandle.standardError.write(Data("[paperi] swipe ignored: fingers joined over \(ms) ms\n".utf8))
                }
                return
            }
            resetSwipeOwnership()
            activeTouches = Dictionary(uniqueKeysWithValues: down.map { ($0.id, $0.position) })
            tracking = true
            if verbose { FileHandle.standardError.write(Data("[paperi] touch gesture began with \(fingers) fingers\n".utf8)) }
            onEvent?(.begin(time: timestamp))
        }
    }
}
