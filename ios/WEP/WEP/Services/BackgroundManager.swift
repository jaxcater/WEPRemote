import BackgroundTasks
import Foundation
import UIKit

@MainActor
final class BackgroundManager {
    static let shared = BackgroundManager()

    static let refreshTaskId = "com.wep.remote.ios.refresh"
    static let processingTaskId = "com.wep.remote.ios.processing"

    private var didRegister = false
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var refreshHandler: (() async -> Bool)?

    private init() {}

    func registerTasks(handler: @escaping () async -> Bool) {
        self.refreshHandler = handler
        guard !didRegister else { return }
        didRegister = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { [weak self] task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self?.handleBackgroundTask(appRefreshTask, isProcessing: false)
            }
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskId, using: nil) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self?.handleBackgroundTask(processingTask, isProcessing: true)
            }
        }
    }

    func updateRefreshHandler(_ handler: @escaping () async -> Bool) {
        self.refreshHandler = handler
    }

    private func handleBackgroundTask(_ task: BGTask, isProcessing: Bool) async {
        let workTask = Task { @MainActor in
            await self.refreshHandler?() ?? false
        }

        task.expirationHandler = {
            workTask.cancel()
        }

        let success = await workTask.value
        task.setTaskCompleted(success: success)

        if !isProcessing {
            scheduleBackgroundRefresh(hasActiveWork: success)
        }
    }

    func scheduleBackgroundRefresh(hasActiveWork: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskId)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskId)

        let refreshRequest = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: hasActiveWork ? 15 : 120)
        try? BGTaskScheduler.shared.submit(refreshRequest)

        if hasActiveWork {
            let processingRequest = BGProcessingTaskRequest(identifier: Self.processingTaskId)
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false
            processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 20)
            try? BGTaskScheduler.shared.submit(processingRequest)
        }
    }

    func cancelAllScheduledTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskId)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskId)
    }

    func beginImmediateBackgroundGraceTask(onExpire: (() -> Void)? = nil) {
        endImmediateBackgroundGraceTask()
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "WEPActiveAgentMonitor") { [weak self] in
            Task { @MainActor in
                onExpire?()
                self?.endImmediateBackgroundGraceTask()
            }
        }
    }

    func endImmediateBackgroundGraceTask() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }
}
