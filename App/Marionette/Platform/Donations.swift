// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import StoreKit

/// The one-time donation sold through the App Store.
enum Donations {
    /// A non-consumable: the App Store remembers it for the account, on every device and after the
    /// app is installed again.
    static let productID = "llc.turing.Marionette.one_time_donation"

    /// Whether the App Store holds the donation for this account. Answered from what the device
    /// already knows; nothing is asked of the person.
    static func isMade() async -> Bool {
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement, transaction.productID == productID, transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    /// How asking the App Store again for the account's purchases ended.
    enum Restoration {
        case found
        case nothingFound
        /// The person backed out of signing in.
        case cancelled
        case failed(String)
    }

    /// Fetches the account's purchases afresh, which may ask the person to sign in, and says
    /// whether the donation is among them. For a device the App Store has not told by itself.
    static func restore() async -> Restoration {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
        return await isMade() ? .found : .nothingFound
    }

    /// Finishes a purchase the App Store reported. Returns whether the App Store vouches for it.
    @discardableResult
    static func finish(_ result: VerificationResult<Transaction>) async -> Bool {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
            return true
        case .unverified(let transaction, _):
            await transaction.finish()
            return false
        }
    }

    /// Reports whether the donation is made, now and whenever that changes away from the sheet, for
    /// as long as the task runs: bought on another device, approved later by a parent, or refunded.
    static func watch(onChange: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await onChange(await isMade())
            for await update in Transaction.updates {
                await finish(update)
                await onChange(await isMade())
            }
        }
    }
}
