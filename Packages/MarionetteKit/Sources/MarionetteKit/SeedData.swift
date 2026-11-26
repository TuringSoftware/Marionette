// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreVideo
import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated

/// Fills the simulated environment's library so tests and screenshots start from a known state.
enum SeedData {
    static let studioMacID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let macMiniID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let buildServerID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static let macBookID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!

    @MainActor
    static func seed(_ setup: ScenarioSetup, into repository: ComputerRepository, secrets: any SecretStore, clock: any AppClock) async {
        guard setup.seed == .populated else { return }
        // Remote displays rather than fitted ones, so screenshots look the same on every device.
        var studio = ComputerConfiguration(id: studioMacID, name: "Studio Mac", host: "studio-mac.local", username: "demo", display: .remoteDisplays)
        setup.primaryComputer(&studio)
        var mini = ComputerConfiguration(id: macMiniID, name: "Mac mini", host: "mini.example.com", username: "demo", display: .remoteDisplays)
        mini.tunnel.isEnabled = true
        mini.tunnel.username = "demo"
        let server = ComputerConfiguration(id: buildServerID, name: "Build Server", host: "192.168.1.40", port: 5901, backendID: BackendID.vnc)
        let laptop = ComputerConfiguration(id: macBookID, name: "", host: "jamies-macbook-air.local", username: "jamie")

        let now = clock.now
        let history: [(ComputerConfiguration, SessionMode?, TimeInterval?, SimulationScenario?)] = [
            (studio, .highPerformance, -18 * 60, .highPerformance),
            (mini, .standard, -26 * 3600, .standard),
            (server, .standard, -6 * 86400, .genericVNC),
            (laptop, nil, nil, nil),
        ]
        for (offset, entry) in history.enumerated() {
            let (configuration, mode, ago, scenario) = entry
            // Creation dates a second apart keep the grid order stable.
            repository.save(configuration, now: now.addingTimeInterval(Double(offset) - 30 * 86400))
            if let mode, let ago {
                repository.recordConnection(id: configuration.id, mode: mode, at: now.addingTimeInterval(ago))
            }
            if let scenario, let thumbnail = await thumbnail(for: scenario) {
                repository.setThumbnail(thumbnail, id: configuration.id)
            }
            if setup.savesPasswords || setup.savesWrongPassword {
                let password = setup.savesWrongPassword ? "not-the-password" : "demo"
                try? secrets.setSecret(password, for: .remoteDesktopPassword(for: configuration), protection: configuration.passwordProtection)
            }
        }
    }

    /// The first frame the simulated desktop draws for a scenario, as JPEG.
    static func thumbnail(for base: SimulationScenario) async -> Data? {
        var scenario = base
        scenario.phaseDelay = .zero
        scenario.frameRate = 0
        scenario.playsTone = false
        scenario.disconnect = nil
        scenario.failure = nil
        scenario.tunnelPrompts = []
        scenario.consoleUser = nil
        scenario.displays = scenario.displays.prefix(1).map {
            SimulationScenario.Display(name: $0.name, pixelSize: PixelSize(width: $0.pixelSize.width / 2, height: $0.pixelSize.height / 2), scale: $0.scale / 2)
        }
        let request = ConnectionRequest(
            transport: SimulatedTransport(),
            prompts: StaticPromptHandler(username: scenario.account?.username ?? "", password: scenario.account?.password ?? "")
        )
        guard let session = try? await SimulatedBackend(scenario: scenario).connect(request) else { return nil }
        defer { Task { await session.disconnect() } }
        guard let display = session.layout.displays.first, let frame = await session.frames(for: display.id).next() else { return nil }
        let image: CGImage? = frame.surface.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )?.makeImage()
        }
        return image.flatMap { ThumbnailEncoder.jpegData(from: $0) }
    }
}
