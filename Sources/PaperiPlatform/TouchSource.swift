import AppKit
import CoreGraphics

public enum TouchEvent: Equatable, Sendable {
    case begin(time: Double)
    case move(dx: Double, dy: Double, time: Double)
    case end(time: Double)
    case cancel
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
    private static var activeInstance: EventTapTouchSource?

    public init(fingers: Int = 3, verbose: Bool = false) {
        self.fingers = fingers
        self.verbose = verbose
    }

    private func touchID(_ identity: any NSCopying) -> AnyHashable {
        if let h = identity as? AnyHashable { return h }
        return AnyHashable(ObjectIdentifier(identity as AnyObject))
    }

    public func start() {
        guard machPort == nil else { return }
        Self.activeInstance = self
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
                    let timestamp = ProcessInfo.processInfo.systemUptime
                    EventTapTouchSource.activeInstance?.processTouches(touches, at: timestamp)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
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
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                self.runLoopSource = nil
            }
            CFMachPortInvalidate(port)
            self.machPort = nil
        }
        if tracking {
            tracking = false
            activeTouches.removeAll()
            onEvent?(.cancel)
        }
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }

    func processTouches(_ touches: Set<NSTouch>, at timestamp: Double) {
        if tracking {
            let ended = touches.contains { $0.phase == .ended || $0.phase == .cancelled }
            if touches.count != fingers || ended {
                tracking = false
                activeTouches.removeAll()
                if verbose { FileHandle.standardError.write(Data("[paperi] touch gesture ended (touches=\(touches.count), ended=\(ended))\n".utf8)) }
                onEvent?(.end(time: timestamp))
                return
            }

            var allMatch = true
            var totalDx = 0.0
            var totalDy = 0.0
            var anyMoved = false

            for touch in touches {
                let id = touchID(touch.identity)
                guard let prev = activeTouches[id] else {
                    allMatch = false
                    break
                }
                let pos = touch.normalizedPosition
                let dx = pos.x - prev.x
                let dy = pos.y - prev.y
                totalDx += dx
                totalDy += dy
                if touch.phase == .moved || abs(dx) > 1e-5 || abs(dy) > 1e-5 {
                    anyMoved = true
                }
                activeTouches[id] = pos
            }

            if !allMatch {
                tracking = false
                activeTouches.removeAll()
                onEvent?(.end(time: timestamp))
                return
            }

            if anyMoved {
                let count = Double(touches.count)
                let avgDx = totalDx / count
                let avgDy = totalDy / count
                onEvent?(.move(dx: avgDx, dy: avgDy, time: timestamp))
            }
        } else {
            if touches.count == fingers && touches.allSatisfy({ $0.phase != .ended && $0.phase != .cancelled }) {
                activeTouches.removeAll()
                for touch in touches {
                    activeTouches[touchID(touch.identity)] = touch.normalizedPosition
                }
                tracking = true
                if verbose { FileHandle.standardError.write(Data("[paperi] touch gesture began with \(fingers) fingers\n".utf8)) }
                onEvent?(.begin(time: timestamp))
            }
        }
    }
}
