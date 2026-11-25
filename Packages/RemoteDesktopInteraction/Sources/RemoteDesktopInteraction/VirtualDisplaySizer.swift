// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// Decides what virtual display to ask the remote machine for, given the pane it will be shown in.
///
/// The display has the pane's shape and fills it: a phone held upright gets a portrait display. A
/// pane large enough for a HiDPI display gets one of its own point size. A smaller pane on a dense
/// screen (a phone) gets a plain display with twice the pane's points — the same pixels, drawn at
/// half size. The sizer reports that as the *residual zoom*: pane points per remote point once the
/// display is fitted into the pane.
///
/// Panes resize continuously (rotation, folding, the keyboard, window resizing), while each change of
/// virtual display costs a renegotiation. The sizer therefore waits until the pane has been stable
/// for ``debounceInterval`` and only then proposes — once, however many sizes it saw meanwhile.
public struct VirtualDisplaySizer: Sendable, Hashable {
    public struct Proposal: Sendable, Hashable {
        public var request: VirtualDisplayRequest
        /// Pane points per remote point when the display is fitted into the pane: 1 for a HiDPI
        /// display of the pane's own size, 0.5 for a phone's doubled plain display, less when the
        /// request had to grow to the server's minimum, and more than 1 when the pixel cap made the
        /// display smaller than the pane.
        public var residualZoom: Double

        public init(request: VirtualDisplayRequest, residualZoom: Double) {
            self.request = request
            self.residualZoom = residualZoom
        }
    }

    public var limits: DisplayConfigurationLimits
    /// Ask for Retina (2x) displays where the remote machine makes them (see ``proposal(forPane:deviceScale:limits:prefersRetina:)``).
    public var prefersRetina = true
    /// Seconds the pane must stay the same size before a proposal is made.
    public var debounceInterval: Double

    private struct Pending: Sendable, Hashable {
        var pane: ViewSize
        var deviceScale: Double
        var time: Double
    }

    private var pending: Pending?
    /// The proposal most recently returned by ``poll(at:)`` or recorded with ``markApplied(_:)``.
    public private(set) var lastProposal: Proposal?

    public init(limits: DisplayConfigurationLimits, debounceInterval: Double = 0.35) {
        self.limits = limits
        self.debounceInterval = debounceInterval
    }

    /// The display to request for a pane, or `nil` when the pane is empty or the session cannot
    /// create virtual displays.
    ///
    /// 1. On a dense screen (more than 1.25 device pixels per point) with `prefersRetina`: a Retina
    ///    display with the pane's own pixels, as a Mac's built-in display has: half the pane's pixels
    ///    in points, at scale 2 (on a 3x phone, 1.5 remote points per pane point; residual zoom 2/3).
    ///    A pane smaller than ``DisplayConfigurationLimits/minimumHiDPIPointSize`` in those points
    ///    grows uniformly to it. Too many pixels for ``DisplayConfigurationLimits/maximumPixelSize``
    ///    shrink it uniformly, as long as it stays at the minimum; when it cannot (a phone held
    ///    upright), there is no Retina display of the pane's shape and rule 2 applies.
    /// 2. On a dense screen otherwise: twice the pane's points at scale 1, residual zoom 0.5 — the
    ///    pixels a scale-2 display of the pane's size would have had, the Mac drawn at half size.
    /// 3. A screen that is not dense (a 1x external monitor): the pane's point size at scale 1.
    /// 4. A scale-1 request below ``DisplayConfigurationLimits/minimumPointSize`` grows uniformly
    ///    until it reaches the minimum.
    /// 5. A request with more pixels on a side than ``DisplayConfigurationLimits/maximumPixelSize``
    ///    (width against width, height against height) shrinks uniformly as far as the minimum for
    ///    its scale allows; whatever is still too long is cut, which changes the shape (the viewport
    ///    letterboxes).
    ///
    /// Dimensions are even and never below the minimum for the request's scale.
    public static func proposal(
        forPane pane: ViewSize, deviceScale: Double, limits: DisplayConfigurationLimits, prefersRetina: Bool = true
    ) -> Proposal? {
        guard limits.maximumVirtualDisplays > 0, !pane.isEmpty, pane.width >= 1, pane.height >= 1 else { return nil }
        let density = deviceScale.isFinite && deviceScale > 0 ? deviceScale : 1
        // At scale 2 a remote point covers one pane point: `density` device pixels.
        let isDense = density > 1.25
        if isDense, prefersRetina {
            let retina = fitted(pane: pane, scale: 2, multiple: density / 2, limits: limits)
            if !retina.isCut { return retina.proposal }
        }
        return fitted(pane: pane, scale: 1, multiple: isDense ? 2 : 1, limits: limits).proposal
    }

    /// A request of `scale` covering `multiple` remote points per pane point, held within the limits.
    /// `isCut`: the request could not keep the pane's shape within the maximum.
    private static func fitted(pane: ViewSize, scale: Int, multiple: Double, limits: DisplayConfigurationLimits) -> (proposal: Proposal, isCut: Bool) {
        var pointWidth = even(pane.width.rounded() * multiple)
        var pointHeight = even(pane.height.rounded() * multiple)
        if multiple == 1 {
            pointWidth = even(pane.width)
            pointHeight = even(pane.height)
        }

        let minimum = scale == 2 ? limits.minimumHiDPIPointSize : limits.minimumPointSize
        let minimumWidth = Double(max(minimum.width, 2))
        let minimumHeight = Double(max(minimum.height, 2))
        var width = Double(pointWidth)
        var height = Double(pointHeight)
        var adjusted = false
        var isCut = false

        if width < minimumWidth || height < minimumHeight {
            adjusted = true
            let growth = max(minimumWidth / (pane.width * multiple), minimumHeight / (pane.height * multiple))
            width = pane.width * multiple * growth
            height = pane.height * multiple * growth
        }

        let hasMaximum = !limits.maximumPixelSize.isEmpty
        let widthLimit = Double(limits.maximumPixelSize.width) / Double(scale)
        let heightLimit = Double(limits.maximumPixelSize.height) / Double(scale)
        if hasMaximum, width > widthLimit || height > heightLimit {
            adjusted = true
            let fitting = min(widthLimit / width, heightLimit / height)
            // The furthest the whole request can shrink before a side drops below the minimum.
            let floor = min(1, max(minimumWidth / width, minimumHeight / height))
            isCut = floor > fitting
            let shrink = max(fitting, floor)
            width = min(width * shrink, widthLimit)
            height = min(height * shrink, heightLimit)
        }

        guard adjusted else {
            return (Proposal(
                request: VirtualDisplayRequest(pointSize: PixelSize(width: pointWidth, height: pointHeight), scale: scale),
                residualZoom: 1 / multiple
            ), false)
        }
        pointWidth = even(width, minimum: minimumWidth, maximum: hasMaximum ? widthLimit : nil)
        pointHeight = even(height, minimum: minimumHeight, maximum: hasMaximum ? heightLimit : nil)
        return (Proposal(
            request: VirtualDisplayRequest(pointSize: PixelSize(width: pointWidth, height: pointHeight), scale: scale),
            residualZoom: min(pane.width / Double(pointWidth), pane.height / Double(pointHeight))
        ), isCut)
    }

    /// The nearest even whole number, at least 2; limited to `minimum...maximum` when given (the
    /// minimum wins if they conflict).
    private static func even(_ value: Double, minimum: Double? = nil, maximum: Double? = nil) -> Int {
        // Far beyond any display, and safely inside `Int`.
        let bound = 1e9
        var result = Int((min(value, bound) / 2).rounded()) * 2
        if let maximum, Double(result) > maximum { result = Int(min(max(maximum, 0), bound) / 2) * 2 }
        if let minimum { result = max(result, Int((min(minimum, bound) / 2).rounded(.up)) * 2) }
        return max(result, 2)
    }

    /// Records the pane's current size. Restarts the debounce timer whenever the size differs from
    /// the previous call.
    public mutating func paneChanged(to pane: ViewSize, deviceScale: Double, at time: Double) {
        if let pending, pending.pane == pane, pending.deviceScale == deviceScale { return }
        pending = Pending(pane: pane, deviceScale: deviceScale, time: time)
    }

    /// When ``poll(at:)`` should next be called; `nil` when nothing is waiting.
    public var nextDeadline: Double? {
        pending.map { $0.time + debounceInterval }
    }

    /// Returns a proposal once the pane has been stable for the debounce interval, provided it asks
    /// for something different from the last proposal. A storm of resizes yields one proposal.
    public mutating func poll(at time: Double) -> Proposal? {
        guard let waiting = pending, time >= waiting.time + debounceInterval else { return nil }
        pending = nil
        guard let proposal = Self.proposal(forPane: waiting.pane, deviceScale: waiting.deviceScale, limits: limits, prefersRetina: prefersRetina),
              proposal.request != lastProposal?.request
        else { return nil }
        lastProposal = proposal
        return proposal
    }

    /// Tells the sizer what the session is already using (for example the display requested at
    /// connect time), so the same request is not proposed again.
    public mutating func markApplied(_ proposal: Proposal?) {
        lastProposal = proposal
    }

    /// Forgets the pending pane and the last proposal.
    public mutating func reset() {
        pending = nil
        lastProposal = nil
    }
}
