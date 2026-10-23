import Combine
import Observation
import Sparkle
import SwiftUI

struct UpdatePolicy {
    static let feed = "https://github.com/torbensko/picker/releases/latest/download/appcast.xml"

    static func permitsUpdates(identifier: String?, channel: String?, feed: String?, publicKey: String?) -> Bool {
        identifier == "com.local.Picker" && channel == "Release" && feed == Self.feed
            && publicKey.flatMap { Data(base64Encoded: $0) }?.count == 32
    }
}

@MainActor final class UpdateRelaunchGate {
    private let isBusy: () -> Bool
    private var pending: (() -> Void)?

    init(isBusy: @escaping () -> Bool) { self.isBusy = isBusy }

    func postponeIfBusy(_ install: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pending = install
        return true
    }

    func resumeIfIdle() {
        guard !isBusy(), let install = pending else { return }
        pending = nil
        install()
    }
}

/// Development builds cannot replace themselves with a public release.
@MainActor final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    let enabled: Bool
    private var controller: SPUStandardUpdaterController?
    private let relaunchGate: UpdateRelaunchGate

    init(library: LibraryModel, bundle: Bundle = .main) {
        relaunchGate = UpdateRelaunchGate(isBusy: { library.blocksUpdateRelaunch })
        #if DEBUG
        enabled = false
        #else
        enabled = UpdatePolicy.permitsUpdates(
            identifier: bundle.bundleIdentifier,
            channel: bundle.object(forInfoDictionaryKey: "PickerUpdateChannel") as? String,
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        #endif
        super.init()
        guard enabled else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        // Let Sparkle own permission, scheduling and persisted preferences.
        observeActivity(of: library)
        controller.startUpdater()
    }

    func check() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    private func observeActivity(of library: LibraryModel) {
        // Observe the model independently of any open window: a scan can finish
        // after the user closes the window while an update is waiting to install.
        withObservationTracking {
            _ = library.blocksUpdateRelaunch
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.relaunchGate.resumeIfIdle()
                self.observeActivity(of: library)
            }
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        relaunchGate.postponeIfBusy(installHandler)
    }
}

struct UpdateCommands: Commands {
    @ObservedObject var updates: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }
                .disabled(!updates.enabled || !updates.canCheck)
            if updates.enabled {
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
            }
        }
    }
}
