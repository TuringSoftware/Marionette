// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Testing

/// Polls `condition` every 10 ms; records an issue if it is still false after `timeout`.
func until(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
