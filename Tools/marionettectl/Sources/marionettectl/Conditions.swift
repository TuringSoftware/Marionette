// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The bad-network options: what `--loss`, `--bandwidth`, `--change` and the rest ask for.

import Foundation
import RemoteDesktopCore
import RemoteDesktopTransport

/// The network conditions the options ask for, and the changes to make to them while the session
/// runs; `nil` when they ask for none.
func networkConditions(_ arguments: Arguments) throws -> (start: NetworkImpairment, changes: [ImpairmentControl.Step])? {
    var start = NetworkImpairment(seed: UInt64(arguments.option("seed") ?? "1") ?? 1)
    var named = false
    for name in conditionNames {
        if let value = arguments.option(name) {
            try apply(name, value, to: &start)
            named = true
        }
    }
    if let quiet = arguments.option("loss-after").flatMap(Double.init) { start.quietPeriod = .seconds(quiet) }
    // "10:bandwidth=2000,delay=50; 30:bandwidth=0": each step starts from the conditions before it.
    var changes: [ImpairmentControl.Step] = []
    if let script = arguments.option("change") {
        var conditions = start
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let seconds = Double(parts[0].trimmingCharacters(in: .whitespaces)) else {
                throw Failure("--change steps look like SECONDS:name=value,name=value, not \(step)")
            }
            for setting in parts[1].split(separator: ",") {
                let pair = setting.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { throw Failure("--change settings look like name=value, not \(setting)") }
                try apply(pair[0], pair[1], to: &conditions)
            }
            changes.append(.init(after: .seconds(seconds), impairment: conditions))
        }
    }
    guard named || !changes.isEmpty else { return nil }
    return (start, changes)
}

private let conditionNames = [
    "loss", "reorder", "burst", "bandwidth", "uplink", "queue", "delay", "jitter", "tcp-bandwidth", "tcp-delay", "tcp-stall",
]

private func apply(_ name: String, _ value: String, to conditions: inout NetworkImpairment) throws {
    guard let number = Double(value), number >= 0 else { throw Failure("--\(name) takes a number, not \(value)") }
    /// Kilobits per second, where 0 means no limit.
    let rate = number > 0 ? Int(number * 1000) : nil
    switch name {
    case "loss":
        conditions.inboundLoss = number / 100
        conditions.outboundLoss = number / 100
    case "reorder": conditions.reordering = number / 100
    case "burst": conditions.burstLength = 0...Int(number)
    case "bandwidth": conditions.inboundBandwidth = rate
    case "uplink": conditions.outboundBandwidth = rate
    case "queue": conditions.queueLimit = .milliseconds(number)
    case "delay": conditions.delay = .milliseconds(number)
    case "jitter": conditions.jitter = .milliseconds(number)
    case "tcp-bandwidth": conditions.streams.bandwidth = rate
    case "tcp-delay": conditions.streams.delay = .milliseconds(number)
    case "tcp-stall": conditions.streams.stallChance = number / 100
    default: throw Failure("--change does not know \(name); it takes \(conditionNames.joined(separator: ", "))")
    }
}

/// One line saying what the conditions are.
func describe(_ conditions: NetworkImpairment) -> String {
    func rate(_ bits: Int?) -> String { bits.map { String(format: "%.0f kbit/s", Double($0) / 1000) } ?? "unlimited" }
    func ms(_ duration: Duration) -> String { String(format: "%.0f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }
    var parts = [
        String(format: "%.1f %% loss each way", conditions.inboundLoss * 100),
        String(format: "%.1f %% reordered", conditions.reordering * 100),
        "bursts up to \(conditions.burstLength.upperBound + 1)",
        "downlink \(rate(conditions.inboundBandwidth)), uplink \(rate(conditions.outboundBandwidth)), queue \(ms(conditions.queueLimit))",
        "delay \(ms(conditions.delay)) + jitter up to \(ms(conditions.jitter))",
    ]
    let streams = conditions.streams
    if streams != StreamImpairment() {
        parts.append("TCP \(rate(streams.bandwidth)), delay \(ms(streams.delay)), " + String(format: "%.1f %% of segments stall", streams.stallChance * 100))
    }
    return parts.joined(separator: "; ")
}
