import ApplicationServices

/// Fresh references only; nothing is carried across recorder lifetimes.
enum RecorderWindowDiscovery {
    struct Window {
        let element: AXUIElement
        var sources: Set<String>
    }
    struct Result {
        let windows: [Window]
        let rejectedCount: Int
    }

    static func collect(enumerated: [AXUIElement], focused: AXUIElement?, main: AXUIElement?,
                        children: [AXUIElement] = [], pid: pid_t,
                        metadata: (AXUIElement) -> (pid: pid_t?, role: String?)) -> Result {
        var windows: [Window] = []
        var rejected = 0
        let candidates = enumerated.map { ($0, "AXWindows") } +
            (focused.map { [($0, "AXFocusedWindow")] } ?? []) + (main.map { [($0, "AXMainWindow")] } ?? []) +
            children.map { ($0, "AXChildren") }
        for (element, source) in candidates {
            if let index = windows.firstIndex(where: { CFEqual($0.element, element) }) {
                windows[index].sources.insert(source)
                continue
            }
            let facts = metadata(element)
            guard WindowReferenceValidation.rejection(pid: facts.pid, role: facts.role, expectedPID: pid) == nil else {
                rejected += 1
                continue
            }
            windows.append(Window(element: element, sources: [source]))
        }
        return Result(windows: windows, rejectedCount: rejected)
    }
}
