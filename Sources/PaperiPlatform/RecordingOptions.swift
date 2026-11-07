import Foundation

public struct RecordingOptions {
    public let seconds: Double
    public let bundleIDs: Set<String>?
    public let includeTabEvidence: Bool

    public enum InvalidArguments: Error { case usage }

    public init(arguments: [String]) throws {
        var seconds: Double?
        var bundleIDs: Set<String> = []
        var includeTabEvidence = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--tab-evidence" {
                guard !includeTabEvidence else { throw InvalidArguments.usage }
                includeTabEvidence = true
            } else if argument == "--bundle-id" {
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("-") else { throw InvalidArguments.usage }
                bundleIDs.insert(arguments[index])
            } else {
                guard seconds == nil, let value = Double(argument), value > 0, value <= 300 else {
                    throw InvalidArguments.usage
                }
                seconds = value
            }
            index += 1
        }
        self.seconds = seconds ?? 30
        guard !includeTabEvidence || bundleIDs.count == 1 else { throw InvalidArguments.usage }
        self.bundleIDs = bundleIDs.isEmpty ? nil : bundleIDs
        self.includeTabEvidence = includeTabEvidence
    }
}
