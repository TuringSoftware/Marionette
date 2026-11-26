// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation

/// Decides when to ask for an App Store review and for a donation, from how much the app has been
/// used.
///
/// Use is counted in sessions and in days, and a prompt is due when either reaches its threshold. A
/// session counts when it closes after having been connected, however often it reconnected in
/// between; a day counts when a session connects on it. Both prompts read the same two counters.
@MainActor
@Observable
public final class SupportPrompts {
    /// How many sessions, or days of use, each prompt waits for.
    public struct Thresholds: Sendable, Hashable {
        public var review = 5
        public var donation = 10

        public init() {}
    }

    /// The review has not been asked for yet and enough use has been counted. Asked for once only:
    /// see ``reviewRequested()``.
    public private(set) var isReviewDue = false
    /// The donation prompt should be on screen.
    public private(set) var isDonationDue = false
    /// The donation has been made, as far as the App Store last said.
    public private(set) var hasDonated: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let thresholds: Thresholds
    @ObservationIgnored private let isEnabled: Bool

    private static let sessionsKey = "support.sessions"
    private static let daysKey = "support.days"
    private static let lastDayKey = "support.lastDay"
    private static let postponedSessionsKey = "support.postponedSessions"
    private static let postponedDaysKey = "support.postponedDays"
    private static let reviewRequestedKey = "support.reviewRequested"
    private static let donationSettledKey = "support.donationSettled"
    private static let donatedKey = "support.donated"

    /// - Parameter isEnabled: `false` keeps both prompts away, whatever has been counted.
    public init(
        defaults: UserDefaults, clock: any AppClock, calendar: Calendar = .current, thresholds: Thresholds = Thresholds(), isEnabled: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.defaults = defaults
        hasDonated = defaults.bool(forKey: Self.donatedKey)
        self.clock = clock
        self.calendar = calendar
        self.thresholds = thresholds
        refresh()
    }

    // MARK: Counting

    /// A session connected for the first time: today is a day of use.
    public func sessionConnected() {
        let parts = calendar.dateComponents([.year, .month, .day], from: clock.now)
        let today = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        guard today != defaults.integer(forKey: Self.lastDayKey) else { return }
        defaults.set(today, forKey: Self.lastDayKey)
        defaults.set(defaults.integer(forKey: Self.daysKey) + 1, forKey: Self.daysKey)
        refresh()
    }

    /// A session that had connected closed.
    public func sessionEnded() {
        defaults.set(defaults.integer(forKey: Self.sessionsKey) + 1, forKey: Self.sessionsKey)
        refresh()
    }

    // MARK: Answers

    /// The system was asked to show its review prompt. It is never asked again, whether or not it
    /// showed one: the system decides that and does not say.
    public func reviewRequested() {
        defaults.set(true, forKey: Self.reviewRequestedKey)
        refresh()
    }

    /// "Not Now", or the Support Us sheet was opened, from the prompt or without it: the prompt
    /// goes away and its counting starts again from nothing. A day already counted is not counted a
    /// second time. The review's counting goes on: it is not what was answered.
    public func donationPostponed() {
        defaults.set(defaults.integer(forKey: Self.sessionsKey), forKey: Self.postponedSessionsKey)
        defaults.set(defaults.integer(forKey: Self.daysKey), forKey: Self.postponedDaysKey)
        refresh()
    }

    /// "Do Not Show Again": the prompt never comes back.
    public func donationSettled() {
        defaults.set(true, forKey: Self.donationSettledKey)
        refresh()
    }

    /// What the App Store says of the donation: made, or not (never, or refunded since). Once it
    /// has been made the prompt never comes, whether or not it had shown before, and a refund does
    /// not bring it back.
    public func setDonated(_ donated: Bool) {
        defaults.set(donated, forKey: Self.donatedKey)
        if donated != hasDonated { hasDonated = donated }
        if donated { donationSettled() }
    }

    /// Starts again as after `sessions` sessions on one day, with no prompt answered: the review
    /// has been asked for only if the sessions were enough for it, and the donation prompt is
    /// settled only by a donation. For tests.
    public func setSessionCount(_ sessions: Int) {
        defaults.set(sessions, forKey: Self.sessionsKey)
        defaults.set(0, forKey: Self.daysKey)
        defaults.removeObject(forKey: Self.lastDayKey)
        defaults.removeObject(forKey: Self.postponedSessionsKey)
        defaults.removeObject(forKey: Self.postponedDaysKey)
        defaults.set(sessions >= thresholds.review, forKey: Self.reviewRequestedKey)
        defaults.set(hasDonated, forKey: Self.donationSettledKey)
        refresh()
    }

    private func refresh() {
        guard isEnabled else { return }
        let sessions = defaults.integer(forKey: Self.sessionsKey)
        let days = defaults.integer(forKey: Self.daysKey)
        let sincePostponed = max(sessions - defaults.integer(forKey: Self.postponedSessionsKey), days - defaults.integer(forKey: Self.postponedDaysKey))
        let review = max(sessions, days) >= thresholds.review && !defaults.bool(forKey: Self.reviewRequestedKey)
        let donation = sincePostponed >= thresholds.donation && !defaults.bool(forKey: Self.donationSettledKey)
        // Assigned only on a change, so that views watching one prompt are not woken by the other.
        if review != isReviewDue { isReviewDue = review }
        if donation != isDonationDue { isDonationDue = donation }
    }
}
