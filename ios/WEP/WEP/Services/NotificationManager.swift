import Foundation
import UserNotifications

enum WEPNotificationCategory {
    static let taskDecision = "WEP_TASK_DECISION"
    static let taskCompleted = "WEP_TASK_COMPLETED"
    static let approveAction = "WEP_APPROVE_ACTION"
    static let openAction = "WEP_OPEN_ACTION"
}

enum WEPNotificationKind: String {
    case completed
    case decision
}

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var onOpenSession: ((String) -> Void)?
    var onApproveDecision: ((String, String?) -> Void)?
    var shouldPresentForegroundBanner: ((String) -> Bool)?

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self
        registerCategories()
        Task {
            await refreshAuthorizationStatus()
        }
    }

    private func registerCategories() {
        let approve = UNNotificationAction(
            identifier: WEPNotificationCategory.approveAction,
            title: "Approve & Continue",
            options: [.foreground]
        )
        let open = UNNotificationAction(
            identifier: WEPNotificationCategory.openAction,
            title: "Open Session",
            options: [.foreground]
        )

        let decisionCategory = UNNotificationCategory(
            identifier: WEPNotificationCategory.taskDecision,
            actions: [approve, open],
            intentIdentifiers: [],
            options: []
        )
        let completedCategory = UNNotificationCategory(
            identifier: WEPNotificationCategory.taskCompleted,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([decisionCategory, completedCategory])
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        guard settings.authorizationStatus == .notDetermined else { return }

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if !granted {
                authorizationStatus = .denied
            }
        } catch {
            await refreshAuthorizationStatus()
        }
    }

    func notifyTaskCompleted(
        sessionId: String,
        turnId: String,
        sessionTitle: String,
        summary: String,
        status: String
    ) {
        let content = UNMutableNotificationContent()
        let titlePrefix: String
        switch status {
        case "error":
            titlePrefix = "Task Failed"
        case "cancelled":
            titlePrefix = "Task Cancelled"
        default:
            titlePrefix = "Task Completed"
        }

        let cleanTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = cleanTitle.isEmpty ? titlePrefix : "\(titlePrefix): \(cleanTitle)"

        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = cleanSummary.isEmpty
            ? "Your remote AI task finished (\(status))."
            : String(cleanSummary.prefix(180))
        content.sound = .default
        content.categoryIdentifier = WEPNotificationCategory.taskCompleted
        content.threadIdentifier = sessionId
        content.userInfo = [
            "sessionId": sessionId,
            "turnId": turnId,
            "kind": WEPNotificationKind.completed.rawValue
        ]

        let identifier = "wep.completed.\(turnId)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request)
    }

    func notifyDecisionNeeded(
        sessionId: String,
        turnId: String,
        sessionTitle: String,
        question: String
    ) {
        let content = UNMutableNotificationContent()
        let cleanTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = cleanTitle.isEmpty
            ? "Decision Needed to Continue"
            : "Decision Needed: \(cleanTitle)"

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = cleanQuestion.isEmpty
            ? "The agent is waiting for your confirmation or choice before continuing."
            : String(cleanQuestion.prefix(200))
        content.sound = .default
        content.interruptionLevel = .active
        content.categoryIdentifier = WEPNotificationCategory.taskDecision
        content.threadIdentifier = sessionId
        content.userInfo = [
            "sessionId": sessionId,
            "turnId": turnId,
            "kind": WEPNotificationKind.decision.rawValue
        ]

        let identifier = "wep.decision.\(turnId)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request)
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "WEP Notifications Ready"
        content.body = "You will be notified when remote tasks finish or need your decision."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: "wep.test.\(UUID().uuidString)", content: content, trigger: trigger)
        center.add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String ?? ""
        Task { @MainActor in
            let allow = self.shouldPresentForegroundBanner?(sessionId) ?? true
            if allow {
                completionHandler([.banner, .list, .sound])
            } else {
                completionHandler([])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        let turnId = userInfo["turnId"] as? String
        let actionId = response.actionIdentifier

        Task { @MainActor in
            if let sessionId, !sessionId.isEmpty {
                if actionId == WEPNotificationCategory.approveAction {
                    self.onApproveDecision?(sessionId, turnId)
                } else {
                    self.onOpenSession?(sessionId)
                }
            }
            completionHandler()
        }
    }
}
