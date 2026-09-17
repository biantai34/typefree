import Cocoa
import QuartzCore

enum OverlayState {
    case recording
    case processing(message: String)
    case done(text: String)
    case error(message: String)
    case learned(description: String)
    case learnSuggestion(description: String)
}

/// 录音浮窗样式：可在「设置 → 设置 → 录音浮窗」里切换。
enum OverlayStyle: String {
    case colorful   // 彩色 Siri 旋转渐变
    case mono       // 墨黑胶囊 + 白色声波（与 iOS 键盘 / App 图标统一）

    static let userDefaultsKey = "OverlayStyle"

    static var current: OverlayStyle {
        OverlayStyle(rawValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "") ?? .mono
    }
}

/// 录音浮窗操作按钮：新版显示取消/完成按钮；经典版保留旧的纯声波胶囊。
enum OverlayControlsMode: String {
    case buttons
    case classic

    static let userDefaultsKey = "OverlayControlsMode"

    static var current: OverlayControlsMode {
        OverlayControlsMode(rawValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "") ?? .buttons
    }
}

/// 录音胶囊上显示哪些操作按钮（只在「显示操作按钮」样式下有意义）：
/// 鼠标/键盘长按 = 不显示（松手即完成）；单击切换或锁定录音 = 叉号 + 对勾。
enum RecordingControls {
    case hidden
    case cancelOnly
    case cancelAndFinish
}

class OverlayWindow {
    private var window: NSPanel?
    private var capsuleView: SiriCapsuleView?
    private var learnedWindow: NSWindow?
    private var learnedDismissTimer: Timer?
    private var mousePassthroughTimer: Timer?
    /// 用显示器 ID 记住本次录音所在屏幕，屏幕排列变化后不复用旧坐标。
    private var recordingDisplayID: CGDirectDisplayID?
    private var learnedDisplayID: CGDirectDisplayID?
    private var screenObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        screenObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleScreenReposition()
        })
        // AppKit 也可能因切换桌面或移除显示器而自动挪动窗口；等它完成后再校正。
        screenObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let changedWindow = notification.object as? NSWindow,
                  changedWindow === self.window || changedWindow === self.learnedWindow else { return }
            self.scheduleScreenReposition()
        })
    }

    deinit {
        screenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        mousePassthroughTimer?.invalidate()
        learnedDismissTimer?.invalidate()
    }
    var onUndoLearn: (() -> Void)?
    var onAcceptLearnSuggestion: (() -> Void)?
    var onDismissLearnSuggestion: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onFinishRecording: (() -> Void)?
    var onLockedDragStart: ((NSPoint) -> Bool)?
    var onLockedDragUpdate: ((NSPoint) -> Void)?
    var onLockedDragEnd: ((NSPoint) -> Void)?
    var onUndoCancel: (() -> Void)?
    /// 下一次 show(.recording) 用哪套按钮；录音中可用 setRecordingControls 改
    var recordingControls: RecordingControls = .cancelAndFinish
    /// 默认输出语言的标签（如 EN）；nil = 跟随说话语言，不显示
    var languageTag: String?
    /// 提问模式（长按空白处问 AI）：录音时胶囊四周一圈蓝色光环
    var askGlow = false

    /// 锁定录音必须有结束入口，经典纯声波样式也临时显示操作按钮。
    func setRecordingLocked(_ locked: Bool) {
        guard let capsuleView, capsuleView.recordingLocked != locked else { return }
        capsuleView.recordingLocked = locked
        if !locked { capsuleView.isLockedDragActive = false }
        capsuleView.setCancelArmed(false)
        setRecordingControls(locked ? .cancelAndFinish : .hidden)
        if locked { capsuleView.showTransientCaption("已鎖定", seconds: 1.2) }
    }

    func setRecordingControls(_ controls: RecordingControls) {
        recordingControls = controls
        capsuleView?.setRecordingControls(controls)
        if window?.isVisible == true, capsuleView?.hasActionControls == true, controls != .hidden {
            startMousePassthroughTracking()
        } else {
            stopMousePassthroughTracking()
            window?.ignoresMouseEvents = true
        }
    }

    /// 拖开取消：到点 = 红边柔光 + 叉号，干脆地出现；解除同样干脆地退回
    func setCancelArmed(_ armed: Bool) {
        capsuleView?.setCancelArmed(armed)
    }

    /// 录音胶囊此刻在屏幕上的中心（AppKit 坐标），供「朝胶囊移动 = 不取消」判定
    var capsuleCenterOnScreen: NSPoint? {
        guard let window, window.isVisible else { return nil }
        return NSPoint(x: window.frame.midX, y: window.frame.midY)
    }

    var capsuleFrameOnScreen: NSRect? {
        guard let window, window.isVisible, let capsuleView,
              let pillFrame = capsuleView.recordingPillFrame else { return nil }
        return window.convertToScreen(capsuleView.convert(pillFrame, to: nil))
    }

    func endCancelGesture() {
        capsuleView?.endCancelGesture()
    }

    /// 录音中短暂显示一句说明（如首次使用的「拖开鼠标可取消」），之后恢复声波
    func showRecordingCaption(_ text: String, seconds: TimeInterval) {
        capsuleView?.showTransientCaption(text, seconds: seconds)
    }

    func show(state: OverlayState) {
        switch state {
        case .learned(let description):
            hideLearnedWindow()
            hide()
            showLearnedCapsule(description: description)
            return
        case .learnSuggestion(let description):
            hideLearnedWindow()
            hide()
            showLearnSuggestionCapsule(description: description)
            return
        default:
            hideLearnedWindow()
        }
        // 样式/操作按钮设置变了 → 丢弃旧浮窗，下次按新设置重建。
        if let cv = capsuleView, cv.style != OverlayStyle.current || cv.controlsMode != OverlayControlsMode.current {
            hide()
            window = nil
            capsuleView = nil
        }
        let shouldAnimateAppear: Bool
        if case .recording = state {
            // 每次新录音重新选屏；之后的识别/润色阶段留在同一块屏幕。
            recordingDisplayID = preferredScreen().map(Self.displayID)
            shouldAnimateAppear = !(window?.isVisible ?? false)
        } else {
            shouldAnimateAppear = false
        }
        if window == nil { createWindow() }
        repositionWindow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsuleView?.recordingControls = recordingControls
        capsuleView?.languageTag = languageTag
        capsuleView?.askGlow = askGlow
        capsuleView?.update(state: state)
        capsuleView?.layoutSubtreeIfNeeded()
        capsuleView?.displayIfNeeded()
        CATransaction.commit()
        if case .recording = state, OverlayControlsMode.current == .buttons, recordingControls != .hidden {
            startMousePassthroughTracking()
        } else {
            stopMousePassthroughTracking()
            window?.ignoresMouseEvents = true
        }
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 按钮、图层及入场动画先准备好，避免窗口先亮一帧再补淡入。
        if shouldAnimateAppear {
            capsuleView?.animateAppear()
        }
        window?.orderFrontRegardless()
        repositionWindow() // 首次显示时 AppKit 可能调整位置，显示后再对齐一次。
    }

    func hide() {
        stopMousePassthroughTracking()
        capsuleView?.stopAnimations()
        window?.orderOut(nil)
    }

    func completeProgressOnly(completion: (() -> Void)? = nil) {
        capsuleView?.completeProgressOnly(completion: completion)
    }

    func updateAudioLevel(_ level: Float) {
        capsuleView?.updateAudioLevel(level)
    }

    /// Switch to think mode (Thinking text + progress bar), call after show(.processing)
    func enterThinkMode() {
        capsuleView?.enterThinkMode()
    }

    private func createWindow() {
        let controlsMode = OverlayControlsMode.current
        // 四周留出「拖开取消」红晕的空间；药丸中心仍在可见区底部 +32pt（与之前一致）
        let margin: CGFloat = 28
        let winW: CGFloat = 120 + margin * 2
        let winH: CGFloat = 34 + margin * 2

        // 先创建，再用全局屏幕坐标定位，避免窗口初始化时套用另一块屏幕的原点。
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let cv = SiriCapsuleView(
            frame: NSRect(x: 0, y: 0, width: winW, height: winH),
            style: OverlayStyle.current,
            controlsMode: controlsMode
        )
        cv.onCancelRecording = { [weak self] in self?.onCancelRecording?() }
        cv.onFinishRecording = { [weak self] in self?.onFinishRecording?() }
        cv.onLockedDragStart = { [weak self] point in self?.onLockedDragStart?(point) ?? false }
        cv.onLockedDragUpdate = { [weak self] point in self?.onLockedDragUpdate?(point) }
        cv.onLockedDragEnd = { [weak self] point in self?.onLockedDragEnd?(point) }
        w.contentView = cv
        self.window = w
        self.capsuleView = cv
    }

    /// 允许已显示的胶囊重新对齐；按显示器 ID 找到最新可用区域，拔掉后退回当前屏幕。
    private func repositionWindow() {
        guard let window, let screen = screen(for: recordingDisplayID) else { return }
        recordingDisplayID = Self.displayID(screen)
        let origin = Self.bottomOrigin(size: window.frame.size, visibleFrame: screen.visibleFrame,
                                       bottomInset: 32 - window.frame.height / 2)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    private func repositionLearnedWindow() {
        guard let learnedWindow, let screen = screen(for: learnedDisplayID) else { return }
        learnedDisplayID = Self.displayID(screen)
        let origin = Self.bottomOrigin(size: learnedWindow.frame.size, visibleFrame: screen.visibleFrame,
                                       bottomInset: 15)
        if learnedWindow.frame.origin != origin { learnedWindow.setFrameOrigin(origin) }
    }

    private func scheduleScreenReposition() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window?.isVisible == true { self.repositionWindow() }
            if self.learnedWindow?.isVisible == true { self.repositionLearnedWindow() }
            self.updateMousePassthrough()
        }
    }

    private static func bottomOrigin(size: NSSize, visibleFrame: NSRect, bottomInset: CGFloat) -> NSPoint {
        NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + bottomInset)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        NSScreen.screens.first { Self.displayID($0) == displayID } ?? preferredScreen()
    }

    private func startMousePassthroughTracking() {
        updateMousePassthrough()
        guard mousePassthroughTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateMousePassthrough()
        }
        RunLoop.main.add(timer, forMode: .common)
        mousePassthroughTimer = timer
    }

    private func stopMousePassthroughTracking() {
        mousePassthroughTimer?.invalidate()
        mousePassthroughTimer = nil
    }

    private func updateMousePassthrough() {
        guard let window, let capsuleView, window.isVisible else {
            window?.ignoresMouseEvents = true
            return
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = capsuleView.convert(windowPoint, from: nil)
        window.ignoresMouseEvents = !capsuleView.shouldHandleMouse(at: viewPoint)
    }

    // MARK: - 统一提示胶囊（文字条 / 已学会 / 学习建议 / 已取消 / 错误原因）

    /// 提示胶囊左侧小圆点的语义色。所有临时提示共用同一近黑底 + 白字，只靠这个点区分类型，
    /// 不再各自换底色/描边/毛玻璃（之前 6 种浮窗 3 套风格，是不同时期一个个加出来的）。
    enum CapsuleAccent {
        case error, warning, success, neutral

        var color: NSColor {
            switch self {
            case .error:   return NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1)
            case .warning: return NSColor(red: 0.95, green: 0.64, blue: 0.20, alpha: 1)
            case .success: return NSColor(red: 0.18, green: 0.88, blue: 0.54, alpha: 1)
            case .neutral: return NSColor.white.withAlphaComponent(0.35)
            }
        }
    }

    /// 提示胶囊里的按钮：primary=白底黑字（近黑主题的反色，不用系统蓝），否则白 14% 透明底白字。
    private struct CapsuleAction {
        let title: String
        let primary: Bool
        let action: Selector
        var systemImage: String? = nil
    }

    /// 与主录音胶囊同色的近黑底（见 SiriCapsuleView.restFillColor 的 mono 值）。
    private static let capsuleFill = NSColor(white: 0.055, alpha: 0.98)
    private static let capsuleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    /// 显示一条带文字的提示（如"请先在设置里填入 API key"）。默认橙点（提示/警告），不抢焦点，5 秒后自动消失。
    func showHint(_ message: String, accent: CapsuleAccent = .warning) {
        showCapsuleBar(message, accent: accent, seconds: 5.0)
    }

    /// 失败原因：红点、按文字长短停留。红色主胶囊本身不显示文字（只闪一下表示"失败了"），
    /// 原因必须靠这条说清——否则用户只看到一个无字红框，不知道是没开通服务、断网还是别的。
    func showErrorHint(_ message: String, seconds: TimeInterval) {
        showCapsuleBar(message, accent: .error, seconds: seconds)
    }

    /// "已學會「xx」· 復原"：綠點，5 秒後自動消失。
    private func showLearnedCapsule(description: String) {
        showCapsuleBar("已學會「\(description)」", accent: .success, seconds: 5.0,
                       actions: [CapsuleAction(title: "復原", primary: false, action: #selector(undoLearnedTapped))])
    }

    /// "學習「xx」？ 稍後 / 學習"：灰點，不自動消失，等使用者表態。
    private func showLearnSuggestionCapsule(description: String) {
        showCapsuleBar("學習「\(description)」？", accent: .neutral, seconds: nil,
                       actions: [CapsuleAction(title: "稍後", primary: false, action: #selector(dismissLearnSuggestionTapped)),
                                 CapsuleAction(title: "學習", primary: true, action: #selector(acceptLearnSuggestionTapped))])
    }

    /// 「已取消」+ 白色圓形復原按鈕，不顯示語意圓點；9 秒後自動消失（與音訊暫存時長一致）。
    /// 點復原箭頭 → AppDelegate 用暫存的錄音重新識別輸出。
    func showCancelledCapsule() {
        showCapsuleBar("已取消", accent: nil, seconds: 9.0,
                       actions: [CapsuleAction(title: "復原取消", primary: true,
                                               action: #selector(undoCancelTapped), systemImage: "arrow.uturn.backward")])
    }

    /// 统一提示胶囊：近黑底 + 左侧语义圆点 + 白字（12.5 medium）+ 可选按钮。
    /// 与录音胶囊同一套尺寸：高 34（纯文字过长时折两行 → 52），圆角全胶囊，底边离屏幕可见区 15pt（和录音胶囊一样），居中。
    /// 同一时刻只有一条（新的顶掉旧的）；seconds=nil 表示不自动消失（等用户点按钮）。
    private func showCapsuleBar(_ message: String,
                                accent: CapsuleAccent?,
                                seconds: TimeInterval?,
                                actions: [CapsuleAction] = []) {
        hideLearnedWindow()
        hide()
        guard let screen = preferredScreen() else { return }
        learnedDisplayID = Self.displayID(screen)
        let sf = screen.visibleFrame

        let compactStatus = accent == nil && actions.count == 1 && actions[0].systemImage != nil
        let font = compactStatus ? NSFont.systemFont(ofSize: 14, weight: .medium) : Self.capsuleFont
        let attr = NSMutableAttributedString(string: message, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ])
        if compactStatus {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            attr.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attr.length))
        }
        dimArrows(in: attr, fullText: message)

        // 尺寸：NSTextField 实际排版比 NSString 量出来的宽几个点（cell 内边距），多留 12pt 免得末尾被截
        let measuredW = ceil(attr.size().width) + 12
        let leftPad: CGFloat = 16
        let dotSize: CGFloat = accent == nil ? 0 : 7
        let dotGap: CGFloat = accent == nil ? 0 : 9
        let textGap: CGFloat = 12, btnGap: CGFloat = 6
        let rightPad: CGFloat = actions.isEmpty ? 18 : (actions.last?.systemImage == nil ? 7 : 5)
        let lineH: CGFloat = 18

        let buttons = actions.map {
            makePillButton(title: $0.title, primary: $0.primary, action: $0.action, systemImage: $0.systemImage)
        }
        let buttonsW = buttons.reduce(CGFloat(0)) { $0 + $1.frame.width } + btnGap * CGFloat(max(0, buttons.count - 1))

        let fixedW = leftPad + dotSize + dotGap + (actions.isEmpty ? 0 : textGap + buttonsW) + rightPad
        // 纯文字：最宽 640、可折两行；带按钮：文字最宽 320、单行截尾（按钮得留在可见处）
        let maxTextW: CGFloat = actions.isEmpty ? min(640, sf.width - 40) - fixedW : 320
        let textW = min(measuredW, maxTextW)
        let twoLines = actions.isEmpty && measuredW > maxTextW
        let winW = fixedW + textW   // 宽度贴合文字（不设最小宽，短文案不留空白）
        let winH: CGFloat = twoLines ? 52 : 34
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = actions.isEmpty   // 没按钮就不抢鼠标：全局热键在别的 app 触发也不打断用户
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.capsuleFill.cgColor
        container.layer?.cornerRadius = winH / 2
        container.layer?.masksToBounds = true

        if let accent {
            let dot = NSView(frame: NSRect(x: leftPad, y: (winH - dotSize) / 2, width: dotSize, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = accent.color.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            if accent != .neutral {
                dot.layer?.shadowColor = accent.color.cgColor
                dot.layer?.shadowOpacity = 0.7
                dot.layer?.shadowRadius = 4
                dot.layer?.shadowOffset = .zero
                dot.layer?.masksToBounds = false
            }
            container.addSubview(dot)
        }

        let label = compactStatus ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = attr
        label.font = font
        label.alignment = compactStatus ? .center : .left
        // 换行 + 最多 N 行 + 末行截尾：lineBreakMode 必须是 byWordWrapping，
        // 设成 byTruncatingTail 会直接关掉换行（整段挤在第一行截尾）。
        label.maximumNumberOfLines = twoLines ? 2 : 1
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        // 短状态使用单行文字的实际高度，并在圆形按钮左侧的完整区域居中。
        let labelH = compactStatus ? ceil(label.fittingSize.height) : lineH * CGFloat(twoLines ? 2 : 1)
        let textX = compactStatus ? 0 : leftPad + dotSize + dotGap
        let labelWidth = compactStatus ? winW - rightPad - buttonsW : textW
        label.frame = NSRect(x: textX, y: (winH - labelH) / 2, width: labelWidth, height: labelH)
        container.addSubview(label)

        var bx = winW - rightPad
        for btn in buttons.reversed() {
            btn.target = self
            btn.frame.origin = CGPoint(x: bx - btn.frame.width, y: (winH - btn.frame.height) / 2)
            container.addSubview(btn)
            bx -= btn.frame.width + btnGap
        }

        w.contentView = container
        learnedWindow = w
        repositionLearnedWindow()
        w.orderFrontRegardless()
        repositionLearnedWindow()

        learnedDismissTimer?.invalidate()
        learnedDismissTimer = nil
        if let seconds = seconds {
            learnedDismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                self?.hideLearnedWindow()
            }
        }
    }

    /// 胶囊内的圆角按钮：primary=白底黑字主按钮，否则白 14% 透明底白字次要按钮。
    private func makePillButton(title: String, primary: Bool, action: Selector, systemImage: String? = nil) -> NSButton {
        if let systemImage {
            // 复用录音对勾的尺寸、白底和悬停/按下效果，只替换图标。
            let button = CapsuleActionButton(role: .finish, style: .mono, target: self, action: action)
            button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
            button.setAccessibilityLabel(title)
            button.toolTip = title
            button.frame = NSRect(x: 0, y: 0, width: CapsuleActionButton.diameter, height: CapsuleActionButton.diameter)
            return button
        }
        let h: CGFloat = 24   // 提示条改为 34 高后，按钮随之收小
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let textColor: NSColor = primary ? NSColor(white: 0.07, alpha: 1) : .white
        let attrTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        let width = max(44, ceil(attrTitle.size().width) + 26)

        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: h))
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.setButtonType(.momentaryChange)
        btn.attributedTitle = attrTitle
        btn.action = action
        btn.wantsLayer = true
        btn.layer?.cornerRadius = h / 2
        btn.layer?.masksToBounds = true
        btn.layer?.backgroundColor = (primary ? NSColor.white : NSColor(white: 1, alpha: 0.14)).cgColor
        return btn
    }

    /// 把文案里的 "→" 调淡，做出层次（变体 → 目标）
    private func dimArrows(in attr: NSMutableAttributedString, fullText: String) {
        let ns = fullText as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: "→", options: [], range: searchRange)
            if r.location == NSNotFound { break }
            attr.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.45), range: r)
            let next = r.location + r.length
            searchRange = NSRange(location: next, length: ns.length - next)
        }
    }

    @objc private func undoCancelTapped() {
        hideLearnedWindow()
        onUndoCancel?()
    }

    @objc private func undoLearnedTapped() {
        onUndoLearn?()
        hideLearnedWindow()
    }

    @objc private func acceptLearnSuggestionTapped() {
        onAcceptLearnSuggestion?()
        hideLearnedWindow()
    }

    @objc private func dismissLearnSuggestionTapped() {
        onDismissLearnSuggestion?()
        hideLearnedWindow()
    }

    private func hideLearnedWindow() {
        learnedDismissTimer?.invalidate()
        learnedDismissTimer = nil
        learnedWindow?.orderOut(nil)
        learnedWindow = nil
        learnedDisplayID = nil
    }

    private func preferredScreen() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - Siri-style capsule with gradient border + sound wave bars

class SiriCapsuleView: NSView {
    fileprivate var recordingPillFrame: NSRect? {
        guard case .recording = currentState else { return nil }
        return NSRect(x: bounds.midX - pillW / 2, y: bounds.midY - pillH / 2,
                      width: pillW, height: pillH)
    }

    /// 长按只显示声波；单击或鼠标锁定录音显示完整操作按钮。
    private var pillW: CGFloat {
        let tagExtra: CGFloat = languageTag == nil ? 0 : languageTagWidth + 6
        guard hasActionControls else { return 120 + tagExtra }
        switch recordingControls {
        case .hidden: return 72 + tagExtra
        case .cancelOnly: return 94 + tagExtra
        case .cancelAndFinish: return 116 + tagExtra
        }
    }
    private let languageTagWidth: CGFloat = 26
    private let pillH: CGFloat = 34
    private let borderWidth: CGFloat = 2.5
    private let actionButtonD = CapsuleActionButton.diameter
    private let actionButtonInset: CGFloat = 5
    private let waveSideGap: CGFloat = 3

    // Layers
    private var glowLayer: CAGradientLayer!
    private var glowMask: CAShapeLayer!
    private var darkFill: CAShapeLayer!
    private var borderGradient: CAGradientLayer!
    private var borderMask: CAShapeLayer!

    // Sound wave bars inside the capsule
    private var barCount: Int { controlsMode == .buttons ? 9 : 24 }
    private var barLayers: [CALayer] = []
    private var barClipLayer: CALayer!
    private var barHeights: [CGFloat] = []       // current animated heights
    private var barTargetHeights: [CGFloat] = []  // target heights

    // Think text + progress fill
    private var thinkTextLayer: CATextLayer!
    private var progressFillLayer: CALayer!
    private var progressStartTime: Date?
    private var cancelButton: CapsuleActionButton!
    private var finishButton: CapsuleActionButton!

    // Animation state
    private var displayTimer: Timer?
    private var time: CGFloat = 0
    private var currentLevel: Float = 0
    private var targetLevel: Float = 0
    private var currentState: OverlayState = .recording

    // Colors
    private let siriColors: [NSColor] = [
        NSColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1),   // Blue
        NSColor(red: 0.60, green: 0.30, blue: 0.95, alpha: 1),   // Purple
        NSColor(red: 0.95, green: 0.35, blue: 0.60, alpha: 1),   // Pink
        NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1),   // Orange
        NSColor(red: 0.30, green: 0.85, blue: 0.65, alpha: 1),   // Teal
        NSColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1),
    ]

    private let thinkColors: [NSColor] = [
        NSColor(red: 0.40, green: 0.35, blue: 0.95, alpha: 1),
        NSColor(red: 0.55, green: 0.25, blue: 0.90, alpha: 1),
        NSColor(red: 0.70, green: 0.30, blue: 0.95, alpha: 1),
        NSColor(red: 0.50, green: 0.40, blue: 1.00, alpha: 1),
        NSColor(red: 0.35, green: 0.50, blue: 0.95, alpha: 1),
        NSColor(red: 0.40, green: 0.35, blue: 0.95, alpha: 1),
    ]

    // Bar gradient colors (pink → purple → blue, like the reference image)
    private let barColorLeft = NSColor(red: 1.0, green: 0.25, blue: 0.50, alpha: 1)     // Hot pink
    private let barColorMid  = NSColor(red: 0.75, green: 0.20, blue: 0.90, alpha: 1)    // Purple
    private let barColorRight = NSColor(red: 0.30, green: 0.35, blue: 1.00, alpha: 1)   // Blue

    let style: OverlayStyle
    let controlsMode: OverlayControlsMode
    var onCancelRecording: (() -> Void)?
    var onFinishRecording: (() -> Void)?
    var onLockedDragStart: ((NSPoint) -> Bool)?
    var onLockedDragUpdate: ((NSPoint) -> Void)?
    var onLockedDragEnd: ((NSPoint) -> Void)?
    fileprivate var isLockedDragActive = false
    var recordingControls: RecordingControls = .cancelAndFinish
    fileprivate var recordingLocked = false
    fileprivate var hasActionControls: Bool { controlsMode == .buttons || recordingLocked }
    /// 默认输出语言标签（录音中常驻在药丸右侧）
    var languageTag: String? { didSet { if languageTag != oldValue { applyLayout(animated: false) } } }
    private var languageTagLayer: CATextLayer!
    private var languageTagBackground: CALayer!
    private var cancelArmed = false
    private var captionRestore: DispatchWorkItem?

    // 拖开取消（方案一·红晕光环）：胶囊本体不变，四周一圈红边 + 柔光；拖得越远越重，到点固定
    private var cancelRing: CAShapeLayer!
    private var cancelMark: CAShapeLayer!         // 到点时替代声波的白色叉号
    /// 提问模式的蓝色光环（与红色取消光环同款，待取消时让位给红色）
    private var askRing: CAShapeLayer!
    private var askShown: CGFloat = 0
    var askGlow = false
    private static let askBlue = NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
    private static let lockGreen = NSColor(red: 0.48, green: 0.90, blue: 0.66, alpha: 1)
    private var cancelShown: CGFloat = 0          // 红晕强度，0/1 之间快速过渡
    private static let cancelRed = NSColor(red: 1.0, green: 0.31, blue: 0.27, alpha: 1)

    init(frame: NSRect, style: OverlayStyle, controlsMode: OverlayControlsMode) {
        self.style = style
        self.controlsMode = controlsMode
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        barHeights = Array(repeating: 2, count: barCount)
        barTargetHeights = Array(repeating: 2, count: barCount)
        setupLayers()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { displayTimer?.invalidate() }   // 视图销毁时确保 60fps 定时器停掉，杜绝打到已释放图层

    /// 静息胶囊填充：墨黑样式＝近黑实心；彩色样式＝半透明深色。
    private var restFillColor: NSColor {
        style == .mono ? NSColor(white: 0.055, alpha: 0.98) : NSColor(white: 0.05, alpha: 0.62)
    }

    private func capsulePath(inset: CGFloat = 0) -> CGPath {
        let cx = bounds.midX, cy = bounds.midY
        let w = pillW - inset * 2
        let h = pillH - inset * 2
        let rect = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
        return CGPath(roundedRect: rect, cornerWidth: h/2, cornerHeight: h/2, transform: nil)
    }

    private func setupLayers() {
        let cx = bounds.midX, cy = bounds.midY

        // === 1. Outer glow ===
        glowLayer = CAGradientLayer()
        glowLayer.type = .conic
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 0.5, y: 0)
        glowLayer.frame = bounds
        glowLayer.colors = siriColors.map { $0.withAlphaComponent(0.4).cgColor }
        glowLayer.locations = [0.0, 0.17, 0.33, 0.50, 0.67, 0.83]

        glowMask = CAShapeLayer()
        glowMask.path = capsulePath(inset: -2)
        glowMask.fillColor = nil
        glowMask.strokeColor = NSColor.white.cgColor
        // 不再用 CIGaussianBlur 滤镜（实时滤镜每帧重渲染图像，是崩溃元凶之一）。
        // 改用「更宽 + 更淡」的描边来还原柔光halo：肉眼接近原来的模糊外发光，但零滤镜、稳定。
        glowMask.lineWidth = 9
        glowLayer.mask = glowMask
        glowLayer.opacity = 0.85
        glowLayer.isHidden = (style == .mono)   // 墨黑样式不要彩色外发光
        layer?.addSublayer(glowLayer)

        // === 1b. 拖开取消的红晕（放在黑色底之下：柔光只留在外圈，药丸内部保持纯黑）===
        setupCancelRing()

        // === 2. Dark fill ===
        darkFill = CAShapeLayer()
        darkFill.path = capsulePath()
        darkFill.fillColor = restFillColor.cgColor
        layer?.addSublayer(darkFill)

        // === 2b. Progress fill (left-to-right, hidden by default) ===
        let pillLeft = cx - pillW / 2
        let pillBottom = cy - pillH / 2
        progressFillLayer = CALayer()
        progressFillLayer.backgroundColor = (style == .mono
            ? NSColor(white: 1, alpha: 0.22)
            : NSColor(red: 0.50, green: 0.35, blue: 0.95, alpha: 0.55)).cgColor
        progressFillLayer.frame = CGRect(x: pillLeft, y: pillBottom, width: 0, height: pillH)
        progressFillLayer.cornerRadius = pillH / 2
        progressFillLayer.isHidden = true
        layer?.addSublayer(progressFillLayer)

        // === 2c. Think text (hidden by default) ===
        thinkTextLayer = CATextLayer()
        thinkTextLayer.string = "Thinking"
        thinkTextLayer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        thinkTextLayer.fontSize = 13
        thinkTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        thinkTextLayer.alignmentMode = .center
        thinkTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let textW: CGFloat = pillW - 16
        let textH: CGFloat = 18
        thinkTextLayer.frame = CGRect(x: cx - textW/2, y: cy - textH/2 - 1, width: textW, height: textH)
        thinkTextLayer.isHidden = true
        layer?.addSublayer(thinkTextLayer)

        // === 3. Sound wave bars (clipped to capsule) ===
        let waveFrame = soundWaveFrame(cx: cx, cy: cy)
        barClipLayer = CALayer()
        barClipLayer.frame = waveFrame
        barClipLayer.cornerRadius = pillH / 2
        barClipLayer.masksToBounds = true
        layer?.addSublayer(barClipLayer)

        let barSpacing: CGFloat = 1.5
        let barW: CGFloat = (waveFrame.width - 12) / CGFloat(barCount) - barSpacing
        let totalBarsWidth = CGFloat(barCount) * (barW + barSpacing) - barSpacing
        let startX = (waveFrame.width - totalBarsWidth) / 2

        for i in 0..<barCount {
            let bar = CALayer()
            bar.cornerRadius = barW / 2
            let x = startX + CGFloat(i) * (barW + barSpacing)
            bar.frame = CGRect(x: x, y: pillH/2 - 1, width: barW, height: 2)

            // Gradient color: pink → purple → blue across bars
            let t = CGFloat(i) / CGFloat(barCount - 1)
            let color: NSColor
            if t < 0.5 {
                color = lerpColor(barColorLeft, barColorMid, t: t * 2)
            } else {
                color = lerpColor(barColorMid, barColorRight, t: (t - 0.5) * 2)
            }
            bar.backgroundColor = (style == .mono ? NSColor.white : color).cgColor

            barClipLayer.addSublayer(bar)
            barLayers.append(bar)
        }

        // === 4. Gradient border ===
        borderGradient = CAGradientLayer()
        borderGradient.type = .conic
        borderGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        borderGradient.endPoint = CGPoint(x: 0.5, y: 0)
        borderGradient.frame = bounds
        borderGradient.colors = (style == .mono
            ? Array(repeating: NSColor(white: 1, alpha: 0.12), count: 6)
            : siriColors).map { $0.cgColor }
        borderGradient.locations = [0.0, 0.17, 0.33, 0.50, 0.67, 0.83]

        borderMask = CAShapeLayer()
        borderMask.path = capsulePath()
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.white.cgColor
        borderMask.lineWidth = style == .mono ? 1 : borderWidth
        borderGradient.mask = borderMask

        layer?.addSublayer(borderGradient)
        layer?.addSublayer(languageTagBackground)
        layer?.addSublayer(languageTagLayer)
        layer?.addSublayer(cancelMark)   // 叉号在最上层

        // 经典样式也预备按钮，只有锁定录音时才显示。
        cancelButton = CapsuleActionButton(role: .cancel, style: style, target: self, action: #selector(cancelTapped))
        cancelButton.toolTip = "取消本次錄音"
        cancelButton.frame = actionButtonFrame(side: .left, cx: cx, cy: cy)
        cancelButton.isHidden = true
        addSubview(cancelButton)

        finishButton = CapsuleActionButton(role: .finish, style: style, target: self, action: #selector(finishTapped))
        finishButton.toolTip = "完成並轉寫"
        finishButton.frame = actionButtonFrame(side: .right, cx: cx, cy: cy)
        finishButton.isHidden = true
        addSubview(finishButton)
        applyLayout(animated: false)
    }

    func update(state: OverlayState) {
        currentState = state
        switch state {
        case .recording:
            cancelArmed = false
            captionRestore?.cancel()
            captionRestore = nil
            thinkTextLayer.string = "Thinking"
            resetCancelRing()
            applyLayout(animated: false)
            cancelMark.opacity = 0
            setActionControlsVisible(true)
            showBars(true)
            showThinkMode(false)
            if style == .colorful { setColors(siriColors, glowAlpha: 0.4) }
            else { resetMonoDecor() }
            startAnimation()
        case .processing(let message):
            askGlow = false
            resetCancelRing()
            setActionControlsVisible(false)
            showBars(false)
            thinkTextLayer.string = message.hasPrefix("→") ? message : "Thinking"
            languageTagBackground?.isHidden = true
            languageTagLayer?.isHidden = true
            if progressStartTime == nil {
                showThinkMode(true)
            }
            if style == .colorful { setColors(thinkColors, glowAlpha: 0.35) }
            startAnimation()
        case .done:
            askGlow = false
            resetCancelRing()
            setActionControlsVisible(false)
            showBars(false)
            showThinkMode(false)
            showFinish(color: NSColor(red: 0.15, green: 0.85, blue: 0.5, alpha: 1))
        case .error:
            askGlow = false
            resetCancelRing()
            setActionControlsVisible(false)
            showBars(false)
            showThinkMode(false)
            showFinish(color: NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1))
        case .learned, .learnSuggestion:
            // Handled by OverlayWindow's separate interactive window, not by SiriCapsuleView
            break
        }
    }

    func updateAudioLevel(_ level: Float) {
        targetLevel = min(max(level, 0), 1)
    }

    func enterThinkMode() {
        setActionControlsVisible(false)
        showBars(false)
        showThinkMode(true)
    }

    func shouldHandleMouse(at point: NSPoint) -> Bool {
        // 按住胶囊拖出窗口后仍接收拖动/松手事件；否则透明穿透定时器会中断拖拽。
        if isLockedDragActive { return true }
        if recordingLocked, let frame = recordingPillFrame,
           NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).contains(point) {
            return true
        }
        guard hasActionControls,
              case .recording = currentState,
              let cancelButton = cancelButton,
              let finishButton = finishButton,
              !cancelButton.isHidden || !finishButton.isHidden else {
            return false
        }

        let hitSlop: CGFloat = 4
        return (!cancelButton.isHidden && cancelButton.frame.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point))
            || (!finishButton.isHidden && finishButton.frame.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard recordingLocked, let window, let frame = recordingPillFrame,
              NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).contains(point),
              ![cancelButton, finishButton].contains(where: { button in
                  button?.isHidden == false && button!.frame.contains(point)
              }),
              onLockedDragStart?(window.convertPoint(toScreen: event.locationInWindow)) == true else {
            super.mouseDown(with: event)
            return
        }
        isLockedDragActive = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isLockedDragActive, let window else { super.mouseDragged(with: event); return }
        onLockedDragUpdate?(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard isLockedDragActive, let window else { super.mouseUp(with: event); return }
        isLockedDragActive = false
        onLockedDragEnd?(window.convertPoint(toScreen: event.locationInWindow))
    }

    func animateAppear() {
        guard let layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()

        layer.removeAnimation(forKey: "appearScale")
        layer.removeAnimation(forKey: "appearOpacity")
        layer.transform = CATransform3DIdentity
        layer.opacity = 1

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.94, 1.015, 1.0]
        scale.keyTimes = [0, 0.72, 1]
        scale.duration = 0.18
        scale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut)
        ]

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.08
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.add(scale, forKey: "appearScale")
        layer.add(opacity, forKey: "appearOpacity")
    }

    func completeProgressOnly(duration: CFTimeInterval = 0.18, completion: (() -> Void)? = nil) {
        stopAnimations()

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock(completion)

        showBars(false)
        thinkTextLayer.isHidden = true
        progressFillLayer.isHidden = false
        progressFillLayer.backgroundColor = (style == .mono
            ? NSColor.white.withAlphaComponent(0.16)
            : thinkColors.first!.withAlphaComponent(0.28)).cgColor

        let pillLeft = bounds.midX - pillW / 2
        let pillBottom = bounds.midY - pillH / 2
        progressFillLayer.frame = CGRect(x: pillLeft, y: pillBottom, width: pillW, height: pillH)
        progressStartTime = nil

        CATransaction.commit()
    }

    func stopAnimations() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func showBars(_ show: Bool) {
        for bar in barLayers { bar.isHidden = !show }
    }

    private func setActionControlsVisible(_ visible: Bool, animated: Bool = false) {
        let showCancel = visible && hasActionControls && recordingControls != .hidden
        let showFinish = visible && hasActionControls && recordingControls == .cancelAndFinish
        // 新按钮随胶囊两端展开，不单独闪现或做透明度动画。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (button, show) in [(cancelButton, showCancel), (finishButton, showFinish)] {
            guard let button else { continue }
            let reveal = animated && show && button.isHidden
            button.isHidden = !show
            button.layer?.mask = nil
            if reveal, let layer = button.layer {
                let mask = CAShapeLayer()
                let full = button.bounds
                let collapsed = CGRect(x: button === cancelButton ? full.maxX : full.minX,
                                       y: full.minY, width: 0, height: full.height)
                mask.path = CGPath(rect: full, transform: nil)
                layer.mask = mask
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = CGPath(rect: collapsed, transform: nil)
                animation.toValue = mask.path
                animation.duration = 0.22
                animation.beginTime = mask.convertTime(CACurrentMediaTime(), from: nil)
                animation.fillMode = .backwards
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak button, weak mask] in
                    guard let mask, button?.layer?.mask === mask else { return }
                    button?.layer?.mask = nil
                }
                mask.add(animation, forKey: "controlsReveal")
                CATransaction.commit()
            }
        }
        CATransaction.commit()
    }

    func setRecordingControls(_ controls: RecordingControls) {
        guard controls != recordingControls else { return }
        recordingControls = controls
        applyLayout(animated: true)
        if case .recording = currentState { setActionControlsVisible(true, animated: true) }
    }

    /// 拖开取消：只有两个状态。到点 = 红边 + 柔光 + 白色叉号，约 0.12s 干脆出现；解除 = 同样干脆退回。
    func setCancelArmed(_ armed: Bool) {
        guard armed != cancelArmed else { return }
        cancelArmed = armed
        if armed, !thinkTextLayer.isHidden {
            captionRestore?.cancel()
            captionRestore = nil
            thinkTextLayer.isHidden = true
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        showBars(!armed)
        cancelMark.opacity = armed ? 1 : 0
        cancelMark.transform = armed ? CATransform3DIdentity : CATransform3DMakeScale(0.6, 0.6, 1)
        CATransaction.commit()
    }

    func endCancelGesture() {
        setCancelArmed(false)
    }

    func showTransientCaption(_ text: String, seconds: TimeInterval) {
        guard case .recording = currentState, !cancelArmed else { return }
        captionRestore?.cancel()
        showBars(false)
        thinkTextLayer.string = text
        thinkTextLayer.opacity = 1
        thinkTextLayer.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelArmed, case .recording = self.currentState else { return }
            self.thinkTextLayer.isHidden = true
            self.thinkTextLayer.string = "Thinking"
            self.showBars(true)
        }
        captionRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func cancelTapped() {
        setActionControlsVisible(false)
        onCancelRecording?()
    }

    @objc private func finishTapped() {
        setActionControlsVisible(false)
        onFinishRecording?()
    }

    private func showThinkMode(_ show: Bool) {
        thinkTextLayer.isHidden = !show
        progressFillLayer.isHidden = !show
        if show {
            progressStartTime = Date()
            let pillLeft = bounds.midX - pillW / 2
            let pillBottom = bounds.midY - pillH / 2
            progressFillLayer.frame = CGRect(x: pillLeft, y: pillBottom, width: 0, height: pillH)
        } else {
            progressStartTime = nil
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        stopAnimations()
        // 挂到 common 模式：在自家面板上按住鼠标续聊时主线程处于鼠标追踪模式，默认模式的定时器不走，胶囊会冻住
        let timer = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        // Fast attack, slow decay for punchy response
        if targetLevel > currentLevel {
            currentLevel += (targetLevel - currentLevel) * 0.4  // fast rise
        } else {
            currentLevel += (targetLevel - currentLevel) * 0.08 // slow fall
        }
        targetLevel *= 0.92

        let isRec: Bool
        switch currentState {
        case .recording: isRec = true
        default: isRec = false
        }

        let speed: CGFloat = isRec ? 1.2 : 0.5
        time += 0.016 * speed

        // Boost energy so even moderate audio produces visible bars
        let energy = isRec ? max(CGFloat(currentLevel), 0.15) : (0.2 + 0.15 * sin(time * 1.5))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let cx = bounds.midX, cy = bounds.midY

        // 彩色样式才旋转渐变边框 / 外发光 / 缩放脉冲；墨黑样式保持静态。
        if style == .colorful {
            // --- Rotate gradient border ---
            let shift = time.truncatingRemainder(dividingBy: 1.0)
            let colors = isRec ? siriColors : thinkColors
            let shifted = shiftColors(colors, by: shift)
            borderGradient.colors = shifted.map { $0.cgColor }

            let glowAlpha: CGFloat = 0.15 + energy * 0.45
            glowLayer.colors = shifted.map { $0.withAlphaComponent(glowAlpha).cgColor }

            // Subtle scale pulse
            let scale: CGFloat = 1.0 + energy * 0.04
            var transform = CATransform3DIdentity
            transform = CATransform3DTranslate(transform, cx, cy, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -cx, -cy, 0)
            borderGradient.transform = transform
            glowLayer.transform = transform

            glowMask.lineWidth = 8 + energy * 5
        }

        // --- Animate progress fill (thinking mode) ---
        if !isRec, let startTime = progressStartTime {
            let elapsed = CGFloat(Date().timeIntervalSince(startTime))
            // Psychological progress: jump forward quickly, then keep moving with a gentle slowdown.
            // Completion snaps to 100% in showFinish().
            let progress = min(0.97 * (1.0 - exp(-elapsed / 0.85)), 0.97)
            let fillWidth = pillW * progress
            let pillLeft = cx - pillW / 2
            let pillBottom = cy - pillH / 2
            progressFillLayer.frame = CGRect(x: pillLeft, y: pillBottom, width: fillWidth, height: pillH)

            // Subtle text pulse
            thinkTextLayer.opacity = Float(0.7 + 0.3 * sin(time * 3.0))
        }

        if isRec { tickCancelRing() }

        // --- Animate sound wave bars ---
        if isRec {
            updateBarHeights(energy: energy, isRecording: isRec)

            let maxBarH = pillH - 4  // max bar height, nearly full capsule
            for i in 0..<barCount {
                // Smooth interpolation toward target
                barHeights[i] += (barTargetHeights[i] - barHeights[i]) * 0.4

                let h = max(barHeights[i], 2)  // minimum 2pt dot
                let barW = barLayers[i].bounds.width
                let x = barLayers[i].frame.origin.x
                barLayers[i].frame = CGRect(x: x, y: pillH/2 - h/2, width: barW, height: h)
                barLayers[i].cornerRadius = barW / 2

                // Bar opacity: brighter when taller.
                // 墨黑·白波：抬高短音波的透明度下限，让白色更白、少发灰；彩色 Siri 维持原值。
                let floor: CGFloat = style == .mono ? 0.8 : 0.5
                let brightness: CGFloat = floor + (1 - floor) * (h / maxBarH)
                barLayers[i].opacity = Float(brightness)
            }
        }

        CATransaction.commit()
    }

    private func updateBarHeights(energy: CGFloat, isRecording: Bool) {
        let maxH = pillH - 6

        if isRecording {
            // Recording: bars respond to audio level with wave-like motion
            for i in 0..<barCount {
                let pos = CGFloat(i) / CGFloat(barCount - 1)
                // Center bars taller, edge bars shorter (bell curve)
                let bell = exp(-pow((pos - 0.5) * 2.0, 2))
                // Sine wave creates movement across bars
                let wave1 = sin(time * 4.0 + CGFloat(i) * 0.4) * 0.3
                let wave2 = sin(time * 6.5 + CGFloat(i) * 0.7) * 0.2
                let wave3 = sin(time * 3.0 + CGFloat(i) * 0.2) * 0.15

                // Quiet: tiny dots (3pt). Loud: nearly full height
                let waveSum = 0.6 + wave1 + wave2 + wave3
                let baseH: CGFloat = 3 + pow(energy, 0.7) * maxH * bell * waveSum
                let jitter = CGFloat.random(in: -1.5...1.5) * energy * 4
                barTargetHeights[i] = max(3, min(maxH, baseH + jitter))
            }
        } else {
            // Processing/thinking: gentle wave pattern, slower
            for i in 0..<barCount {
                let pos = CGFloat(i) / CGFloat(barCount - 1)
                let wave = sin(time * 2.0 + CGFloat(i) * 0.5) * 0.5 + 0.5
                let bell = exp(-pow((pos - 0.5) * 2.5, 2))
                let h = 2 + maxH * 0.3 * wave * bell
                barTargetHeights[i] = h
            }
        }
    }

    // MARK: - Helpers

    private func shiftColors(_ colors: [NSColor], by amount: CGFloat) -> [NSColor] {
        let count = colors.count
        guard count > 0 else { return colors }
        var result: [NSColor] = []
        for i in 0..<count {
            let srcIdx = CGFloat(i) / CGFloat(count) + amount
            let wrapped = srcIdx.truncatingRemainder(dividingBy: 1.0)
            let pos = wrapped * CGFloat(count - 1)
            let low = Int(pos) % count
            let high = (low + 1) % count
            let frac = pos - CGFloat(Int(pos))
            result.append(lerpColor(colors[low], colors[high], t: frac))
        }
        return result
    }

    private func setColors(_ colors: [NSColor], glowAlpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderGradient.colors = colors.map { $0.cgColor }
        glowLayer.colors = colors.map { $0.withAlphaComponent(glowAlpha).cgColor }
        CATransaction.commit()
    }

    private enum ActionButtonSide { case left, right }

    private func actionButtonFrame(side: ActionButtonSide, cx: CGFloat, cy: CGFloat) -> CGRect {
        let pillLeft = cx - pillW / 2
        let pillRight = cx + pillW / 2
        let x: CGFloat
        switch side {
        case .left:
            x = pillLeft + actionButtonInset
        case .right:
            x = pillRight - actionButtonInset - actionButtonD
        }
        return CGRect(x: x, y: cy - actionButtonD / 2, width: actionButtonD, height: actionButtonD)
    }

    private func soundWaveFrame(cx: CGFloat, cy: CGFloat) -> CGRect {
        guard hasActionControls else {
            return CGRect(x: cx - pillW / 2, y: cy - pillH / 2, width: pillW, height: pillH)
        }
        let pillLeft = cx - pillW / 2, pillRight = cx + pillW / 2
        let tagExtra: CGFloat = languageTag == nil ? 0 : languageTagWidth + 6
        let left: CGFloat, right: CGFloat
        switch recordingControls {
        case .hidden:
            left = pillLeft + 10; right = pillRight - 10 - tagExtra
        case .cancelOnly:
            left = pillLeft + actionButtonInset + actionButtonD + waveSideGap; right = pillRight - 9 - tagExtra
        case .cancelAndFinish:
            left = pillLeft + actionButtonInset + actionButtonD + waveSideGap
            right = pillRight - actionButtonInset - actionButtonD - waveSideGap - tagExtra
        }
        return CGRect(x: left, y: cy - pillH / 2, width: right - left, height: pillH)
    }

    /// 墨黑样式不会逐帧重画边框，进入录音前手动把上一轮 showFinish（成功绿 / 失败红）
    /// 染上的边框与填充复位成静息态，否则红/绿框会残留到下一次浮窗。
    private func resetMonoDecor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderGradient.colors = Array(repeating: NSColor(white: 1, alpha: 0.12).cgColor, count: 6)
        darkFill.fillColor = restFillColor.cgColor
        CATransaction.commit()
    }

    private func showFinish(color: NSColor) {
        stopAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let solidColors = Array(repeating: color.cgColor, count: 6)
        borderGradient.colors = solidColors
        glowLayer.colors = Array(repeating: color.withAlphaComponent(0.5).cgColor, count: 6)
        glowMask.lineWidth = 7
        darkFill.fillColor = color.withAlphaComponent(0.15).cgColor

        borderGradient.transform = CATransform3DIdentity
        glowLayer.transform = CATransform3DIdentity

        // Flash-fill the progress bar to 100% on completion
        if progressStartTime != nil {
            let pillLeft = bounds.midX - pillW / 2
            let pillBottom = bounds.midY - pillH / 2
            progressFillLayer.frame = CGRect(x: pillLeft, y: pillBottom, width: pillW, height: pillH)
            progressFillLayer.backgroundColor = color.withAlphaComponent(0.3).cgColor
        }

        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.darkFill.fillColor = self.restFillColor.cgColor
            self.progressFillLayer.isHidden = true
            self.thinkTextLayer.isHidden = true
            self.progressStartTime = nil
        }
    }

    private func lerpColor(_ a: NSColor, _ b: NSColor, t: CGFloat) -> NSColor {
        let ac = a.usingColorSpace(.sRGB) ?? a
        let bc = b.usingColorSpace(.sRGB) ?? b
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        ac.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        bc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = min(max(t, 0), 1)
        return NSColor(red: ar+(br-ar)*f, green: ag+(bg-ag)*f,
                       blue: ab+(bb-ab)*f, alpha: aa+(ba-aa)*f)
    }
}

private final class CapsuleActionButton: NSButton {
    static let diameter: CGFloat = 24

    enum Role {
        case cancel
        case finish
    }

    private let role: Role
    private let style: OverlayStyle
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    init(role: Role, style: OverlayStyle, target: AnyObject?, action: Selector?) {
        self.role = role
        self.style = style
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.masksToBounds = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown

        let symbolName = role == .cancel ? "xmark" : "checkmark"
        if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            symbolImage.isTemplate = true
            image = symbolImage
        } else {
            imagePosition = .noImage
            title = role == .cancel ? "X" : "✓"
        }
        updateAppearance(isHovering: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var frame: NSRect {
        didSet {
            layer?.cornerRadius = min(frame.width, frame.height) / 2
        }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance(isHovering: hovering || isMouseInside) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateAppearance(isHovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateAppearance(isHovering: false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private var isMouseInside: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    private func updateAppearance(isHovering: Bool) {
        let pressed = isHighlighted
        let background: NSColor
        let tint: NSColor
        switch role {
        case .cancel:
            let alpha: CGFloat = pressed ? 0.20 : (isHovering ? 0.16 : 0.11)
            background = NSColor(white: 1.0, alpha: alpha)
            tint = NSColor.white.withAlphaComponent(0.86)
        case .finish:
            if style == .mono {
                background = pressed
                    ? NSColor(white: 0.86, alpha: 1.0)
                    : (isHovering ? NSColor(white: 1.0, alpha: 1.0) : NSColor(white: 0.94, alpha: 1.0))
                tint = NSColor(white: 0.08, alpha: 0.96)
            } else {
                let alpha: CGFloat = pressed ? 0.24 : (isHovering ? 0.18 : 0.13)
                background = NSColor(red: 0.42, green: 0.95, blue: 0.82, alpha: alpha)
                tint = NSColor.white.withAlphaComponent(0.94)
            }
        }

        contentTintColor = tint
        if image == nil {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: tint,
            ])
        }

        let lift: CGFloat = pressed ? 0 : (isHovering ? 1.2 : 0)
        let transform = CATransform3DMakeTranslation(0, lift, 0)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(isHovering ? 0.24 : 0.12).cgColor
        layer?.borderWidth = 0.7
        layer?.transform = transform
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(isHovering && !pressed ? 0.10 : 0)
        layer?.shadowRadius = isHovering && !pressed ? 2.5 : 0
        layer?.shadowOffset = .zero
        CATransaction.commit()
    }
}


// MARK: - 布局（药丸宽度随模式变化）与「拖开取消」红晕

extension SiriCapsuleView {
    /// 按当前 pillW 重新摆放所有图层；animated=true 时药丸宽度变化带 0.22s 过渡（键盘单击锁定后长出对勾）
    fileprivate func applyLayout(animated: Bool) {
        let cx = bounds.midX, cy = bounds.midY
        let animationTime = CACurrentMediaTime()
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        // CAShapeLayer.path 不会自动做隐式动画，需要明确指定起点和终点。
        for (shape, inset, hasShadow) in [(glowMask, CGFloat(-2), false),
                                         (darkFill, CGFloat(0), false),
                                         (borderMask, CGFloat(0), false),
                                         (cancelRing, CGFloat(-1.25), true),
                                         (askRing, CGFloat(-1.25), true)] {
            guard let shape else { continue }
            let from = shape.presentation()?.path ?? shape.path
            let path = capsulePath(inset: inset)
            shape.path = path
            if hasShadow { shape.shadowPath = path }
            for key in hasShadow ? ["path", "shadowPath"] : ["path"] {
                let animationKey = "capsuleLayout.\(key)"
                if animated, let from {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = from
                    animation.toValue = path
                    animation.duration = 0.22
                    animation.beginTime = shape.convertTime(animationTime, from: nil)
                    animation.fillMode = .backwards
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    shape.add(animation, forKey: animationKey)
                } else {
                    shape.removeAnimation(forKey: animationKey)
                }
            }
        }
        cancelMark?.position = CGPoint(x: cx, y: cy)

        let pillLeft = cx - pillW / 2
        let pillBottom = cy - pillH / 2
        progressFillLayer.frame = CGRect(x: pillLeft, y: pillBottom, width: progressFillLayer.frame.width, height: pillH)
        let textW: CGFloat = max(pillW - 16, 56)
        thinkTextLayer.frame = CGRect(x: cx - textW / 2, y: cy - 9 - 1, width: textW, height: 18)

        let waveFrame = soundWaveFrame(cx: cx, cy: cy)
        barClipLayer.frame = waveFrame
        let barSpacing: CGFloat = 1.5
        let barW: CGFloat = max(2, (waveFrame.width - 12) / CGFloat(barCount) - barSpacing)
        let totalBarsWidth = CGFloat(barCount) * (barW + barSpacing) - barSpacing
        let startX = (waveFrame.width - totalBarsWidth) / 2
        for (i, bar) in barLayers.enumerated() {
            let x = startX + CGFloat(i) * (barW + barSpacing)
            bar.frame = CGRect(x: x, y: bar.frame.origin.y, width: barW, height: bar.frame.height)
            bar.cornerRadius = barW / 2
        }
        cancelButton?.frame = actionButtonFrame(side: .left, cx: cx, cy: cy)
        finishButton?.frame = actionButtonFrame(side: .right, cx: cx, cy: cy)
        if let tag = languageTag, let bg = languageTagBackground, let text = languageTagLayer {
            let rightInset: CGFloat = recordingControls == .cancelAndFinish ? actionButtonInset + actionButtonD + waveSideGap : 8
            let x = cx + pillW / 2 - rightInset - languageTagWidth
            bg.frame = CGRect(x: x, y: cy - 7, width: languageTagWidth, height: 14)
            text.frame = CGRect(x: x, y: cy - 6, width: languageTagWidth, height: 12)
            text.string = tag
            bg.isHidden = false
            text.isHidden = false
        } else {
            languageTagBackground?.isHidden = true
            languageTagLayer?.isHidden = true
        }
        CATransaction.commit()
    }

    fileprivate func setupCancelRing() {
        cancelRing = CAShapeLayer()
        cancelRing.fillColor = nil
        cancelRing.strokeColor = Self.cancelRed.withAlphaComponent(0).cgColor
        cancelRing.lineWidth = 1.5
        cancelRing.shadowColor = Self.cancelRed.cgColor
        cancelRing.shadowOffset = .zero
        cancelRing.shadowRadius = 9
        cancelRing.shadowOpacity = 0
        cancelRing.path = capsulePath(inset: -1.25)
        cancelRing.shadowPath = capsulePath(inset: -1.25)
        askRing = CAShapeLayer()
        askRing.fillColor = nil
        askRing.strokeColor = Self.askBlue.withAlphaComponent(0).cgColor
        askRing.lineWidth = 1.5
        askRing.shadowColor = Self.askBlue.cgColor
        askRing.shadowOffset = .zero
        askRing.shadowRadius = 9
        askRing.shadowOpacity = 0
        askRing.path = capsulePath(inset: -1.25)
        askRing.shadowPath = capsulePath(inset: -1.25)
        layer?.addSublayer(askRing)
        layer?.addSublayer(cancelRing)

        cancelMark = CAShapeLayer()
        let l: CGFloat = 5
        let xp = CGMutablePath()
        xp.move(to: CGPoint(x: -l, y: -l)); xp.addLine(to: CGPoint(x: l, y: l))
        xp.move(to: CGPoint(x: -l, y: l)); xp.addLine(to: CGPoint(x: l, y: -l))
        cancelMark.path = xp
        cancelMark.bounds = CGRect(x: -8, y: -8, width: 16, height: 16)
        cancelMark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        cancelMark.strokeColor = NSColor.white.cgColor
        cancelMark.fillColor = nil
        cancelMark.lineWidth = 2.2
        cancelMark.lineCap = .round
        cancelMark.opacity = 0
        cancelMark.transform = CATransform3DMakeScale(0.6, 0.6, 1)

        languageTagBackground = CALayer()
        languageTagBackground.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        languageTagBackground.cornerRadius = 7
        languageTagBackground.isHidden = true
        languageTagLayer = CATextLayer()
        languageTagLayer.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        languageTagLayer.fontSize = 9.5
        languageTagLayer.foregroundColor = NSColor.white.cgColor
        languageTagLayer.alignmentMode = .center
        languageTagLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        languageTagLayer.isHidden = true
    }

    fileprivate func resetCancelRing() {
        recordingLocked = false
        isLockedDragActive = false
        cancelShown = 0
        cancelArmed = false
        askShown = 0
        askRing.strokeColor = Self.askBlue.withAlphaComponent(0).cgColor
        askRing.shadowOpacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cancelRing.strokeColor = Self.cancelRed.withAlphaComponent(0).cgColor
        cancelRing.shadowOpacity = 0
        CATransaction.commit()
    }

    /// 每帧：红晕在 0/1 之间约 0.12s 完成过渡（干脆，不拖泥带水）；到点后柔光缓慢呼吸
    fileprivate func tickCancelRing() {
        // 锁定优先显示淡绿色；普通提问显示蓝色；待取消时让位给红色。
        let ringColor = recordingLocked ? Self.lockGreen : Self.askBlue
        let askTarget: CGFloat = ((askGlow || recordingLocked) && !cancelArmed) ? 1 : 0
        askShown += (askTarget - askShown) * 0.25
        if abs(askTarget - askShown) < 0.01 { askShown = askTarget }
        if askShown > 0.001 || askRing.shadowOpacity > 0 {
            let breathe: CGFloat = 0.06 * sin(CGFloat(CACurrentMediaTime()) * 2.4)
            askRing.strokeColor = ringColor.withAlphaComponent((recordingLocked ? 0.65 : 0.85) * askShown).cgColor
            askRing.shadowColor = ringColor.cgColor
            askRing.shadowOpacity = Float(max(0, ((recordingLocked ? 0.38 : 0.5) + breathe) * askShown))
        }
        let target: CGFloat = cancelArmed ? 1 : 0
        cancelShown += (target - cancelShown) * 0.4
        if abs(target - cancelShown) < 0.01 { cancelShown = target }
        let p = cancelShown
        guard p > 0.001 || cancelRing.shadowOpacity > 0 else { return }
        let breathe: CGFloat = cancelArmed ? 0.07 * sin(CGFloat(CACurrentMediaTime()) * 3.6) : 0
        cancelRing.strokeColor = Self.cancelRed.withAlphaComponent(0.92 * p).cgColor
        cancelRing.shadowOpacity = Float(max(0, 0.6 * p + breathe * p))
    }
}
