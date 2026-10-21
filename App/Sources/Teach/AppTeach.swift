import AVFoundation
import Foundation
import ParrotKit

/// This app's side of Teach your sounds (ParrotKit): the microphone it records from, how it reaches a trainer by address, and the trainer
/// configuration. Everything else (plan, library, sound pack, trainer client and discovery, the state machine, the screens) is the kit's.
enum AppTeach {
    /// The trainer's port, from `PARROT_TRAINER_PORT` in Config/Base.xcconfig through Info.plist.
    static func configuration(info: [String: Any]? = Bundle.main.infoDictionary) -> TrainerConfiguration {
        TrainerConfiguration.fromInfo(info) ?? TrainerConfiguration(port: 8750)
    }

    /// A client for one trainer: names go through URLSession (App Transport Security allows `*.ts.net`), 100.x addresses through the
    /// plain TCP transport the computers use, and every request says which app version is asking.
    static func makeClient(_ base: URL) -> TrainerClient {
        var client = TrainerClient(baseURL: base)
        client.addressTransport = SocketTrainerTransport()
        client.tailnet = InterfaceTailnetStatus()
        client.decorate = { request in
            if let version = AppVersion.current { request.setValue(version.description, forHTTPHeaderField: AppVersion.header) }
        }
        return client
    }
}

/// 100.x addresses: App Transport Security cannot be told to allow an address range, so these go over `SocketTransport` like the computers.
struct SocketTrainerTransport: TrainerTransport {
    func send(_ request: URLRequest, bodyFile: URL?, timeout: TimeInterval,
              progress: @escaping @Sendable (Double) -> Void) async throws -> (status: Int, body: Data) {
        var request = request
        if let bodyFile { request.httpBody = try Data(contentsOf: bodyFile) }
        let reply = try await SocketTransport(timeout: timeout).send(request)
        progress(1)
        return (reply.status, reply.data)
    }
}

/// The app's one microphone tap, as the Teach flow's microphone: a take subscribes to the `SampleBus`, so the detector and the speech
/// model keep running on the same audio and no second audio engine is opened.
final class SessionMicrophone: TeachMicrophone, @unchecked Sendable {
    private let bus: SampleBus
    private let makeReady: @MainActor () async -> String?
    private let lock = NSLock()
    private var subscription: SampleBus.Subscription?
    private var observers: [NSObjectProtocol] = []

    /// - Parameter makeReady: starts the tap if needed; returns a sentence when it cannot be used.
    init(bus: SampleBus, makeReady: @escaping @MainActor () async -> String?) {
        self.bus = bus
        self.makeReady = makeReady
    }

    @MainActor func prepare() async -> String? { await makeReady() }

    func start(onSamples: @escaping @Sendable ([Float]) -> Void, onEvent: @escaping @Sendable (TeachMicrophoneEvent) -> Void) throws {
        let center = NotificationCenter.default
        let tokens = [AVAudioSession.interruptionNotification, .AVAudioEngineConfigurationChange].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in onEvent(.interrupted) }
        }
        let subscription = bus.subscribe(onSamples)
        lock.withLock {
            self.subscription = subscription
            observers = tokens
        }
    }

    func stop() {
        let (subscription, tokens) = lock.withLock { () -> (SampleBus.Subscription?, [NSObjectProtocol]) in
            defer {
                self.subscription = nil
                observers = []
            }
            return (self.subscription, observers)
        }
        subscription?.cancel()
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
