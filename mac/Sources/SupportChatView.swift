import Cocoa
import UniformTypeIdentifiers
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 设置窗「反馈」页：像聊天一样和开发者来回。上半是消息（自己的在右、开发者的在左），下半是输入区：
/// 文字 + 截图（拖进来 / 粘贴 / 选文件）+ 可选附上最后一次转录和录音。发送时自动带上系统版本、
/// App 版本、最近使用的软件和最近的日志，方便定位「某个软件里不好用」这类问题。
final class SupportChatView: NSView, NSTextViewDelegate {
    /// 复用 App 的调试日志（粘贴 / 拖入 / 发送的诊断）
    static var log: ((String) -> Void)?

    struct Context {
        var latestTranscript: () -> (asr: String, output: String, audio: Data?)?
        var recentApp: () -> String?
        var logTail: () -> String
        var openSetupHint: (() -> Void)?
    }

    private let theme: VPTheme
    private let context: Context
    private let service = SupportChatService.shared

    private let messagesScroll = NSScrollView()
    private let messagesDoc = SupportFlippedView()
    private let messagesStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private let composerCard = NSView()
    private let textView = SupportTextView()
    private let placeholder = NSTextField(labelWithString: "有問題、建議，或者哪個軟體裡不好用，直接在這裡說…")
    private let attachmentRow = NSStackView()
    private var imageThumb: NSImageView?
    private var pendingImage: Data?             // 已轉成 JPEG 的截圖
    private var transcriptAttached = false     // 預設不帶；使用者點「附上最後的轉錄」才帶
    private var attachTranscriptButton: VPButton!
    private let transcriptChip = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var sendButton: VPButton!
    private var observer: NSObjectProtocol?

    init(theme: VPTheme, context: Context) {
        self.theme = theme
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL, .png, .tiff])
        build()
        reload()
        observer = NotificationCenter.default.addObserver(forName: SupportChatService.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        service.sync()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: - 佈局

    private func build() {
        // 訊息區
        messagesScroll.translatesAutoresizingMaskIntoConstraints = false
        messagesScroll.hasVerticalScroller = true
        messagesScroll.autohidesScrollers = true
        messagesScroll.drawsBackground = false
        messagesScroll.scrollerStyle = .overlay
        messagesDoc.translatesAutoresizingMaskIntoConstraints = false
        messagesStack.orientation = .vertical
        messagesStack.alignment = .leading
        messagesStack.spacing = 12
        messagesStack.translatesAutoresizingMaskIntoConstraints = false
        messagesDoc.addSubview(messagesStack)
        messagesScroll.documentView = messagesDoc
        addSubview(messagesScroll)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = theme.text3
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.stringValue = "還沒有訊息。有問題、建議，或者哪個軟體裡用著不順，直接在下面說。\n開發者的回覆會出現在這裡。"
        addSubview(emptyLabel)

        // 输入区
        composerCard.wantsLayer = true
        composerCard.layer?.cornerRadius = 12
        composerCard.layer?.borderWidth = 1
        composerCard.layer?.setAppearanceBorder(theme.sep)
        composerCard.layer?.setAppearanceBackground(theme.card)
        composerCard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composerCard)

        let inputWrap = NSView()
        inputWrap.wantsLayer = true
        inputWrap.layer?.cornerRadius = 8
        inputWrap.layer?.masksToBounds = true
        inputWrap.layer?.borderWidth = 1
        inputWrap.layer?.setAppearanceBorder(theme.sep)
        inputWrap.translatesAutoresizingMaskIntoConstraints = false
        let inputScroll = NSScrollView()
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.borderType = .noBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = theme.text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.onPasteImage = { [weak self] image in self?.attach(image: image) }
        inputScroll.documentView = textView
        inputWrap.addSubview(inputScroll)
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = theme.text3
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        inputWrap.addSubview(placeholder)
        NSLayoutConstraint.activate([
            inputScroll.leadingAnchor.constraint(equalTo: inputWrap.leadingAnchor, constant: 1),
            inputScroll.trailingAnchor.constraint(equalTo: inputWrap.trailingAnchor, constant: -1),
            inputScroll.topAnchor.constraint(equalTo: inputWrap.topAnchor, constant: 1),
            inputScroll.bottomAnchor.constraint(equalTo: inputWrap.bottomAnchor, constant: -1),
            placeholder.leadingAnchor.constraint(equalTo: inputWrap.leadingAnchor, constant: 12),
            placeholder.topAnchor.constraint(equalTo: inputWrap.topAnchor, constant: 9),
        ])

        attachmentRow.orientation = .horizontal
        attachmentRow.alignment = .centerY
        attachmentRow.spacing = 8
        attachmentRow.translatesAutoresizingMaskIntoConstraints = false

        let addImage = VPButton(title: "新增截圖", style: .secondary, size: .small, theme: theme,
                                target: self, action: #selector(chooseImage))
        attachTranscriptButton = VPButton(title: "附上最後的轉錄", style: .secondary, size: .small, theme: theme,
                                          target: self, action: #selector(attachTranscript))
        attachTranscriptButton.toolTip = "把最近一次辨識的文字和錄音一起發給開發者，方便排查辨識問題"
        let hint = NSTextField(wrappingLabelWithString: "也可以把截圖拖進來或直接貼上。")
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = theme.text3
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = theme.text3
        statusLabel.isHidden = true
        sendButton = VPButton(title: "發送", style: .primary, size: .regular, theme: theme,
                              target: self, action: #selector(sendTapped))
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 12
        bottomRow.addArrangedSubview(addImage)
        bottomRow.addArrangedSubview(attachTranscriptButton)
        bottomRow.addArrangedSubview(hint)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)   // 把「发送」顶到最右
        bottomRow.addArrangedSubview(spacer)
        bottomRow.addArrangedSubview(statusLabel)
        bottomRow.addArrangedSubview(sendButton)

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        form.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        form.addArrangedSubview(attachmentRow)
        form.addArrangedSubview(inputWrap)
        form.addArrangedSubview(bottomRow)
        composerCard.addSubview(form)

        NSLayoutConstraint.activate([
            messagesScroll.topAnchor.constraint(equalTo: topAnchor),
            messagesScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            messagesScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            messagesScroll.bottomAnchor.constraint(equalTo: composerCard.topAnchor, constant: -16),
            messagesDoc.leadingAnchor.constraint(equalTo: messagesScroll.contentView.leadingAnchor),
            messagesDoc.trailingAnchor.constraint(equalTo: messagesScroll.contentView.trailingAnchor),
            messagesDoc.topAnchor.constraint(equalTo: messagesScroll.contentView.topAnchor),
            messagesDoc.widthAnchor.constraint(equalTo: messagesScroll.contentView.widthAnchor),
            messagesStack.leadingAnchor.constraint(equalTo: messagesDoc.leadingAnchor),
            messagesStack.trailingAnchor.constraint(equalTo: messagesDoc.trailingAnchor),
            messagesStack.topAnchor.constraint(equalTo: messagesDoc.topAnchor, constant: 4),
            messagesStack.bottomAnchor.constraint(equalTo: messagesDoc.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: messagesScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: messagesScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            composerCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerCard.bottomAnchor.constraint(equalTo: bottomAnchor),
            form.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor),
            form.topAnchor.constraint(equalTo: composerCard.topAnchor),
            form.bottomAnchor.constraint(equalTo: composerCard.bottomAnchor),
            attachmentRow.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
            inputWrap.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
            inputWrap.heightAnchor.constraint(equalToConstant: 84),
            bottomRow.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
        ])
        refreshAttachments()
    }

    // MARK: - 消息列表

    func reload() {
        let messages = service.messages
        messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !messages.isEmpty
        for m in messages {
            let row = makeBubbleRow(m)
            messagesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: messagesStack.widthAnchor).isActive = true
        }
        layoutSubtreeIfNeeded()
        scrollToBottom()
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [self] in
            let h = messagesDoc.fittingSize.height
            messagesScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, h - messagesScroll.contentView.bounds.height)))
            messagesScroll.reflectScrolledClipView(messagesScroll.contentView)
        }
    }

    private func makeBubbleRow(_ m: SupportMessage) -> NSView {
        let mine = m.role == .user
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.translatesAutoresizingMaskIntoConstraints = false
        if mine {
            bubble.layer?.setAppearanceBackground(theme.accent)
        } else {
            bubble.layer?.setAppearanceBackground(theme.card)
            bubble.layer?.borderWidth = 1
            bubble.layer?.setAppearanceBorder(theme.sep)
        }

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)

        if !m.text.isEmpty {
            let t = NSTextField(wrappingLabelWithString: m.text)
            t.font = .systemFont(ofSize: 13.5)
            t.textColor = mine ? theme.onAccent : theme.text
            t.isSelectable = true
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            content.addArrangedSubview(t)
            t.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -26).isActive = true
        }
        if m.hasImage {
            if let url = service.imageURL(for: m), let image = NSImage(contentsOf: url) {
                let iv = SupportClickableImage(image: image, url: url)
                content.addArrangedSubview(iv)
                let ratio = max(image.size.width, 1) / max(image.size.height, 1)
                let w = min(320, max(120, image.size.width))
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(lessThanOrEqualToConstant: w),
                    iv.widthAnchor.constraint(equalTo: iv.heightAnchor, multiplier: ratio),
                    iv.heightAnchor.constraint(lessThanOrEqualToConstant: 240),
                ])
            } else {
                let t = NSTextField(labelWithString: "🖼 截圖")
                t.font = .systemFont(ofSize: 12)
                t.textColor = mine ? theme.onAccent.withAlphaComponent(0.8) : theme.text3
                content.addArrangedSubview(t)
            }
        }
        if m.hasAudio {
            let t = NSTextField(labelWithString: "🎙 附帶了最後一次錄音")
            t.font = .systemFont(ofSize: 12)
            t.textColor = mine ? theme.onAccent.withAlphaComponent(0.8) : theme.text3
            content.addArrangedSubview(t)
        }
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            content.topAnchor.constraint(equalTo: bubble.topAnchor),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
        ])

        let time = NSTextField(labelWithString: Self.localTime(m.createdAt) + (mine ? "" : " · 開發者"))
        time.font = .systemFont(ofSize: 11)
        time.textColor = theme.text3

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = mine ? .trailing : .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(bubble)
        column.addArrangedSubview(time)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: row.topAnchor),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.72),
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            mine ? column.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4)
                 : column.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
        ])
        return row
    }

    private static func localTime(_ s: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: s)
        if date == nil { iso.formatOptions = [.withInternetDateTime]; date = iso.date(from: s) }
        if date == nil {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.timeZone = TimeZone(identifier: "UTC")
            date = f.date(from: s)
        }
        guard let date else { return s }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return out.string(from: date)
    }

    // MARK: - 附件

    private func refreshAttachments() {
        attachmentRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        imageThumb = nil
        if let data = pendingImage, let image = NSImage(data: data) {
            let chip = makeChip(icon: nil, title: "截圖 · \(Int(image.size.width))×\(Int(image.size.height))",
                                remove: #selector(removeImage))
            let thumb = NSImageView(image: image)
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 4
            thumb.layer?.masksToBounds = true
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.widthAnchor.constraint(equalToConstant: 28).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 20).isActive = true
            chip.insertArrangedSubview(thumb, at: 0)
            attachmentRow.addArrangedSubview(chip)
        }
        if transcriptAttached, let t = context.latestTranscript() {
            let preview = (t.output.isEmpty ? t.asr : t.output).split(whereSeparator: \.isNewline).joined(separator: " ")
            let brief = preview.count > 24 ? String(preview.prefix(24)) + "…" : preview
            attachmentRow.addArrangedSubview(makeChip(icon: "waveform", title: "最後的轉錄：\(brief)", remove: #selector(removeTranscript)))
        }
        attachmentRow.isHidden = attachmentRow.arrangedSubviews.isEmpty
        // 已經附上了、或者根本沒有轉錄可附，就不顯示這個按鈕
        attachTranscriptButton?.isHidden = transcriptAttached || context.latestTranscript() == nil
    }

    @objc private func attachTranscript() {
        guard context.latestTranscript() != nil else { return }
        transcriptAttached = true
        refreshAttachments()
    }

    private func makeChip(icon: String?, title: String, remove: Selector) -> NSStackView {
        let chip = NSStackView()
        chip.orientation = .horizontal
        chip.alignment = .centerY
        chip.spacing = 6
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 7
        chip.layer?.setAppearanceBackground(theme.cardAlt)
        chip.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 6)
        if let icon, let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = theme.text2
            chip.addArrangedSubview(iv)
        }
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12)
        t.textColor = theme.text2
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        t.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        chip.addArrangedSubview(t)
        let x = NSButton()
        x.bezelStyle = .regularSquare
        x.isBordered = false
        x.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除")
        x.contentTintColor = theme.text3
        x.target = self
        x.action = remove
        chip.addArrangedSubview(x)
        return chip
    }

    @objc private func removeImage() { pendingImage = nil; refreshAttachments() }
    @objc private func removeTranscript() { transcriptAttached = false; refreshAttachments() }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "選一張截圖（PNG / JPG）"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        attach(image: image)
    }

    private func attach(image: NSImage) {
        SupportChatView.log?("support attach image \(Int(image.size.width))x\(Int(image.size.height))")
        guard let jpeg = SupportImageEncoder.jpegData(from: image) else {
            showStatus("這張圖片無法讀取", isError: true)
            return
        }
        pendingImage = jpeg
        refreshAttachments()
        showStatus("", isError: false)
    }

    // 拖放
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { hasImage(sender) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            attach(image: image); return true
        }
        if let image = NSImage(pasteboard: pb) { attach(image: image); return true }
        return false
    }
    private func hasImage(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) { return true }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    // MARK: - 发送

    @objc private func sendTapped() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || pendingImage != nil else {
            showStatus("請填寫內容或附上截圖再發送", isError: true)
            return
        }
        var asr: String?, polished: String?, audio: Data?
        if transcriptAttached, let t = context.latestTranscript() {
            asr = t.asr; polished = t.output; audio = t.audio
        }
        let out = SupportChatService.Outgoing(
            text: text, imageJPEG: pendingImage, audioM4A: audio,
            asrText: asr, polishedText: polished,
            recentApp: context.recentApp(), log: context.logTail(),
            deviceName: Host.current().localizedName ?? "",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        sendButton.isEnabled = false
        sendButton.title = "發送中…"
        service.send(out) { [weak self] result in
            guard let self else { return }
            sendButton.isEnabled = true
            sendButton.title = "發送"
            switch result {
            case .success:
                textView.string = ""
                pendingImage = nil
                transcriptAttached = false      // 轉錄只隨這一條發；下次要帶得再點一次
                textDidChange(Notification(name: NSText.didChangeNotification))
                refreshAttachments()
                showStatus("已發送，收到回覆會顯示在這裡", isError: false)
            case .failure(let err):
                showStatus(err.userMessage, isError: true)
            }
        }
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? theme.danger : theme.ok
        statusLabel.isHidden = text.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
    }

    /// 页面显示时：记已读 + 拉一次新回复；按钮按有没有转录可附刷新
    func pageDidAppear() {
        service.markAllSeen()
        service.sync { [weak self] _ in self?.service.markAllSeen() }
        refreshAttachments()
    }
}

// MARK: - 小件

/// 粘贴图片直接当截图附件（文字照常粘贴）
final class SupportTextView: NSTextView {
    var onPasteImage: ((NSImage) -> Void)?

    /// 剪贴板里是图（没有文字）→ 交给附件；否则照常粘贴文字。
    /// 纯文本 NSTextView 的 ⌘V 走的是 pasteAsPlainText:，不是 paste:，两个都拦。
    private func takeImageFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        let hasText = pb.string(forType: .string)?.isEmpty == false
        let image = hasText ? nil : NSImage(pasteboard: pb)
        SupportChatView.log?("support paste: types=\(pb.types?.map(\.rawValue).prefix(3) ?? []) hasText=\(hasText) image=\(image != nil)")
        guard let image else { return false }
        onPasteImage?(image)
        return true
    }
    override func paste(_ sender: Any?) {
        if takeImageFromPasteboard() { return }
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if takeImageFromPasteboard() { return }
        super.pasteAsPlainText(sender)
    }
    /// 兜底：菜单没把 ⌘V 送过来时（比如「粘贴」被判为不可用），自己认一下
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            SupportChatView.log?("support paste: keyDown ⌘V")
            if takeImageFromPasteboard() { return }
        }
        super.keyDown(with: event)
    }
    /// 空文本框也要把图当成可粘贴的东西（否则菜单里的「粘贴」是灰的、⌘V 直接被忽略）
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            let pb = NSPasteboard.general
            if NSImage.canInit(with: pb) { return true }
        }
        return super.validateUserInterfaceItem(item)
    }
}

final class SupportClickableImage: NSImageView {
    private let url: URL
    init(image: NSImage, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "點擊查看大圖"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { NSWorkspace.shared.open(url) }
}

private final class SupportFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 截图转码：任何来源的图都重画成 ≤1600px 的 JPEG，只保留像素——原文件里的元数据、附加内容一律不带走，
/// 服务器也只认这种格式。超过 1.5MB 逐档降质量。
enum SupportImageEncoder {
    static let maxDimension: CGFloat = 1600
    static let maxBytes = SupportChatService.maxImageBytes

    static func jpegData(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        for q in [0.8, 0.65, 0.5, 0.35] {
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: q]), data.count <= maxBytes {
                return data
            }
        }
        return nil
    }
}
