import AppKit
import Network
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "local.ip-location-menu-bar", category: "refresh")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        if isOffline {
            symbolName = "wifi.slash"
            title = (info?.shortLocation).nonEmpty ?? "网络已断开"
        } else if let info, !info.shortLocation.isEmpty {
            symbolName = lastError == nil ? "mappin.and.ellipse" : "exclamationmark.triangle"
            title = info.shortLocation
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
        button.title = " " + title
        button.toolTip = isOffline ? "网络已断开，恢复后自动刷新" : lastError
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let info {
            menu.addItem(.sectionHeader(title: "位置"))
            addDetailRow(to: menu, label: "国家", value: info.countryName)
            addDetailRow(to: menu, label: "地区", value: info.region)
            addDetailRow(to: menu, label: "城市", value: info.city)
            addDetailRow(to: menu, label: "邮编", value: info.postal)
            addDetailRow(to: menu, label: "经纬度", value: info.coordinates)
            addDetailRow(to: menu, label: "时区", value: info.timezoneDescription)
            menu.addItem(.separator())

            menu.addItem(.sectionHeader(title: "网络"))
            addDetailRow(to: menu, label: "IP", value: info.ip)
            addDetailRow(to: menu, label: "运营商", value: info.org)
            addDetailRow(to: menu, label: "ASN", value: info.asn)
            menu.addItem(.separator())
        }

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

    /// Adds a "label  value" row; clicking it copies the value.
    private func addDetailRow(to menu: NSMenu, label: String, value: String?) {
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
            attributes: [.foregroundColor: NSColor.labelColor, .font: font, .paragraphStyle: paragraph]
        ))

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
