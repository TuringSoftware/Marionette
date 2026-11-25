// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

package import Foundation

extension Data {
    /// Bytes from a hex string; spaces and newlines are ignored.
    package init(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        precondition(digits.count % 2 == 0, "odd number of hex digits")
        var bytes = [UInt8]()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    package var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// SplitMix64, seeded, so property tests are reproducible.
package struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    package init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
