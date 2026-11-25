// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import os

/// The route a connection took, and failures the transports recovered from without reporting them.
let transportLog = Logger(subsystem: "llc.turing.Marionette", category: "transport")
