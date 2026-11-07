import Foundation

public struct RecordingOptions {
    public let seconds: Double
    public let bundleIDs: Set<String>?

    public enum InvalidArguments: Error { case usage }

    public init(arguments: [String]) throws {
        var seconds: Double?
        var bundleIDs: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--bundle-id" {
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
        self.bundleIDs = bundleIDs.isEmpty ? nil : bundleIDs
    }
}
