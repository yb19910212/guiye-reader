import SwiftUI
import UserNotifications
import UIKit

enum ReadingReminderDefaults {
    static let enabled = "guiye.readingReminder.enabled"
    static let hour = "guiye.readingReminder.hour"
    static let minute = "guiye.readingReminder.minute"
}

final class GuiyeReaderAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class ReadingReminderScheduler {
    static let shared = ReadingReminderScheduler()

    private let center = UNUserNotificationCenter.current()
    private let identifier = "guiye.readingReminder.daily"
    private var desiredTime: (hour: Int, minute: Int)?

    private init() {}

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func scheduleDaily(hour: Int, minute: Int) async throws {
        let safeHour = min(max(hour, 0), 23)
        let safeMinute = min(max(minute, 0), 59)
        desiredTime = (safeHour, safeMinute)
        try await install(hour: safeHour, minute: safeMinute)

        // A time change or disable action can happen while Notification Center is
        // accepting the request. Reconcile once more so the latest choice wins.
        guard let latest = desiredTime else {
            removeRequests()
            return
        }
        if latest.hour != safeHour || latest.minute != safeMinute {
            try await install(hour: latest.hour, minute: latest.minute)
        }
    }

    func cancel() {
        desiredTime = nil
        removeRequests()
    }

    func refreshIfEnabled() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: ReadingReminderDefaults.enabled) else {
            cancel()
            return
        }
        let status = await authorizationStatus()
        guard status.allowsNotifications else {
            removeRequests()
            return
        }
        let hour = defaults.object(forKey: ReadingReminderDefaults.hour) == nil
            ? 20 : defaults.integer(forKey: ReadingReminderDefaults.hour)
        let minute = defaults.object(forKey: ReadingReminderDefaults.minute) == nil
            ? 30 : defaults.integer(forKey: ReadingReminderDefaults.minute)
        try? await scheduleDaily(hour: hour, minute: minute)
    }

    func messagePreview() -> String {
        notificationBody()
    }

    private func install(hour: Int, minute: Int) async throws {
        removeRequests()
        let content = UNMutableNotificationContent()
        content.title = "该读一会儿了"
        content.body = notificationBody()
        content.sound = .default
        content.threadIdentifier = "guiye.readingReminder"

        // No time zone is pinned here: UNCalendarNotificationTrigger follows the
        // device's current local calendar and continues to do so after travel.
        let components = DateComponents(hour: hour, minute: minute)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await center.add(request)
    }

    private func notificationBody() -> String {
        let defaults = UserDefaults.standard
        let savedGoal = defaults.integer(forKey: "guiye.readingStats.goalMinutes")
        let goalMinutes = savedGoal > 0 ? savedGoal : 30

        if let data = defaults.data(forKey: "guiye.readingPlans"),
           let plans = try? JSONDecoder().decode([ReadingPlan].self, from: data),
           let nextPlan = plans
               .filter({ $0.deadline >= Calendar.autoupdatingCurrent.startOfDay(for: Date()) })
               .min(by: { $0.deadline < $1.deadline }) {
            return "继续《\(nextPlan.bookTitle)》的读完计划，今天也完成 \(goalMinutes) 分钟目标吧。"
        }
        return "今天读 \(goalMinutes) 分钟，让阅读进度再向前一点。"
    }

    private func removeRequests() {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

private extension UNAuthorizationStatus {
    var allowsNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }
}

struct ReadingReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(ReadingReminderDefaults.enabled) private var enabled = false
    @AppStorage(ReadingReminderDefaults.hour) private var hour = 20
    @AppStorage(ReadingReminderDefaults.minute) private var minute = 30
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @State private var rescheduleTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("每日阅读提醒", isOn: enabledBinding)
                        .disabled(isUpdating)
                    DatePicker("提醒时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .disabled(!enabled || isUpdating)
                } footer: {
                    Text("按设备当前本地时间每天提醒；关闭后会立即取消待发送通知。")
                }

                Section("提醒内容") {
                    Text(ReadingReminderScheduler.shared.messagePreview())
                        .foregroundStyle(.secondary)
                    Label("每日目标和读完计划只在本机读取，不会上传书名或阅读数据。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("系统权限") {
                    LabeledContent("通知") {
                        Text(permissionDescription)
                            .foregroundStyle(permissionColor)
                    }
                    if authorizationStatus == .denied {
                        Button("打开系统通知设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("阅读提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await refreshStatus() }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { newValue in
                if newValue {
                    enableReminder()
                } else {
                    rescheduleTask?.cancel()
                    enabled = false
                    errorMessage = nil
                    ReadingReminderScheduler.shared.cancel()
                }
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.autoupdatingCurrent.date(
                    from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)
                ) ?? Date()
            },
            set: { newValue in
                let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: newValue)
                let newHour = components.hour ?? 20
                let newMinute = components.minute ?? 30
                hour = newHour
                minute = newMinute
                scheduleTimeChange(hour: newHour, minute: newMinute)
            }
        )
    }

    private func enableReminder() {
        enabled = true
        isUpdating = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let granted = try await ReadingReminderScheduler.shared.requestAuthorization()
                authorizationStatus = await ReadingReminderScheduler.shared.authorizationStatus()
                guard granted && authorizationStatus.allowsNotifications else {
                    enabled = false
                    ReadingReminderScheduler.shared.cancel()
                    errorMessage = "通知权限未开启，请在系统设置中允许归页发送通知。"
                    isUpdating = false
                    return
                }
                try await ReadingReminderScheduler.shared.scheduleDaily(hour: hour, minute: minute)
            } catch {
                enabled = false
                ReadingReminderScheduler.shared.cancel()
                errorMessage = "提醒设置失败：\(error.localizedDescription)"
            }
            isUpdating = false
        }
    }

    private func scheduleTimeChange(hour: Int, minute: Int) {
        guard enabled else { return }
        rescheduleTask?.cancel()
        rescheduleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                try await ReadingReminderScheduler.shared.scheduleDaily(hour: hour, minute: minute)
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "更新时间失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshStatus() async {
        authorizationStatus = await ReadingReminderScheduler.shared.authorizationStatus()
        if enabled && !authorizationStatus.allowsNotifications {
            enabled = false
            ReadingReminderScheduler.shared.cancel()
            if authorizationStatus == .denied {
                errorMessage = "系统通知权限已关闭，请重新授权后再开启提醒。"
            }
        } else if enabled {
            try? await ReadingReminderScheduler.shared.scheduleDaily(hour: hour, minute: minute)
        }
    }

    private var permissionDescription: String {
        switch authorizationStatus {
        case .notDetermined: "尚未请求"
        case .denied: "已拒绝"
        case .authorized: "已允许"
        case .provisional: "临时允许"
        case .ephemeral: "本次允许"
        @unknown default: "未知"
        }
    }

    private var permissionColor: Color {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: .green
        case .denied: .red
        case .notDetermined: .secondary
        @unknown default: .secondary
        }
    }
}
