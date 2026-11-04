import AppKit
import Network
import OSLog
import ServiceManagement
import UserNotifications

private let log = Logger(subsystem: "local.ip-location-menu-bar", category: "refresh")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Defaults to one hour; override with REFRESH_INTERVAL=<seconds> for testing.
    private let refreshInterval: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["REFRESH_INTERVAL"],
           let seconds = TimeInterval(raw), seconds >= 10 {
            return seconds
        }
        return 3600
    }()

    private let client = IPAPIClient()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?

    /// Backoff between automatic retries after a failed refresh, in seconds.
    private static let retryDelays: [TimeInterval] = [5, 15, 30, 60, 120]

    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?
    private var pendingRefresh: Task<Void, Never>?
    private var retryAttempt = 0
    private var nextRetryAt: Date?
    private var refreshQueued = false

    private var info: IPInfo?
    private var lastUpdated: Date?
    private var lastError: String?
    private var isRefreshing = false
    private var isOffline = false

    private let favorites = FavoriteStore()
    private var match: ProfileMatch = .noFavorites
    private var mismatchDetectedAt: Date?
    /// Signature already notified about, so one mismatch only notifies once.
    private var notifiedSignature: String?

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. under `swift run`).
    private let canNotify = Bundle.main.bundleURL.pathExtension == "app"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let retryTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.wantsLayer = true
        if canNotify { UNUserNotificationCenter.current().delegate = self }
        updateStatusButton()
        rebuildMenu()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isOffline else { return }
                log.notice("Hourly refresh")
                self.retryAttempt = 0
                await self.refresh()
            }
        }
        refreshTimer?.tolerance = 60

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.handlePathUpdate(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "local.ip-location-menu-bar.path-monitor"))

        Task { await refresh() }
    }

    // MARK: - Network changes

    /// Refreshes when the network comes back or switches (Wi-Fi to Ethernet, VPN on/off, new hotspot).
    private func handlePathUpdate(_ path: NWPath) {
        let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        let signature = "\(path.status)|\(interfaces)"
        defer { lastPathSignature = signature }

        guard path.status == .satisfied else {
            log.notice("Network unavailable (\(signature, privacy: .public))")
            isOffline = true
            cancelPendingRefresh()
            updateStatusButton()
            rebuildMenu()
            return
        }

        let wasOffline = isOffline
        isOffline = false
        // The monitor reports the initial path right after start; launch already refreshes.
        guard let previous = lastPathSignature, previous != signature || wasOffline else { return }

        log.notice("Network changed (\(previous, privacy: .public) -> \(signature, privacy: .public)), refreshing soon")
        retryAttempt = 0
        // Debounce: interfaces often flap several times while a connection settles.
        scheduleRefresh(after: 2)
        updateStatusButton()
        rebuildMenu()
    }

    // MARK: - Refresh

    private func scheduleRefresh(after seconds: TimeInterval) {
        pendingRefresh?.cancel()
        nextRetryAt = Date().addingTimeInterval(seconds)
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        nextRetryAt = nil
    }

    private func refresh() async {
        guard !isRefreshing else {
            // A network change arrived mid-request; the result may already be stale.
            refreshQueued = true
            return
        }
        cancelPendingRefresh()
        isRefreshing = true
        updateStatusButton()
        rebuildMenu()

        do {
            info = try await client.fetch()
            lastUpdated = Date()
            lastError = nil
            retryAttempt = 0
            log.notice("Refresh succeeded")
            evaluateMatch()
        } catch where error.isCancellation {
            log.notice("Refresh cancelled")
        } catch {
            lastError = error.localizedDescription
            log.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            scheduleRetry(after: error)
        }

        isRefreshing = false
        if refreshQueued {
            refreshQueued = false
            scheduleRefresh(after: 1)
        }
        updateStatusButton()
        rebuildMenu()
    }

    private func scheduleRetry(after error: Error) {
        // While offline the path monitor triggers the next attempt instead.
        guard !isOffline, retryAttempt < Self.retryDelays.count else { return }
        var delay = Self.retryDelays[retryAttempt]
        if error.isRateLimited { delay = max(delay, 60) }
        retryAttempt += 1
        log.notice("Retry \(self.retryAttempt) in \(Int(delay))s")
        scheduleRefresh(after: delay)
    }

    @objc private func refreshNow() {
        retryAttempt = 0
        Task { await refresh() }
    }

    @objc private func systemDidWake() {
        // The path monitor usually fires on wake too; this covers waking onto the same network.
        log.notice("System woke")
        retryAttempt = 0
        scheduleRefresh(after: 3)
    }

    // MARK: - Status bar button

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let title: String
        var toolTip = isOffline ? "网络已断开，恢复后自动刷新" : lastError
        var alert = false
        if isOffline {
            symbolName = "wifi.slash"
            title = (info?.shortLocation).nonEmpty ?? "网络已断开"
        } else if let info, !info.shortLocation.isEmpty {
            title = info.shortLocation
            switch match {
            case .mismatched(let profile, _):
                symbolName = "xmark.shield.fill"
                alert = true
                toolTip = "与收藏档案「\(profile.name)」不符"
            case _ where lastError != nil:
                symbolName = "exclamationmark.triangle"
            case .matched:
                symbolName = "checkmark.shield"
            default:
                symbolName = "mappin.and.ellipse"
            }
        } else if isRefreshing {
            symbolName = "mappin.and.ellipse"
            title = "定位中…"
        } else {
            symbolName = "exclamationmark.triangle"
            title = "无数据"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "IP 定位")
        image?.isTemplate = true
        button.image = image
        button.toolTip = toolTip

        // Mismatch: a solid red pill so it stands out in peripheral vision.
        button.layer?.backgroundColor = alert ? NSColor.systemRed.cgColor : nil
        button.layer?.cornerRadius = 4
        button.contentTintColor = alert ? .white : nil
        if alert {
            button.attributedTitle = NSAttributedString(
                string: " \(title) ",
                attributes: [.foregroundColor: NSColor.white, .font: NSFont.menuBarFont(ofSize: 0)]
            )
        } else {
            button.title = " " + title
        }
    }

    // MARK: - Favorite profiles

    private func evaluateMatch() {
        guard let info else {
            match = .noFavorites
            return
        }
        if let ignored = favorites.ignoredSignature, ignored != info.signature {
            favorites.ignoredSignature = nil
        }

        let wasMismatch = match.isMismatch
        match = favorites.match(info)

        guard case .mismatched(let profile, let differences) = match else {
            mismatchDetectedAt = nil
            notifiedSignature = nil
            return
        }
        if !wasMismatch { mismatchDetectedAt = Date() }
        log.notice("Profile mismatch: \(info.signature, privacy: .public)")
        if notifiedSignature != info.signature {
            notifiedSignature = info.signature
            sendMismatchNotification(profile: profile, differences: differences, info: info)
        }
    }

    private func sendMismatchNotification(profile: FavoriteProfile, differences: [FavoriteProfile.Difference], info: IPInfo) {
        guard canNotify, favorites.notifyOnMismatch else { return }

        let content = UNMutableNotificationContent()
        content.title = "IP 与收藏档案不符"
        let current = [info.shortLocation.isEmpty ? nil : info.shortLocation, info.asn.nonEmpty]
            .compactMap { $0 }.joined(separator: "，")
        let expected = differences.map(\.expected).joined(separator: "，")
        content.body = "当前：\(current)\n「\(profile.name)」应为：\(expected)"
        content.sound = .default

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "profile-mismatch", content: content, trigger: nil))
        }
    }

    /// Show banners even when the app counts as active (e.g. while its menu is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    @objc private func addCurrentToFavorites() {
        guard let info else { return }

        let alert = NSAlert()
        alert.messageText = "收藏当前 IP 档案"
        alert.informativeText = "之后刷新时，如果国家、地区或 ASN 与它不同，菜单栏会变红提醒。"
        alert.addButton(withTitle: "收藏")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = [info.city.nonEmpty, info.org.nonEmpty].compactMap { $0 }.joined(separator: " · ")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        favorites.add(FavoriteProfile(from: info, name: name.isEmpty ? "收藏 \(favorites.profiles.count + 1)" : name))
        favoritesChanged()
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        favorites.remove(id: id)
        favoritesChanged()
    }

    @objc private func toggleLockIP(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        favorites.toggleLockIP(id: id)
        favoritesChanged()
    }

    @objc private func ignoreMismatch() {
        favorites.ignoredSignature = info?.signature
        favoritesChanged()
    }

    @objc private func toggleNotifyOnMismatch() {
        favorites.notifyOnMismatch.toggle()
        rebuildMenu()
    }

    private func favoritesChanged() {
        evaluateMatch()
        updateStatusButton()
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        var expected: [FavoriteProfile.Field: String] = [:]
        if case .mismatched(let profile, let differences) = match {
            for difference in differences { expected[difference.field] = difference.expected }
            menu.addItem(mismatchBanner(profile: profile, differenceCount: differences.count))
        }

        if let info {
            menu.addItem(.sectionHeader(title: "位置"))
            addDetailRow(to: menu, label: "国家", value: info.countryName, expected: expected[.country])
            addDetailRow(to: menu, label: "地区", value: info.region, expected: expected[.region])
            addDetailRow(to: menu, label: "城市", value: info.city)
            addDetailRow(to: menu, label: "邮编", value: info.postal)
            addDetailRow(to: menu, label: "经纬度", value: info.coordinates)
            addDetailRow(to: menu, label: "时区", value: info.timezoneDescription)
            menu.addItem(.separator())

            menu.addItem(.sectionHeader(title: "网络"))
            addDetailRow(to: menu, label: "IP", value: info.ip, expected: expected[.ip])
            addDetailRow(to: menu, label: "运营商", value: info.org)
            addDetailRow(to: menu, label: "ASN", value: info.asn, expected: expected[.asn])
            menu.addItem(.separator())
        }

        if match.isMismatch {
            let ignoreItem = NSMenuItem(title: "暂时忽略，直到下次变化", action: #selector(ignoreMismatch), keyEquivalent: "")
            ignoreItem.target = self
            menu.addItem(ignoreItem)
        }
        menu.addItem(favoritesMenuItem())
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: isRefreshing ? "正在刷新…" : "立即刷新",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let updatedItem = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)
        if let notice = noticeLine() {
            let noticeItem = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            noticeItem.isEnabled = false
            noticeItem.attributedTitle = NSAttributedString(
                string: notice,
                attributes: [
                    .foregroundColor: isOffline ? NSColor.secondaryLabelColor : NSColor.systemRed,
                    .font: NSFont.menuFont(ofSize: 0),
                ]
            )
            menu.addItem(noticeItem)
        }
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func statusLine() -> String {
        let schedule = refreshInterval == 3600 ? "每小时自动" : "每 \(Int(refreshInterval)) 秒自动"
        guard let lastUpdated else { return "尚未更新 · \(schedule)" }
        return "\(Self.timeFormatter.string(from: lastUpdated)) 更新 · \(schedule)"
    }

    /// Offline notice or the last error, with when the next automatic retry happens.
    private func noticeLine() -> String? {
        if isOffline { return "网络已断开，恢复后自动刷新" }
        guard let lastError, !isRefreshing else { return nil }
        guard let nextRetryAt, pendingRefresh != nil else {
            return "\(lastError)（已停止自动重试）"
        }
        return "\(lastError)，\(Self.retryTimeFormatter.string(from: nextRetryAt)) 自动重试"
    }

    /// Red banner at the top of the menu while the info does not match any favorite.
    private func mismatchBanner(profile: FavoriteProfile, differenceCount: Int) -> NSMenuItem {
        let title = NSTextField(labelWithString: "与收藏档案不符：\(profile.name)")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail

        let detected = mismatchDetectedAt.map { Self.timeFormatter.string(from: $0) + " 检测到 · " } ?? ""
        let subtitle = NSTextField(labelWithString: "\(detected)\(differenceCount) 项不同")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.85)

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.systemRed.cgColor
        stack.layer?.cornerRadius = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        container.autoresizingMask = [.width]
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func favoritesMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let matchedID: UUID? = if case .matched(let profile) = match { profile.id } else { nil }
        for profile in favorites.profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            let summary = profile.summary
            if !summary.isEmpty {
                let title = NSMutableAttributedString(string: profile.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                title.append(NSAttributedString(
                    string: "  \(summary)",
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
                ))
                item.attributedTitle = title
            }
            item.state = profile.id == matchedID ? .on : .off

            let actions = NSMenu()
            let lockItem = NSMenuItem(title: "锁定 IP（\(profile.ip ?? "无")）", action: #selector(toggleLockIP(_:)), keyEquivalent: "")
            lockItem.target = self
            lockItem.representedObject = profile.id
            lockItem.state = profile.lockIP ? .on : .off
            actions.addItem(lockItem)
            let removeItem = NSMenuItem(title: "删除", action: #selector(removeFavorite(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = profile.id
            actions.addItem(removeItem)
            item.submenu = actions

            submenu.addItem(item)
        }
        if !favorites.profiles.isEmpty { submenu.addItem(.separator()) }

        let addItem = NSMenuItem(title: "把当前档案加入收藏…", action: #selector(addCurrentToFavorites), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = info != nil
        submenu.addItem(addItem)

        if canNotify {
            let notifyItem = NSMenuItem(title: "不符时发系统通知", action: #selector(toggleNotifyOnMismatch), keyEquivalent: "")
            notifyItem.target = self
            notifyItem.state = favorites.notifyOnMismatch ? .on : .off
            submenu.addItem(notifyItem)
        }

        let item = NSMenuItem(title: "收藏档案", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Adds a "label  value" row; clicking it copies the value.
    /// With `expected`, the value is shown in red followed by "应为 <expected>".
    private func addDetailRow(to menu: NSMenu, label: String, value: String?, expected: String? = nil) {
        guard let value = value.nonEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 64)]
        let font = NSFont.menuFont(ofSize: 0)

        let title = NSMutableAttributedString(
            string: label + "\t",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font, .paragraphStyle: paragraph]
        )
        title.append(NSAttributedString(
            string: value,
            attributes: [
                .foregroundColor: expected == nil ? NSColor.labelColor : NSColor.systemRed,
                .font: font,
                .paragraphStyle: paragraph,
            ]
        ))
        if let expected {
            title.append(NSAttributedString(
                string: "  应为 \(expected)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font, .paragraphStyle: paragraph]
            ))
        }

        let item = NSMenuItem(title: "\(label) \(value)", action: #selector(copyValue(_:)), keyEquivalent: "")
        item.attributedTitle = title
        item.representedObject = value
        item.target = self
        item.toolTip = "点击复制"
        menu.addItem(item)
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更改登录时启动"
            alert.informativeText = "\(error.localizedDescription)\n\n请先把应用移到「应用程序」文件夹再试，或到「系统设置 → 通用 → 登录项」中手动添加。"
            NSApp.activate()
            alert.runModal()
        }
        rebuildMenu()
    }
}
