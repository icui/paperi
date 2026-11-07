import Foundation

public struct RecordingOptions {
    public let seconds: Double
    public let bundleIDs: Set<String>?
    public let includeTabEvidence: Bool
    public let restartAfter: Double?

    public enum InvalidArguments: Error { case usage }

    public init(arguments: [String]) throws {
        var seconds: Double?
        var bundleIDs: Set<String> = []
        var includeTabEvidence = false
        var restartAfter: Double?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--restart-after" {
                index += 1
                guard restartAfter == nil, index < arguments.count,
                      let value = Double(arguments[index]), value > 0, value.isFinite else {
                    throw InvalidArguments.usage
                }
                restartAfter = value
            } else if argument == "--tab-evidence" {
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
        let duration = seconds ?? 30
        self.seconds = duration
        guard restartAfter.map({ $0 < duration }) ?? true else { throw InvalidArguments.usage }
        guard !includeTabEvidence || bundleIDs.count == 1 else { throw InvalidArguments.usage }
        self.bundleIDs = bundleIDs.isEmpty ? nil : bundleIDs
        self.includeTabEvidence = includeTabEvidence
        self.restartAfter = restartAfter
    }
}
