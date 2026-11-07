import Foundation

/// A source reporting a reference as a window is not affirmative window evidence.
enum WindowReferenceValidation {
    enum Rejection: String {
        case ownerUnavailable, foreignOwner, roleUnavailable, nonWindowRole
    }

    static func rejection(pid: pid_t?, role: String?, expectedPID: pid_t) -> Rejection? {
        guard let pid else { return .ownerUnavailable }
        guard pid == expectedPID else { return .foreignOwner }
        guard let role, !role.isEmpty else { return .roleUnavailable }
        guard ["AXWindow", "AXSheet"].contains(role) else { return .nonWindowRole }
        return nil
    }
}
