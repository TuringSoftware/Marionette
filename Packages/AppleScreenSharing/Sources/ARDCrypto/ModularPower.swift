// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import BigInt
import Foundation

/// `base ^ exponent mod modulus` for an odd modulus, by Montgomery multiplication over 64-bit limbs.
///
/// The logins do two or three 4096-bit exponentiations each. BigInt's general-purpose arithmetic
/// takes seconds for them in an unoptimised build, which is every debug build of the app; this
/// target is compiled optimised in every configuration and this takes milliseconds.
///
/// The exponent is processed in fixed 4-bit windows: always four squarings and one multiplication,
/// and the multiplier is read from the table by scanning all of it, so neither the sequence of
/// operations nor the memory touched depends on the secret exponent's bits.
enum ModularPower {
    static func power(_ base: BigUInt, _ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(modulus > 1 && modulus[bitAt: 0], "Montgomery arithmetic needs an odd modulus above 1")
        let context = Montgomery(modulus: modulus)
        return context.power(base % modulus, exponent)
    }

    struct Montgomery {
        let count: Int
        let modulus: [UInt64]
        /// -modulus⁻¹ mod 2⁶⁴.
        let inverse: UInt64
        /// R² mod modulus, R = 2^(64·count).
        let rSquared: [UInt64]

        init(modulus value: BigUInt) {
            count = (value.bitWidth + 63) / 64
            modulus = Self.limbs(value, count: count)
            var x: UInt64 = 1
            // Newton's iteration doubles the correct low bits each round: 1 → 64 in six rounds.
            for _ in 0..<6 { x = x &* (2 &- modulus[0] &* x) }
            inverse = 0 &- x
            rSquared = Self.limbs((BigUInt(1) << (128 * count)) % value, count: count)
        }

        static func limbs(_ value: BigUInt, count: Int) -> [UInt64] {
            var output = [UInt64](repeating: 0, count: count)
            for (index, word) in value.words.prefix(count).enumerated() { output[index] = UInt64(word) }
            return output
        }

        static func number(_ limbs: [UInt64]) -> BigUInt {
            BigUInt(words: limbs.map { UInt($0) })
        }

        /// a·b·R⁻¹ mod modulus (CIOS), for a, b < modulus.
        func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
            let n = count
            var t = [UInt64](repeating: 0, count: n + 2)
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    modulus.withUnsafeBufferPointer { m in
                        t.withUnsafeMutableBufferPointer { t in
                            for i in 0..<n {
                                // t += a · b[i]
                                var carry: UInt64 = 0
                                let bi = b[i]
                                for j in 0..<n {
                                    let product = a[j].multipliedFullWidth(by: bi)
                                    let (sum1, overflow1) = t[j].addingReportingOverflow(product.low)
                                    let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                                    t[j] = sum2
                                    carry = product.high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                                }
                                let (top, topOverflow) = t[n].addingReportingOverflow(carry)
                                t[n] = top
                                t[n + 1] = topOverflow ? 1 : 0
                                // t = (t + q · modulus) / 2⁶⁴, with q chosen so the low limb vanishes.
                                let q = t[0] &* inverse
                                let first = m[0].multipliedFullWidth(by: q)
                                let (_, lowOverflow) = t[0].addingReportingOverflow(first.low)
                                carry = first.high &+ (lowOverflow ? 1 : 0)
                                for j in 1..<n {
                                    let product = m[j].multipliedFullWidth(by: q)
                                    let (sum1, overflow1) = t[j].addingReportingOverflow(product.low)
                                    let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                                    t[j - 1] = sum2
                                    carry = product.high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                                }
                                let (shifted, shiftOverflow) = t[n].addingReportingOverflow(carry)
                                t[n - 1] = shifted
                                t[n] = t[n + 1] &+ (shiftOverflow ? 1 : 0)
                            }
                        }
                    }
                }
            }
            // t < 2·modulus: subtract once if needed, choosing the result without a branch on it.
            var difference = [UInt64](repeating: 0, count: n)
            var borrow: UInt64 = 0
            for j in 0..<n {
                let (d1, o1) = t[j].subtractingReportingOverflow(modulus[j])
                let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                difference[j] = d2
                borrow = (o1 ? 1 : 0) | (o2 ? 1 : 0)
            }
            // Keep the difference unless it borrowed past the top limb.
            let keepDifference = (t[n] != 0 || borrow == 0) ? UInt64.max : 0
            var result = [UInt64](repeating: 0, count: n)
            for j in 0..<n { result[j] = (difference[j] & keepDifference) | (t[j] & ~keepDifference) }
            return result
        }

        func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
            let n = count
            var one = [UInt64](repeating: 0, count: n)
            one[0] = 1
            let montgomeryOne = multiply(one, rSquared)
            var table = [[UInt64]](repeating: montgomeryOne, count: 16)
            table[1] = multiply(Self.limbs(base, count: n), rSquared)
            for index in 2..<16 { table[index] = multiply(table[index - 1], table[1]) }

            var result = montgomeryOne
            let windows = max(1, (exponent.bitWidth + 3) / 4)
            for window in stride(from: windows - 1, through: 0, by: -1) {
                for _ in 0..<4 { result = multiply(result, result) }
                var digit = 0
                for bit in 0..<4 where exponent[bitAt: window * 4 + bit] { digit |= 1 << bit }
                // Read every entry, keep the one wanted.
                var chosen = [UInt64](repeating: 0, count: n)
                for (index, entry) in table.enumerated() {
                    let mask: UInt64 = index == digit ? .max : 0
                    for j in 0..<n { chosen[j] |= entry[j] & mask }
                }
                result = multiply(result, chosen)
            }
            return Self.number(multiply(result, one))
        }
    }
}
