/// Describes sampled references, never completeness of an application's windows.
struct WindowCoverage {
    enum Status: String { case noReferences, unusableReferences, referencesAvailable, truncated }
    let status: Status
    let usableRootCount: Int

    init(rootCount: Int, usableRootCount: Int, truncated: Bool) {
        self.usableRootCount = usableRootCount
        if truncated { status = .truncated }
        else if rootCount == 0 { status = .noReferences }
        else if usableRootCount == 0 { status = .unusableReferences }
        else { status = .referencesAvailable }
    }

    var json: [String: Any] {
        ["status": status.rawValue, "usableRootCount": usableRootCount,
         "confirmsEmptyWindowSet": false]
    }
}
