import ApplicationServices

/// One fresh retry for a transient AX transport failure; no cached role fallback.
enum TabRoleRead {
    struct Result {
        let role: String?
        let errors: [AXError]
    }

    static func collect(withinBudget: () -> Bool, read: () -> (AXError, String?)) -> Result {
        let first = read()
        var final = first
        var errors = [first.0]
        if first.0 == .cannotComplete, withinBudget() {
            final = read()
            errors.append(final.0)
        }
        let role = final.0 == .success ? final.1.flatMap { $0.isEmpty ? nil : $0 } : nil
        return Result(role: role, errors: errors)
    }
}
