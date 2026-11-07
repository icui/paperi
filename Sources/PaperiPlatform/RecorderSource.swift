import Foundation

/// Owns installation of one native observer source on its original run loop.
/// Removal is idempotent and also happens when the recorder is released.
final class RecorderSource {
    private let source: CFRunLoopSource
    private let runLoop: CFRunLoop

    init(_ source: CFRunLoopSource, runLoop: CFRunLoop = CFRunLoopGetMain()) {
        self.source = source
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
    }

    var installed: Bool { CFRunLoopContainsSource(runLoop, source, .commonModes) }

    @discardableResult func remove() -> Bool {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        return !installed
    }

    deinit { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
}
