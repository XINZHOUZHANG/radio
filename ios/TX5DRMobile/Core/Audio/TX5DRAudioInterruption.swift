import AVFoundation
import Foundation

/// What the app should do about an audio-session event while it may be
/// transmitting.
enum TX5DRAudioInterruptionAction: Equatable, Sendable {
    /// Release PTT and tear down microphone capture. Never the reverse: this
    /// type deliberately has no "resume transmitting" case, because resuming
    /// transmission without an explicit operator action is not something a
    /// remote station may do on its own.
    case stopCaptureAndTransmit
    case ignore
}

/// Maps `AVAudioSession` notifications onto `TX5DRAudioInterruptionAction`.
///
/// This exists because `scenePhase` is the wrong signal for "something took the
/// microphone away". `scenePhase` goes `.inactive` for a system permission
/// alert too, and treating that as backgrounding cancels the very first PTT the
/// operator ever presses — the microphone permission dialog appears, the app
/// goes `.inactive`, and the in-flight PTT task is cancelled before the
/// operator can tap "Allow".
enum TX5DRAudioInterruptionPolicy {
    static func action(for notification: Notification) -> TX5DRAudioInterruptionAction {
        if notification.name == AVAudioSession.mediaServicesWereLostNotification
            || notification.name == AVAudioSession.mediaServicesWereResetNotification {
            return .stopCaptureAndTransmit
        }
        if notification.name == AVAudioSession.routeChangeNotification {
            // Only `.oldDeviceUnavailable` is unambiguous: the input the tap was
            // installed on is gone, so the microphone is dead while the rig may
            // still be keyed. Transmitting a silent carrier occupies the
            // frequency without putting a signal on it, so stop. Other route
            // reasons (a device appearing, a category change) do not by
            // themselves invalidate the capture path.
            guard let reason = routeChangeReason(for: notification) else { return .ignore }
            return reason == .oldDeviceUnavailable ? .stopCaptureAndTransmit : .ignore
        }
        guard let type = interruptionType(for: notification) else { return .ignore }
        // `.ended` is intentionally `.ignore`: an interruption ending must not
        // put the rig back on the air by itself.
        return type == .began ? .stopCaptureAndTransmit : .ignore
    }

    static func interruptionType(for notification: Notification) -> AVAudioSession.InterruptionType? {
        guard notification.name == AVAudioSession.interruptionNotification,
              let rawValue = unsignedInteger(
                  notification.userInfo?[AVAudioSessionInterruptionTypeKey]
              ) else {
            return nil
        }
        return AVAudioSession.InterruptionType(rawValue: rawValue)
    }

    static func routeChangeReason(for notification: Notification) -> AVAudioSession.RouteChangeReason? {
        guard notification.name == AVAudioSession.routeChangeNotification,
              let rawValue = unsignedInteger(
                  notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
              ) else {
            return nil
        }
        return AVAudioSession.RouteChangeReason(rawValue: rawValue)
    }

    private static func unsignedInteger(_ value: Any?) -> UInt? {
        if let rawValue = value as? UInt { return rawValue }
        return (value as? NSNumber)?.uintValue
    }
}

/// Holds the notification tokens and removes them on deallocation.
///
/// This is deliberately a plain (non-isolated) class: a `deinit` on a
/// `@MainActor` type cannot touch actor-isolated stored properties, so the
/// cleanup lives here and the isolated observer just owns one of these.
private final class TX5DRNotificationObservationBag {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func insert(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}

/// Subscribes to the audio-session notifications that must stop a transmission
/// and forwards them on the main actor.
///
/// One interruption episode delivers at most one stop, so an incoming call that
/// emits several notifications does not produce a burst of PTT releases.
@MainActor
final class TX5DRAudioInterruptionObserver {
    private let observationBag: TX5DRNotificationObservationBag
    private let onStopCaptureAndTransmit: @MainActor () -> Void
    private var stopDeliveredForCurrentEpisode = false

    init(
        notificationCenter: NotificationCenter = .default,
        onStopCaptureAndTransmit: @escaping @MainActor () -> Void
    ) {
        let observationBag = TX5DRNotificationObservationBag(notificationCenter: notificationCenter)
        self.observationBag = observationBag
        self.onStopCaptureAndTransmit = onStopCaptureAndTransmit
        for name in [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ] {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.receive(notification)
                }
            }
            observationBag.insert(observer)
        }
    }

    /// Arms the observer for a new transmission. Call this when PTT starts so a
    /// later interruption is delivered even if an earlier one already fired.
    func rearm() {
        stopDeliveredForCurrentEpisode = false
    }

    private func receive(_ notification: Notification) {
        guard TX5DRAudioInterruptionPolicy.action(for: notification) == .stopCaptureAndTransmit else {
            return
        }
        guard !stopDeliveredForCurrentEpisode else { return }
        stopDeliveredForCurrentEpisode = true
        onStopCaptureAndTransmit()
    }
}
