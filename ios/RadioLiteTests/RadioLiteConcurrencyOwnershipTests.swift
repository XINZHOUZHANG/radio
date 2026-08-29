import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteConcurrencyOwnershipTests: XCTestCase {
    @MainActor
    func testCancelledVoicePTTStartupCannotConsumeReceiveRecoveryAfterRelease() async {
        var events: [String] = []
        let task = RadioLiteVoicePTTStartup.schedule(
            requiresMediaSubscription: true,
            prepareReceiveRecovery: { events.append("receive-recovery-transferred") }
        ) {
            events.append("media-subscribe-started")
        }

        XCTAssertEqual(
            events,
            ["receive-recovery-transferred"],
            "receive recovery must transfer synchronously before the startup Task can be cancelled"
        )

        task.cancel()
        await task.value

        XCTAssertEqual(
            events,
            ["receive-recovery-transferred"],
            "a PTT Task cancelled by an immediate release must not begin media subscription"
        )
    }

    @MainActor
    func testCredentialRefreshSharesRotationWhileCancelledWaiterExitsPromptly() async throws {
        let server = try RadioLiteServer(address: "http://radio.example:8787")
        let current = RadioLiteDeviceCredentials(
            deviceId: "device-1",
            accessToken: "access-old",
            accessExpiresAtMs: 1_000,
            refreshToken: "refresh-old",
            refreshExpiresAtMs: 10_000
        )
        let refreshed = RadioLiteDeviceCredentials(
            deviceId: "device-1",
            accessToken: "access-new",
            accessExpiresAtMs: 2_000,
            refreshToken: "refresh-new",
            refreshExpiresAtMs: 20_000
        )
        let coordinator = RadioLiteCredentialRefreshCoordinator()
        let probe = RadioLiteCredentialRefreshProbe()
        let commitProbe = RadioLiteCredentialCommitProbe(server: server, credential: current)

        let first = Task { @MainActor in
            try await coordinator.refresh(
                server: server,
                current: current,
                operation: { credential in try await probe.perform(credential) },
                commit: { request, credentials in
                    try commitProbe.commit(request: request, credentials: credentials)
                }
            )
        }
        await probe.waitForCallCount(1)
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("a cancelled waiter must not apply a shared credential lease")
        } catch is CancellationError {
            // The shared server rotation remains alive for another waiter.
        }

        let newerSnapshot = RadioLiteDeviceCredentials(
            deviceId: "device-1",
            accessToken: "access-newer-snapshot",
            accessExpiresAtMs: 1_500,
            refreshToken: "refresh-newer-snapshot",
            refreshExpiresAtMs: 15_000
        )
        let replacement = Task { @MainActor in
            try await coordinator.refresh(
                server: server,
                current: newerSnapshot,
                operation: { credential in try await probe.perform(credential) },
                commit: { request, credentials in
                    try commitProbe.commit(request: request, credentials: credentials)
                }
            )
        }
        await Task.yield()

        let requestCountBeforeCompletion = await probe.callCount
        XCTAssertEqual(
            requestCountBeforeCompletion,
            1,
            "all waiters for one refresh token must share exactly one server-side rotation"
        )

        await probe.succeed(with: refreshed)
        let replacementLease = try await replacement.value

        XCTAssertEqual(replacementLease.credentials, refreshed)
        XCTAssertEqual(
            commitProbe.commitCount,
            1,
            "credential persistence and publication must run once inside the shared flight before waiters resume"
        )
        XCTAssertEqual(replacementLease.request.refreshToken, "refresh-old")
    }

    func testAuthenticationOwnershipRejectsSupersededRestoreAndLogout() {
        var state = RadioLiteAuthenticationOwnershipState()
        let restore = state.begin()
        XCTAssertTrue(state.isCurrent(restore))
        XCTAssertEqual(state.currentOwnership, restore)

        let login = state.begin()
        XCTAssertFalse(state.isCurrent(restore))
        XCTAssertTrue(state.isCurrent(login))
        XCTAssertEqual(state.currentOwnership, login)

        state.invalidate()
        XCTAssertFalse(state.isCurrent(login))
        XCTAssertNil(state.currentOwnership)
    }

    @MainActor
    func testCredentialRefreshLeaseCannotApplyAfterLogoutOrAccountSwitch() async throws {
        let server = try RadioLiteServer(address: "http://radio.example:8787")
        let current = RadioLiteDeviceCredentials(
            deviceId: "device-1",
            accessToken: "access-old",
            accessExpiresAtMs: 1_000,
            refreshToken: "refresh-old",
            refreshExpiresAtMs: 10_000
        )
        let refreshed = RadioLiteDeviceCredentials(
            deviceId: "device-1",
            accessToken: "access-new",
            accessExpiresAtMs: 2_000,
            refreshToken: "refresh-new",
            refreshExpiresAtMs: 20_000
        )
        let coordinator = RadioLiteCredentialRefreshCoordinator()
        let probe = RadioLiteCredentialRefreshProbe()
        let commitProbe = RadioLiteCredentialCommitProbe(server: server, credential: current)

        let refresh = Task { @MainActor in
            try await coordinator.refresh(
                server: server,
                current: current,
                operation: { credential in try await probe.perform(credential) },
                commit: { request, credentials in
                    try commitProbe.commit(request: request, credentials: credentials)
                }
            )
        }
        await probe.waitForCallCount(1)
        commitProbe.invalidateAccount()
        await probe.succeed(with: refreshed)

        do {
            _ = try await refresh.value
            XCTFail("an old account flight must not publish refreshed credentials")
        } catch is CancellationError {
            // Expected: the network flight finished, but its account lease was invalidated.
        }
        XCTAssertEqual(commitProbe.commitCount, 0)

        let staleRequest = RadioLiteCredentialRefreshRequest(server: server, current: current)
        XCTAssertTrue(
            staleRequest.matches(server: server, credential: .device(current))
        )
        XCTAssertFalse(
            staleRequest.matches(
                server: try RadioLiteServer(address: "http://other.example:8787"),
                credential: .device(current)
            )
        )
        XCTAssertFalse(
            staleRequest.matches(
                server: server,
                credential: .device(RadioLiteDeviceCredentials(
                    deviceId: "device-2",
                    accessToken: "access-other",
                    accessExpiresAtMs: 3_000,
                    refreshToken: "refresh-other",
                    refreshExpiresAtMs: 30_000
                ))
            )
        )
    }

    @MainActor
    func testPersistenceFailureRetriesCommitWithoutRotatingTokenAgain() async throws {
        let server = try RadioLiteServer(address: "http://radio.example:8787")
        let current = RadioLiteDeviceCredentials(
            deviceId: "device-1",
            accessToken: "access-old",
            accessExpiresAtMs: 1_000,
            refreshToken: "refresh-old",
            refreshExpiresAtMs: 10_000
        )
        let refreshed = RadioLiteDeviceCredentials(
            deviceId: "device-1",
            accessToken: "access-new",
            accessExpiresAtMs: 2_000,
            refreshToken: "refresh-new",
            refreshExpiresAtMs: 20_000
        )
        let coordinator = RadioLiteCredentialRefreshCoordinator()
        let probe = RadioLiteCredentialRefreshProbe()
        let commitProbe = RadioLiteCredentialCommitProbe(server: server, credential: current)
        commitProbe.failPersistence()

        let first = Task { @MainActor in
            try await coordinator.refresh(
                server: server,
                current: current,
                operation: { credential in try await probe.perform(credential) },
                commit: { request, credentials in
                    try commitProbe.commit(request: request, credentials: credentials)
                }
            )
        }
        await probe.waitForCallCount(1)
        await probe.succeed(with: refreshed)

        do {
            _ = try await first.value
            XCTFail("the first Keychain commit is intentionally unavailable")
        } catch RadioLiteCredentialCommitProbeError.persistenceUnavailable {
            // The rotated response must remain cached for a commit-only retry.
        }
        XCTAssertTrue(coordinator.hasPendingCommit(server: server, deviceId: current.deviceId))
        XCTAssertEqual(
            coordinator.pendingCommitCredentials(server: server, deviceId: current.deviceId),
            refreshed
        )
        let requestCountAfterFailure = await probe.callCount
        XCTAssertEqual(requestCountAfterFailure, 1)

        commitProbe.allowPersistence()
        let recovered = try await coordinator.refresh(
            server: server,
            current: refreshed,
            operation: { credential in try await probe.rejectUnexpectedRefresh(credential) },
            commit: { request, credentials in
                try commitProbe.commit(request: request, credentials: credentials)
            }
        )

        XCTAssertEqual(recovered.credentials, refreshed)
        let requestCountAfterRecovery = await probe.callCount
        XCTAssertEqual(requestCountAfterRecovery, 1)
        XCTAssertEqual(commitProbe.commitAttemptCount, 2)
        XCTAssertEqual(commitProbe.commitCount, 1)
        XCTAssertFalse(coordinator.hasPendingCommit(server: server, deviceId: current.deviceId))
    }

    func testInvalidatedOperationCannotOwnAReplacement() {
        var epoch = RadioLiteOperationEpoch()
        let old = epoch.begin()
        epoch.invalidate()
        let replacement = epoch.begin()

        XCTAssertFalse(epoch.owns(old))
        XCTAssertTrue(epoch.owns(replacement))
    }

    func testStoppedPendingReceiveAudioCannotRestartPlayback() {
        var transition = RadioLiteOperationEpoch()
        let pendingStart = transition.begin()

        transition.invalidate()
        XCTAssertFalse(
            transition.owns(pendingStart),
            "a subscription completing after Stop must not start monitoring"
        )

        let replacementStart = transition.begin()
        XCTAssertFalse(transition.owns(pendingStart))
        XCTAssertTrue(transition.owns(replacementStart))
    }

    func testStoppedPendingUplinkCannotRebindOrClearItsReplacement() {
        var state = RadioLiteUplinkOwnershipState()
        let old = state.begin(transmitToken: "old-token")
        XCTAssertTrue(state.stop(transmitToken: old.transmitToken, epoch: old.epoch))

        let replacement = state.begin(transmitToken: "new-token")
        XCTAssertFalse(state.complete(old), "a late bind response must stay cancelled")
        XCTAssertTrue(state.complete(replacement))
        XCTAssertFalse(state.stop(transmitToken: old.transmitToken, epoch: old.epoch))
        XCTAssertTrue(state.isBound(replacement), "old cleanup must not clear the replacement")
    }

    func testOldMediaSubscriptionCompletionCannotPublishOverItsReplacement() {
        var state = RadioLiteMediaSubscriptionOwnershipState()
        let main = state.begin(radioId: "main")
        let backup = state.begin(radioId: "backup")

        XCTAssertFalse(
            state.complete(main),
            "a delayed subscription response must be surfaced as cancellation, not success"
        )
        XCTAssertTrue(state.complete(backup))
        XCTAssertFalse(state.isCurrent(main))
        XCTAssertTrue(state.isCurrent(backup))
    }

    func testOldReconnectOwnerCannotClearItsReplacement() {
        var state = RadioLiteReconnectOwnershipState()
        let old = state.begin()
        let replacement = state.begin()

        XCTAssertFalse(state.complete(old), "a cancelled request finishing late must not clear reconnectTask")
        XCTAssertTrue(state.isCurrent(replacement))
        XCTAssertTrue(state.complete(replacement))
        XCTAssertFalse(state.isCurrent(replacement))
    }

    func testReconnectFailurePolicyTreatsSupersessionAsBenign() {
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: CancellationError(),
                stage: .channelReconnect
            ),
            .benign
        )
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: URLError(.timedOut),
                stage: .channelReconnect
            ),
            .retry
        )
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: URLError(.timedOut),
                stage: .credentialRefresh
            ),
            .retry
        )
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: RadioLiteHTTPError.http(
                    status: 401,
                    code: "refresh_expired",
                    message: "expired"
                ),
                stage: .credentialRefresh
            ),
            .signOut
        )
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: RadioLiteHTTPError.http(
                    status: 401,
                    code: "authentication_required",
                    message: "expired access token"
                ),
                stage: .channelReconnect
            ),
            .retry,
            "only an authoritative refresh rejection may delete paired-device credentials"
        )
    }

    func testPTTSubscriptionTransfersMonitoringRestorationUntilRelease() {
        var intent = RadioLiteReceiveMonitoringIntent()
        intent.setDesired(true)
        let monitoring = RadioLiteReceiveMonitoringOwnership(
            radioId: "main",
            generation: intent.suspend()
        )
        var transfers = RadioLiteVoicePTTReceiveRestoreState()

        transfers.assign(monitoring, transmitGeneration: 11)
        XCTAssertFalse(intent.shouldMonitor, "PTT must not resume the speaker while transmit is held")

        let released = transfers.take(transmitGeneration: 11)
        XCTAssertEqual(released, monitoring)
        XCTAssertTrue(intent.resume(
            generation: released?.generation ?? 0,
            expectedRadioId: "main",
            selectedRadioId: "main",
            subscribedRadioId: "main"
        ))
        XCTAssertTrue(intent.shouldMonitor, "releasing PTT must restore the user's receive-audio choice")
    }

    func testOldPTTCleanupCannotConsumeReplacementMonitoringTransfer() {
        var transfers = RadioLiteVoicePTTReceiveRestoreState()
        let old = RadioLiteReceiveMonitoringOwnership(radioId: "main", generation: 3)
        let replacement = RadioLiteReceiveMonitoringOwnership(radioId: "main", generation: 4)
        transfers.assign(old, transmitGeneration: 20)
        transfers.assign(replacement, transmitGeneration: 21)

        XCTAssertNil(transfers.take(transmitGeneration: 20))
        XCTAssertEqual(transfers.take(transmitGeneration: 21), replacement)
    }

    func testNewPTTInvalidatesPendingReleaseAudioResume() {
        var releases = RadioLiteVoicePTTReleaseState()
        let oldRelease = releases.beginRelease()

        XCTAssertTrue(releases.mayResume(
            oldRelease,
            voicePTTHeld: false,
            tuning: false,
            capturingMicrophone: false
        ))

        releases.beginTransmit()

        XCTAssertFalse(releases.mayResume(
            oldRelease,
            voicePTTHeld: false,
            tuning: false,
            capturingMicrophone: false
        ))
    }

    func testReleaseAudioResumeIsBlockedByEveryTransmitActivity() {
        var releases = RadioLiteVoicePTTReleaseState()
        let release = releases.beginRelease()

        XCTAssertFalse(releases.mayResume(
            release,
            voicePTTHeld: true,
            tuning: false,
            capturingMicrophone: false
        ))
        XCTAssertFalse(releases.mayResume(
            release,
            voicePTTHeld: false,
            tuning: true,
            capturingMicrophone: false
        ))
        XCTAssertFalse(releases.mayResume(
            release,
            voicePTTHeld: false,
            tuning: false,
            capturingMicrophone: true
        ))
    }

    func testReleaseAfterStartDispatchStopsALateStartedTokenExactlyOnce() {
        var starts = RadioLiteVoicePTTStartReleaseState()
        let ownership = starts.begin()

        XCTAssertTrue(starts.markStartDispatched(ownership))
        starts.release(ownership)

        XCTAssertEqual(starts.receiveStarted(ownership), .stop)
        XCTAssertEqual(
            starts.receiveStarted(ownership),
            .ignore,
            "a duplicated late callback must not send a second tx.stop"
        )
    }

    func testOldLateStartedTokenStopsWithoutTakingOwnershipFromNewPTT() {
        var starts = RadioLiteVoicePTTStartReleaseState()
        let old = starts.begin()
        XCTAssertTrue(starts.markStartDispatched(old))
        starts.release(old)

        let replacement = starts.begin()
        XCTAssertTrue(starts.markStartDispatched(replacement))

        XCTAssertEqual(starts.receiveStarted(old), .stop)
        XCTAssertEqual(starts.receiveStarted(replacement), .bind)
    }

    func testReleaseBeforeStartDispatchCannotCreateARemoteStopOwner() {
        var starts = RadioLiteVoicePTTStartReleaseState()
        let ownership = starts.begin()

        starts.release(ownership)

        XCTAssertFalse(starts.markStartDispatched(ownership))
        XCTAssertEqual(starts.receiveStarted(ownership), .ignore)
    }

    func testFailedOldStartDoesNotInvalidateReplacementOwnership() {
        var starts = RadioLiteVoicePTTStartReleaseState()
        let old = starts.begin()
        XCTAssertTrue(starts.markStartDispatched(old))
        starts.release(old)
        let replacement = starts.begin()
        XCTAssertTrue(starts.markStartDispatched(replacement))

        starts.failStart(old)

        XCTAssertEqual(starts.receiveStarted(replacement), .bind)
    }

    func testPTTStopReasonRestoresReceiveExceptDuringConnectionLoss() {
        XCTAssertTrue(RadioLiteVoicePTTStopReason.userRelease.restoresReceiveMonitoring)
        XCTAssertTrue(RadioLiteVoicePTTStopReason.transmitFailure.restoresReceiveMonitoring)
        XCTAssertTrue(
            RadioLiteVoicePTTStopReason.operatorCancellation.restoresReceiveMonitoring,
            "a local lifecycle stop must keep the operator's receive-audio intent"
        )
        XCTAssertFalse(
            RadioLiteVoicePTTStopReason.connectionLoss.restoresReceiveMonitoring,
            "connection recovery owns a newer monitoring suspension"
        )
        XCTAssertFalse(
            RadioLiteVoicePTTStopReason.audioInterruption.restoresReceiveMonitoring,
            "an interrupted AVAudioSession must not be reactivated while PTT is being revoked"
        )
    }

    func testTransmitReleaseFallsBackToPendingAudioInterruptionRestore() {
        let pendingInterruption = RadioLiteReceiveMonitoringOwnership(
            radioId: "main",
            generation: 7
        )

        XCTAssertEqual(
            RadioLiteTransmitReceiveRecoverySource.select(
                voicePTTRestore: nil,
                audioInterruptionRestore: pendingInterruption
            ),
            .audioInterruption
        )
        XCTAssertEqual(
            RadioLiteTransmitReceiveRecoverySource.select(
                voicePTTRestore: pendingInterruption,
                audioInterruptionRestore: pendingInterruption
            ),
            .voicePTT
        )
    }

    func testAudioInterruptionInvalidatesQueuedUserReleaseReceiveRestore() {
        var intent = RadioLiteReceiveMonitoringIntent()
        intent.setDesired(true)
        let queuedRestore = RadioLiteReceiveMonitoringOwnership(
            radioId: "main",
            generation: intent.suspend()
        )

        _ = intent.suspend()

        XCTAssertFalse(
            intent.resume(
                generation: queuedRestore.generation,
                expectedRadioId: "main",
                selectedRadioId: "main",
                subscribedRadioId: "main"
            ),
            "an audio interruption must invalidate receive recovery already queued by user release"
        )
        XCTAssertTrue(intent.isSuspended)
        XCTAssertFalse(intent.shouldMonitor)
    }

    func testOldConfigurationReconnectCannotPublishControlForNewRadio() {
        var state = RadioLiteRadioConfigurationReconnectOwnershipState()
        let old = state.begin(radioId: "main")
        let replacement = state.begin(radioId: "backup")

        XCTAssertFalse(state.isCurrent(old, selectedRadioId: "backup"))
        XCTAssertTrue(state.isCurrent(replacement, selectedRadioId: "backup"))
        XCTAssertFalse(state.complete(old, selectedRadioId: "backup"))
        XCTAssertTrue(state.isCurrent(replacement, selectedRadioId: "backup"))
    }

    func testPermissionResultCannotActivateCaptureAfterStop() {
        var state = RadioLiteCaptureEpochState()
        let pending = state.begin()

        XCTAssertEqual(state.stop(epoch: pending.epoch), .invalidatedPending)
        XCTAssertFalse(state.activate(pending), "permission completion after release must not start capture")
        XCTAssertEqual(state.stop(epoch: pending.epoch), .notOwner, "repeat stop must be side-effect free")
    }

    func testOldCaptureStopCannotStopAReplacement() {
        var state = RadioLiteCaptureEpochState()
        let old = state.begin()
        XCTAssertTrue(state.activate(old))
        XCTAssertEqual(state.stop(epoch: old.epoch), .stoppedActive)

        let replacement = state.begin()
        XCTAssertTrue(state.activate(replacement))
        XCTAssertEqual(state.stop(epoch: old.epoch), .notOwner)
        XCTAssertFalse(state.isActive(old), "queued callbacks from the old tap must be discarded")
        XCTAssertTrue(state.isActive(replacement))
    }

    func testOneAsyncMediaFailureHasExactlyOnePresentationOwner() {
        XCTAssertEqual(
            RadioLiteMediaFailurePresentation.route(
                wasUplinkBound: true,
                reconnectRequired: true
            ),
            .reconnectBanner
        )
        XCTAssertEqual(
            RadioLiteMediaFailurePresentation.route(
                wasUplinkBound: true,
                reconnectRequired: false
            ),
            .uplinkBanner
        )
        XCTAssertEqual(
            RadioLiteMediaFailurePresentation.route(
                wasUplinkBound: false,
                reconnectRequired: false
            ),
            .none
        )
    }
}

private actor RadioLiteCredentialRefreshProbe {
    private(set) var callCount = 0
    private var completions: [CheckedContinuation<RadioLiteDeviceCredentials, Error>] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func perform(_ credential: RadioLiteDeviceCredentials) async throws -> RadioLiteDeviceCredentials {
        callCount += 1
        let readyWaiters = callWaiters.filter { callCount >= $0.count }
        callWaiters.removeAll { callCount >= $0.count }
        readyWaiters.forEach { $0.continuation.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            completions.append(continuation)
        }
    }

    func waitForCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((expectedCount, continuation))
        }
    }

    func succeed(with credentials: RadioLiteDeviceCredentials) {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0.resume(returning: credentials) }
    }

    func rejectUnexpectedRefresh(
        _ credential: RadioLiteDeviceCredentials
    ) throws -> RadioLiteDeviceCredentials {
        callCount += 1
        throw RadioLiteCredentialCommitProbeError.unexpectedSecondRefresh
    }
}

@MainActor
private final class RadioLiteCredentialCommitProbe {
    private var accountState = RadioLiteCredentialAccountOwnershipState()
    private let accountOwnership: RadioLiteCredentialAccountOwnership
    private let server: RadioLiteServer
    private let credential: RadioLiteDeviceCredentials
    private var persistenceAvailable = true
    private(set) var commitAttemptCount = 0
    private(set) var commitCount = 0

    init(server: RadioLiteServer, credential: RadioLiteDeviceCredentials) {
        var state = RadioLiteCredentialAccountOwnershipState()
        let ownership = state.activate(server: server, credential: credential)
        self.accountState = state
        self.accountOwnership = ownership
        self.server = server
        self.credential = credential
    }

    func invalidateAccount() {
        accountState.invalidate()
    }

    func failPersistence() {
        persistenceAvailable = false
    }

    func allowPersistence() {
        persistenceAvailable = true
    }

    func commit(
        request: RadioLiteCredentialRefreshRequest,
        credentials: RadioLiteDeviceCredentials
    ) throws {
        guard accountState.isCurrent(accountOwnership),
              request.matches(server: server, credential: .device(credential)) else {
            throw CancellationError()
        }
        commitAttemptCount += 1
        guard persistenceAvailable else {
            throw RadioLiteCredentialCommitProbeError.persistenceUnavailable
        }
        commitCount += 1
    }
}

private enum RadioLiteCredentialCommitProbeError: Error {
    case persistenceUnavailable
    case unexpectedSecondRefresh
}
