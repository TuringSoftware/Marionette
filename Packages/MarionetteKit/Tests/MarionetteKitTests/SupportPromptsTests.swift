// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated
import Synchronization
import Testing
@testable import MarionetteKit

/// A clock whose date the test sets.
private final class SettableClock: AppClock {
    private let date = Mutex(Date(timeIntervalSince1970: 1_795_254_060))

    var now: Date { date.withLock { $0 } }
    var uptime: Double { ProcessInfo.processInfo.systemUptime }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }

    func advance(days: Double) {
        date.withLock { $0 += days * 86_400 }
    }
}

@MainActor
@Suite struct SupportPromptsTests {
    private let clock = SettableClock()
    private let defaults: UserDefaults

    init() {
        let suite = "MarionetteKitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makePrompts() -> SupportPrompts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return SupportPrompts(defaults: defaults, clock: clock, calendar: calendar)
    }

    /// One session a day would reach the day thresholds as well; these stay on one day.
    private func endSessions(_ count: Int, in prompts: SupportPrompts) {
        for _ in 0..<count {
            prompts.sessionConnected()
            prompts.sessionEnded()
        }
    }

    /// A day of use each, without a session ending: the app was closed with the session open.
    private func useOn(days: Int, in prompts: SupportPrompts) {
        for _ in 0..<days {
            clock.advance(days: 1)
            prompts.sessionConnected()
        }
    }

    @Test func theReviewIsDueAfterFiveSessionsAndTheDonationAfterTen() {
        let prompts = makePrompts()
        endSessions(4, in: prompts)
        #expect(!prompts.isReviewDue)
        endSessions(1, in: prompts)
        #expect(prompts.isReviewDue && !prompts.isDonationDue)
        endSessions(4, in: prompts)
        #expect(!prompts.isDonationDue)
        endSessions(1, in: prompts)
        #expect(prompts.isDonationDue)
    }

    @Test func daysOfUseCountLikeSessions() {
        let prompts = makePrompts()
        useOn(days: 4, in: prompts)
        #expect(!prompts.isReviewDue)
        useOn(days: 1, in: prompts)
        #expect(prompts.isReviewDue && !prompts.isDonationDue)
        useOn(days: 5, in: prompts)
        #expect(prompts.isDonationDue)
    }

    @Test func aDayCountsOnceHoweverManySessionsStartOnIt() {
        let prompts = makePrompts()
        for _ in 0..<20 { prompts.sessionConnected() }
        clock.advance(days: 0.25)
        prompts.sessionConnected()
        #expect(defaults.integer(forKey: "support.days") == 1)
        #expect(!prompts.isReviewDue)
    }

    @Test func aDayWithoutASessionIsNotADayOfUse() {
        let prompts = makePrompts()
        prompts.sessionConnected()
        clock.advance(days: 30)
        #expect(defaults.integer(forKey: "support.days") == 1)
        prompts.sessionConnected()
        #expect(defaults.integer(forKey: "support.days") == 2)
    }

    @Test func theReviewIsAskedForOnce() {
        let prompts = makePrompts()
        endSessions(5, in: prompts)
        prompts.reviewRequested()
        #expect(!prompts.isReviewDue)
        endSessions(20, in: prompts)
        prompts.donationPostponed()
        endSessions(20, in: prompts)
        #expect(!prompts.isReviewDue)
    }

    /// Opening Support Us counts as "Not Now" for the donation. It answers nothing about a review.
    @Test func puttingTheDonationOffDoesNotPutOffTheReview() {
        let prompts = makePrompts()
        endSessions(4, in: prompts)
        prompts.donationPostponed()
        endSessions(1, in: prompts)
        #expect(prompts.isReviewDue)
        endSessions(8, in: prompts)
        #expect(!prompts.isDonationDue, "nine sessions since it was put off")
        endSessions(1, in: prompts)
        #expect(prompts.isDonationDue)
    }

    @Test func notNowStartsTheCountAgain() {
        let prompts = makePrompts()
        endSessions(10, in: prompts)
        prompts.donationPostponed()
        #expect(!prompts.isDonationDue)
        endSessions(9, in: prompts)
        #expect(!prompts.isDonationDue)
        endSessions(1, in: prompts)
        #expect(prompts.isDonationDue)
    }

    /// The day of the answer was counted before it; counting it again would make nine more days enough.
    @Test func notNowStartsTheDaysAgainWithoutCountingTodayTwice() {
        let prompts = makePrompts()
        useOn(days: 10, in: prompts)
        prompts.donationPostponed()
        prompts.sessionConnected()
        useOn(days: 9, in: prompts)
        #expect(!prompts.isDonationDue)
        useOn(days: 1, in: prompts)
        #expect(prompts.isDonationDue)
    }

    @Test func aDonationEndsThePromptBeforeItEverShows() {
        let prompts = makePrompts()
        endSessions(3, in: prompts)
        prompts.setDonated(true)
        #expect(prompts.hasDonated)
        endSessions(30, in: prompts)
        useOn(days: 30, in: prompts)
        #expect(!prompts.isDonationDue)
        #expect(makePrompts().hasDonated, "remembered until the App Store says otherwise")
    }

    /// A donation the App Store reports at launch or after a restore, with the prompt due or showing.
    @Test func aDonationFoundLaterTakesThePromptAway() {
        let prompts = makePrompts()
        endSessions(10, in: prompts)
        #expect(prompts.isDonationDue)
        prompts.setDonated(true)
        #expect(!prompts.isDonationDue)
        endSessions(10, in: prompts)
        #expect(!prompts.isDonationDue)
    }

    @Test func aRefundedDonationIsNotThankedForButDoesNotBringThePromptBack() {
        let prompts = makePrompts()
        endSessions(10, in: prompts)
        prompts.setDonated(true)
        prompts.setDonated(false)
        #expect(!prompts.hasDonated && !prompts.isDonationDue)
        #expect(!makePrompts().hasDonated)
    }

    @Test func doNotShowAgainEndsTheDonationPromptForGood() {
        let prompts = makePrompts()
        endSessions(10, in: prompts)
        prompts.donationSettled()
        #expect(!prompts.isDonationDue)
        endSessions(30, in: prompts)
        useOn(days: 30, in: prompts)
        #expect(!prompts.isDonationDue)
    }

    @Test func countsAndAnswersOutliveTheProcess() {
        endSessions(10, in: makePrompts())
        let relaunched = makePrompts()
        #expect(relaunched.isReviewDue && relaunched.isDonationDue)
        relaunched.reviewRequested()
        relaunched.donationSettled()
        let again = makePrompts()
        #expect(!again.isReviewDue && !again.isDonationDue)
    }

    @Test func aDisabledModelNeverAsks() {
        let prompts = SupportPrompts(defaults: defaults, clock: clock, isEnabled: false)
        endSessions(20, in: prompts)
        #expect(!prompts.isReviewDue && !prompts.isDonationDue)
        #expect(makePrompts().isDonationDue, "the sessions are counted all the same")
    }

    /// Live UI tests run in an app that remembers its earlier runs; a prompt would cover the library.
    @Test func aDiagnosticsRunIsNotAskedForAnything() {
        #expect(LaunchOptions(arguments: ["-MarionetteUITestMode"]).allowsSupportPrompts)
        #expect(!LaunchOptions(arguments: ["-MarionetteDiagnostics"]).allowsSupportPrompts)
    }

    /// What `-MarionetteSessionCount` does on a device that has counted and been answered before.
    @Test func aSeededCountForgetsWhatWasCountedAndAnswered() {
        let prompts = makePrompts()
        useOn(days: 12, in: prompts)
        endSessions(12, in: prompts)
        prompts.reviewRequested()
        prompts.donationSettled()
        prompts.setSessionCount(0)
        #expect(!prompts.isReviewDue && !prompts.isDonationDue)
        endSessions(5, in: prompts)
        #expect(prompts.isReviewDue, "the review can be asked for again")
        endSessions(5, in: prompts)
        #expect(prompts.isDonationDue, "and so can the donation")
    }

    @Test func aSeededCountDoesNotAskADonorAgain() {
        let prompts = makePrompts()
        prompts.setDonated(true)
        prompts.setSessionCount(10)
        #expect(!prompts.isDonationDue)
    }

    @Test func aSeededCountHasHadItsReview() {
        let prompts = makePrompts()
        prompts.setSessionCount(9)
        #expect(!prompts.isReviewDue && !prompts.isDonationDue)
        endSessions(1, in: prompts)
        #expect(prompts.isDonationDue && !prompts.isReviewDue)
    }
}

// MARK: - What the session store reports

@MainActor
@Suite struct SessionUseTests {
    private func makeStore(_ fixture: Fixture, prompts: SupportPrompts) -> SessionStore {
        let ladder = fixture.ladder
        return SessionStore(support: prompts) {
            var dependencies = SessionModel.Dependencies(
                ladder: ladder, secrets: fixture.secrets, pasteboard: fixture.pasteboard, clock: SystemClock(),
                repository: fixture.repository, defaults: fixture.defaults
            )
            dependencies.mutesAudio = true
            dependencies.reconnection = fixture.reconnection
            return dependencies
        }
    }

    private func counts(_ fixture: Fixture) -> (sessions: Int, days: Int) {
        (fixture.defaults.integer(forKey: "support.sessions"), fixture.defaults.integer(forKey: "support.days"))
    }

    @Test func aSessionCountsWhenItClosesAndItsDayWhenItConnects() async throws {
        let fixture = try Fixture()
        let store = makeStore(fixture, prompts: SupportPrompts(defaults: fixture.defaults, clock: SystemClock()))
        let session = store.open(fixture.computer)
        try await waitUntil { session.phase == .connected }
        #expect(counts(fixture) == (0, 1))
        session.disconnect()
        try await waitUntil { store.sessions.isEmpty }
        #expect(counts(fixture) == (1, 1))
    }

    @Test func aSessionThatReconnectsCountsOnce() async throws {
        var dropping = fastScenario()
        dropping.disconnect = (.milliseconds(60), .connectionLost(detail: ""))
        let fixture = try Fixture([dropping, fastScenario()])
        let store = makeStore(fixture, prompts: SupportPrompts(defaults: fixture.defaults, clock: SystemClock()))
        let session = store.open(fixture.computer)
        try await waitUntil { fixture.backend.attempts == 2 && session.phase == .connected }
        // Away and back, as when the app is sent to the background during a session.
        store.applicationWillResignActive()
        store.applicationDidEnterBackground()
        store.applicationWillEnterForeground()
        store.applicationDidBecomeActive()
        session.disconnect()
        try await waitUntil { store.sessions.isEmpty }
        #expect(counts(fixture) == (1, 1))
    }

    @Test func anAttemptThatNeverConnectsIsNotASession() async throws {
        var refusing = fastScenario()
        refusing.failure = (.negotiating, .permissionDenied(detail: ""))
        let fixture = try Fixture([refusing])
        let store = makeStore(fixture, prompts: SupportPrompts(defaults: fixture.defaults, clock: SystemClock()))
        let session = store.open(fixture.computer)
        try await waitUntil { if case .failed = session.phase { true } else { false } }
        session.disconnect()
        try await waitUntil { store.sessions.isEmpty }
        #expect(counts(fixture) == (0, 0))
    }
}
