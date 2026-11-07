import Foundation
import Testing
@testable import PaperiPlatform

@MainActor struct RecorderSourceTests {
    private final class Counter { var calls = 0 }

    private func source(_ counter: Counter = Counter()) -> CFRunLoopSource {
        var context = CFRunLoopSourceContext()
        // Distinct contexts matter: two empty version-zero sources compare equal.
        context.info = Unmanaged.passRetained(counter).toOpaque()
        context.release = { info in Unmanaged<Counter>.fromOpaque(info!).release() }
        context.perform = { info in Unmanaged<Counter>.fromOpaque(info!).takeUnretainedValue().calls += 1 }
        return CFRunLoopSourceCreate(nil, 0, &context)
    }

    @Test func nativeSourceRemovalIsIdempotentAndReplacementIsIndependent() {
        let old = source()
        let replacement = source()
        let owner = RecorderSource(old)
        #expect(owner.installed)
        #expect(owner.remove())
        #expect(owner.remove())
        #expect(!CFRunLoopContainsSource(CFRunLoopGetMain(), old, .commonModes))
        let next = RecorderSource(replacement)
        #expect(next.installed)
        #expect(!owner.installed)
        #expect(owner.remove())
        #expect(next.installed)
        #expect(next.remove())
    }

    @Test func releasingOwnerRemovesNativeSource() {
        let native = source()
        var owner: RecorderSource? = RecorderSource(native)
        weak var released = owner
        #expect(CFRunLoopContainsSource(CFRunLoopGetMain(), native, .commonModes))
        owner = nil
        #expect(released == nil)
        released = nil
        #expect(!CFRunLoopContainsSource(CFRunLoopGetMain(), native, .commonModes))
    }

    @Test func removedNativeSourceCannotDeliverQueuedCallbacks() {
        let counter = Counter()
        let native = source(counter)
        let owner = RecorderSource(native)
        CFRunLoopSourceSignal(native)
        CFRunLoopRunInMode(.defaultMode, 0.001, true)
        #expect(counter.calls == 1)
        CFRunLoopSourceSignal(native)
        #expect(owner.remove())
        CFRunLoopRunInMode(.defaultMode, 0.001, true)
        #expect(counter.calls == 1)
    }
}
