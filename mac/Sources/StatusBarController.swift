import Cocoa
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

class StatusBarController {
    private let statusItem: NSStatusItem
    private let appearanceObserver = AppearanceObservingView(frame: .zero)
    private weak var delegate: AppDelegate?
    private let micItem = NSMenuItem(title: "麥克風", action: nil, keyEquivalent: "")
    private let hotkeyHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(delegate: AppDelegate) {
        self.delegate = delegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.addSubview(appearanceObserver)
            appearanceObserver.onAppearanceChange = { [weak self] in self?.refreshStatusBarIcon() }
        }
        refreshStatusBarIcon()

        let menu = NSMenu()
        menu.addItem(withTitle: "開始/停止錄音", action: #selector(toggleRecording), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "開啟 Typefree", action: #selector(openSettingsCenter), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "檢查更新…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
            .target = delegate
        menu.addItem(NSMenuItem.separator())
        menu.addItem(micItem)
        rebuildMicSubmenu()
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "修正上次結果", action: #selector(showManualCorrection), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        updateHotkeyHint()
        menu.addItem(hotkeyHintItem)
        menu.addItem(withTitle: "開啟輔助功能設定", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "結束 Typefree", action: #selector(quitApp), keyEquivalent: "q")
            .target = self
        statusItem.menu = menu

        setProcessingMode(delegate.currentProcessingMode())

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMicListOrSelectionChanged),
            name: .voicePolishMicrophoneListDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMicListOrSelectionChanged),
            name: .voicePolishMicrophoneSelectionDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onHotkeySettingsChanged),
            name: .voicePolishHotkeyDidChange,
            object: nil
        )
    }

    @objc private func onMicListOrSelectionChanged() {
        rebuildMicSubmenu()
        refreshStatusBarIcon()
    }

    private func rebuildMicSubmenu() {
        let mgr = MicrophoneManager.shared
        let submenu = NSMenu()

        let defaultName = mgr.systemDefaultDeviceName ?? "未知"
        let defaultItem = NSMenuItem(
            title: "跟隨系統預設（\(defaultName)）",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = MicrophoneManager.systemDefaultUID
        defaultItem.state = mgr.selectedUID == MicrophoneManager.systemDefaultUID ? .on : .off
        submenu.addItem(defaultItem)
        submenu.addItem(NSMenuItem.separator())

        for device in mgr.devices {
            let title = device.isBuiltIn ? "\(device.name)（推薦）" : device.name
            let item = NSMenuItem(title: title, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = mgr.selectedUID == device.uid ? .on : .off
            submenu.addItem(item)
        }

        micItem.submenu = submenu
    }

    @objc private func onHotkeySettingsChanged() {
        updateHotkeyHint()
    }

    private func updateHotkeyHint() {
        let shortcut = RecordingHotkeyShortcut.current.displayName
        let action = RecordingHotkeyBehavior.isTapToggleEnabled ? "長按/按一下" : "長按"
        hotkeyHintItem.title = "快速鍵：\(action) \(shortcut) 錄音"
        hotkeyHintItem.isEnabled = false
    }

    private func refreshStatusBarIcon() {
        guard let baseIcon = NSImage(named: "statusbar-icon") else {
            statusItem.button?.title = "VP"
            statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            return
        }

        let displayIcon: NSImage
        if MicrophoneManager.shared.isUsingNonDefault {
            var tintedIcon: NSImage?
            statusItem.button?.effectiveAppearance.performAsCurrentDrawingAppearance {
                tintedIcon = baseIcon.withBlueDotOverlay()
            }
            displayIcon = tintedIcon ?? baseIcon
            displayIcon.isTemplate = false
        } else {
            displayIcon = baseIcon
            displayIcon.isTemplate = true
        }
        displayIcon.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = displayIcon
        statusItem.button?.title = ""
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        MicrophoneManager.shared.select(uid: uid)
    }

    func setTitle(_ title: String) {
        // Don't overwrite icon with text — icon is always shown
        // Title is only used as fallback when icon isn't available
        if statusItem.button?.image == nil {
            statusItem.button?.title = title
        }
    }

    func setProcessingMode(_ mode: ProcessingMode) {
        // 处理模式选择器已从 UI 移除（应用固定云端直出）。保留方法以兼容调用方。
    }

    @objc private func toggleRecording() {
        delegate?.toggleRecording()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showManualCorrection() {
        DispatchQueue.main.async {
            self.delegate?.showManualCorrection()
        }
    }

    @objc private func openSettingsCenter() {
        DispatchQueue.main.async {
            self.delegate?.showSettingsCenter()
        }
    }

    @objc private func openAccessibilitySettings() {
        delegate?.openAccessibilitySettings()
    }

}

private extension NSImage {
    /// 在图标右下角合成一个小蓝点，用于状态栏角标
    func withBlueDotOverlay() -> NSImage? {
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        // 先把基础图标按模板着色为深色画上去
        let rect = NSRect(origin: .zero, size: size)
        NSColor.labelColor.set()
        rect.fill()
        draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)

        // 角标：右下角小蓝点
        let dotDiameter = max(size.width * 0.32, 5)
        let dot = NSRect(
            x: size.width - dotDiameter,
            y: 0,
            width: dotDiameter,
            height: dotDiameter
        )
        NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.95, alpha: 1).set()
        NSBezierPath(ovalIn: dot).fill()
        return result
    }
}
