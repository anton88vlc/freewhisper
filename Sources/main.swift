import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import Carbon
import CoreGraphics
import Foundation

@main
@MainActor
enum FreeWhisperMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        FreeWhisperRuntime.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = RecordingStore()
    private let recorder = AudioRecorder()
    private let transcriber = TranscriptionService()
    private var status: StatusController?
    private var hotKey: HotKeyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.load()

        let status = StatusController(
            store: store,
            recorder: recorder,
            transcriber: transcriber,
            onSettingsChanged: { [weak self] in self?.reloadHotKey() }
        )
        self.status = status
        status.install()
        reloadHotKey()
    }

    private func reloadHotKey() {
        hotKey?.unregister()
        hotKey = HotKeyController(shortcut: store.settings.shortcut) { [weak self] in
            self?.status?.toggleRecording()
        }
        hotKey?.register()
    }
}

@MainActor
enum FreeWhisperRuntime {
    static var delegate: AppDelegate?
}

@MainActor
final class StatusController {
    private let store: RecordingStore
    private let recorder: AudioRecorder
    private let transcriber: TranscriptionService
    private let onSettingsChanged: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var historyWindow: NSWindow?
    private weak var historyController: HistoryViewController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var isRecording = false
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?
    private var activeTranscriptionID: UUID?
    private var targetApp: PasteTarget?
    private var transcriptionStartedAt: Date?
    private var transcriptionTimer: Timer?
    private var transcriptionFrame = 0
    private var menuActions: [MenuAction] = []
    private var lastToggleAt = Date.distantPast

    init(
        store: RecordingStore,
        recorder: AudioRecorder,
        transcriber: TranscriptionService,
        onSettingsChanged: @escaping () -> Void
    ) {
        self.store = store
        self.recorder = recorder
        self.transcriber = transcriber
        self.onSettingsChanged = onSettingsChanged
    }

    func install() {
        setIdleTitle()
        rebuildMenu()
        if store.needsOnboarding {
            openOnboarding()
        }
    }

    func toggleRecording() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.25 else { return }
        lastToggleAt = now

        if activeTranscriptionID != nil && !isRecording {
            NSSound.beep()
            return
        }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard activeTranscriptionID == nil else {
            NSSound.beep()
            return
        }
        guard MicrophonePermission.isGranted else {
            openOnboarding()
            return
        }
        do {
            targetApp = PasteTarget.current()
            let record = try store.createPendingRecording()
            try recorder.start(url: record.audioURL)
            isRecording = true
            recordingStartedAt = Date()
            startRecordingTimer()
            rebuildMenu()
        } catch {
            showError("Recording failed: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        do {
            let url = try recorder.stop()
            isRecording = false
            stopRecordingTimer()
            setIdleTitle()
            try store.markRecorded(audioURL: url)
            rebuildMenu()
            transcribeLatest(autoPaste: store.settings.autoPaste, target: targetApp)
        } catch {
            isRecording = false
            stopRecordingTimer()
            setIdleTitle()
            showError("Stop failed: \(error.localizedDescription)")
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        updateRecordingTitle()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRecordingTitle() }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }

    private func updateRecordingTitle() {
        guard let recordingStartedAt else {
            setIdleTitle()
            return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        setStatusItem(title: formatElapsed(elapsed), symbolName: "mic.fill", fallback: "R \(formatElapsed(elapsed))")
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        return "\(minutes):\(String(format: "%02d", rest))"
    }

    private func startTranscriptionTimer() {
        transcriptionTimer?.invalidate()
        transcriptionStartedAt = Date()
        transcriptionFrame = 0
        updateTranscriptionTitle()
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTranscriptionTitle() }
        }
    }

    private func stopTranscriptionTimer() {
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil
        transcriptionStartedAt = nil
    }

    private func updateTranscriptionTitle() {
        guard let transcriptionStartedAt else {
            setIdleTitle()
            return
        }
        _ = transcriptionStartedAt
        let frames = ["◐", "◓", "◑", "◒"]
        item.button?.image = nil
        item.button?.imagePosition = .noImage
        item.button?.title = frames[transcriptionFrame % frames.count]
        transcriptionFrame += 1
    }

    private func setIdleTitle() {
        setStatusItem(title: "", symbolName: "mic", fallback: "V")
    }

    private func setStatusItem(title: String, symbolName: String, fallback: String) {
        guard let button = item.button else { return }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "FreeWhisper") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
            button.title = title
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = fallback
        }
    }

    private func transcribeLatest(autoPaste: Bool, target: PasteTarget?) {
        guard let record = store.records.first else { return }
        transcribe(record, autoPaste: autoPaste, forceProvider: nil, target: target)
    }

    private func transcribe(_ record: RecordingItem, autoPaste: Bool, forceProvider: ProviderMode?, target: PasteTarget? = nil) {
        guard activeTranscriptionID == nil else {
            NSSound.beep()
            return
        }
        let settings = store.settings
        let provider = forceProvider ?? settings.providerMode
        activeTranscriptionID = record.id
        startTranscriptionTimer()
        store.update(record.id) {
            $0.status = .transcribing
            $0.errorMessage = nil
            $0.provider = provider.rawValue
        }
        rebuildMenu()

        let service = transcriber
        Task.detached {
            do {
                let text = try await service.transcribe(
                    record: record,
                    settings: settings,
                    forceProvider: forceProvider
                )
                await MainActor.run {
                    guard self.activeTranscriptionID == record.id else { return }
                    self.activeTranscriptionID = nil
                    self.stopTranscriptionTimer()
                    self.store.update(record.id) {
                        $0.status = .transcribed
                        $0.transcript = text
                        $0.errorMessage = nil
                        $0.provider = provider.rawValue
                    }
                    if autoPaste {
                        PasteboardInserter.insert(text, target: target)
                    }
                    self.setIdleTitle()
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    guard self.activeTranscriptionID == record.id else { return }
                    self.activeTranscriptionID = nil
                    self.stopTranscriptionTimer()
                    self.store.update(record.id) {
                        $0.status = .failed
                        $0.errorMessage = error.localizedDescription
                        $0.provider = provider.rawValue
                    }
                    self.setIdleTitle()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menuActions = []
        let isTranscribing = activeTranscriptionID != nil

        let toggle = NSMenuItem(
            title: isRecording ? "Stop Recording" : (isTranscribing ? "Transcribing..." : "Start Recording"),
            action: #selector(MenuAction.run(_:)),
            keyEquivalent: ""
        )
        toggle.isEnabled = isRecording || !isTranscribing
        toggle.target = action { [weak self] in self?.toggleRecording() }
        menu.addItem(toggle)

        let history = NSMenuItem(
            title: "Open Recordings",
            action: #selector(MenuAction.run(_:)),
            keyEquivalent: ""
        )
        history.target = action { [weak self] in self?.openHistory() }
        menu.addItem(history)

        let settings = NSMenuItem(
            title: "Settings",
            action: #selector(MenuAction.run(_:)),
            keyEquivalent: ""
        )
        settings.target = action { [weak self] in self?.openSettings() }
        menu.addItem(settings)

        let setup = NSMenuItem(
            title: "Setup / Permissions",
            action: #selector(MenuAction.run(_:)),
            keyEquivalent: ""
        )
        setup.target = action { [weak self] in self?.openOnboarding() }
        menu.addItem(setup)

        menu.addItem(.separator())

        for record in store.records.prefix(5) {
            let title = "\(record.shortTime) \(record.status.menuLabel)"
            let submenu = NSMenu()

            let retryAuto = NSMenuItem(title: "Transcribe", action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            retryAuto.isEnabled = !isTranscribing && record.status != .transcribing
            retryAuto.target = action { [weak self] in self?.transcribe(record, autoPaste: false, forceProvider: nil) }
            submenu.addItem(retryAuto)

            let retryDeepgram = NSMenuItem(title: "Retry Deepgram", action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            retryDeepgram.isEnabled = !isTranscribing && record.status != .transcribing
            retryDeepgram.target = action { [weak self] in self?.transcribe(record, autoPaste: false, forceProvider: .deepgram) }
            submenu.addItem(retryDeepgram)

            let retryLocal = NSMenuItem(title: "Retry Local Whisper", action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            retryLocal.isEnabled = !isTranscribing && record.status != .transcribing
            retryLocal.target = action { [weak self] in self?.transcribe(record, autoPaste: false, forceProvider: .localWhisper) }
            submenu.addItem(retryLocal)

            if let text = record.transcript, !text.isEmpty {
                let copy = NSMenuItem(title: "Copy Transcript", action: #selector(MenuAction.run(_:)), keyEquivalent: "")
                copy.target = action { PasteboardInserter.copy(text) }
                submenu.addItem(copy)

                let insert = NSMenuItem(title: "Insert Transcript", action: #selector(MenuAction.run(_:)), keyEquivalent: "")
                insert.target = action { PasteboardInserter.insert(text) }
                submenu.addItem(insert)
            }

            let reveal = NSMenuItem(title: "Reveal Audio", action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            reveal.target = action { NSWorkspace.shared.activateFileViewerSelecting([record.audioURL]) }
            submenu.addItem(reveal)

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Hotkey: \(store.settings.shortcut.label)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        historyController?.reload()
    }

    private func action(_ closure: @escaping () -> Void) -> MenuAction {
        let action = MenuAction(closure)
        menuActions.append(action)
        return action
    }

    private func openHistory() {
        if let historyWindow {
            historyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = HistoryViewController(
            store: store,
            onRetry: { [weak self] record, provider in
                self?.transcribe(record, autoPaste: false, forceProvider: provider)
            }
        )
        historyController = controller
        let window = NSWindow(contentViewController: controller)
        window.title = "FreeWhisper Recordings"
        window.setContentSize(NSSize(width: 820, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }

    private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsViewController(store: store) { [weak self] in
            self?.store.saveSettings()
            self?.onSettingsChanged()
            self?.rebuildMenu()
        }
        let window = NSWindow(contentViewController: controller)
        window.title = "FreeWhisper Settings"
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func openOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            onboardingWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = OnboardingViewController(store: store) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.rebuildMenu()
        }
        let window = NSWindow(contentViewController: controller)
        window.title = "FreeWhisper Setup"
        window.setContentSize(NSSize(width: 560, height: 390))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "FreeWhisper"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
final class MenuAction: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func run(_ sender: Any?) {
        closure()
    }
}

@MainActor
final class HistoryViewController: NSViewController {
    private let store: RecordingStore
    private let onRetry: (RecordingItem, ProviderMode?) -> Void
    private let stack = NSStackView()

    init(store: RecordingStore, onRetry: @escaping (RecordingItem, ProviderMode?) -> Void) {
        self.store = store
        self.onRetry = onRetry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if store.records.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No recordings yet."))
            return
        }
        for record in store.records {
            stack.addArrangedSubview(row(for: record))
        }
    }

    private func row(for record: RecordingItem) -> NSView {
        let isTranscribing = store.hasTranscribingRecord
        let box = NSBox()
        box.boxType = .primary
        box.cornerRadius = 6
        box.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView()
        v.orientation = .vertical
        v.spacing = 6
        v.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "\(record.fullTime) · \(record.status.menuLabel) · \(record.durationLabel) · \(record.provider)")
        title.font = .boldSystemFont(ofSize: 13)
        v.addArrangedSubview(title)

        let text = NSTextField(wrappingLabelWithString: record.transcript ?? record.errorMessage ?? "No transcript yet.")
        text.maximumNumberOfLines = 5
        v.addArrangedSubview(text)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let retry = RecordButton(title: "Transcribe", target: self, action: #selector(retryClicked(_:)))
        retry.recordID = record.id
        retry.isEnabled = !isTranscribing && record.status != .transcribing
        buttons.addArrangedSubview(retry)

        let deepgram = RecordButton(title: "Deepgram", target: self, action: #selector(deepgramClicked(_:)))
        deepgram.recordID = record.id
        deepgram.isEnabled = !isTranscribing && record.status != .transcribing
        buttons.addArrangedSubview(deepgram)

        let local = RecordButton(title: "Local", target: self, action: #selector(localClicked(_:)))
        local.recordID = record.id
        local.isEnabled = !isTranscribing && record.status != .transcribing
        buttons.addArrangedSubview(local)

        let copy = RecordButton(title: "Copy", target: self, action: #selector(copyClicked(_:)))
        copy.recordID = record.id
        copy.isEnabled = !(record.transcript ?? "").isEmpty
        buttons.addArrangedSubview(copy)

        let reveal = RecordButton(title: "Reveal", target: self, action: #selector(revealClicked(_:)))
        reveal.recordID = record.id
        buttons.addArrangedSubview(reveal)

        v.addArrangedSubview(buttons)
        box.contentView?.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 780),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])
        return box
    }

    @objc private func retryClicked(_ sender: RecordButton) {
        guard let record = record(for: sender) else { return }
        onRetry(record, nil)
    }

    @objc private func deepgramClicked(_ sender: RecordButton) {
        guard let record = record(for: sender) else { return }
        onRetry(record, .deepgram)
    }

    @objc private func localClicked(_ sender: RecordButton) {
        guard let record = record(for: sender) else { return }
        onRetry(record, .localWhisper)
    }

    @objc private func copyClicked(_ sender: RecordButton) {
        guard let text = record(for: sender)?.transcript else { return }
        PasteboardInserter.copy(text)
    }

    @objc private func revealClicked(_ sender: RecordButton) {
        guard let record = record(for: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([record.audioURL])
    }

    private func record(for button: RecordButton) -> RecordingItem? {
        guard let id = button.recordID else { return nil }
        return store.record(id: id)
    }
}

@MainActor
final class OnboardingViewController: NSViewController {
    private let store: RecordingStore
    private let onDone: () -> Void
    private let micStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let deepgramStatus = NSTextField(labelWithString: "")
    private let continueButton = NSButton()

    init(store: RecordingStore, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "FreeWhisper Setup")
        title.font = .boldSystemFont(ofSize: 22)

        let intro = NSTextField(wrappingLabelWithString: "Grant microphone once here. Accessibility is optional and only controls automatic paste; dictation still works without it by copying text to the clipboard.")
        intro.textColor = .secondaryLabelColor
        let accessibilityHint = NSTextField(wrappingLabelWithString: "If Accessibility is enabled in System Settings but still shows Missing here, macOS is pointing at an old FreeWhisper entry. You can continue; auto paste will fall back to clipboard.")
        accessibilityHint.textColor = .secondaryLabelColor
        accessibilityHint.font = .systemFont(ofSize: 12)

        let micButton = NSButton(title: "Grant Microphone", target: self, action: #selector(grantMicrophoneClicked(_:)))
        let accessibilityButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilityClicked(_:)))
        let deepgramButton = NSButton(title: "Get Deepgram Key", target: self, action: #selector(openDeepgramClicked(_:)))
        let refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refreshClicked(_:)))

        continueButton.title = "Continue"
        continueButton.target = self
        continueButton.action = #selector(continueClicked(_:))

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(row(label: "Microphone", status: micStatus, button: micButton))
        stack.addArrangedSubview(row(label: "Accessibility", status: accessibilityStatus, button: accessibilityButton))
        stack.addArrangedSubview(row(label: "Deepgram key", status: deepgramStatus, button: deepgramButton))
        stack.addArrangedSubview(accessibilityHint)
        stack.addArrangedSubview(refreshButton)
        stack.addArrangedSubview(continueButton)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)
        ])
        refreshStatus()
    }

    private func row(label: String, status: NSTextField, button: NSButton) -> NSView {
        let grid = NSGridView()
        grid.columnSpacing = 10
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .boldSystemFont(ofSize: 13)
        grid.addRow(with: [labelView, status, button])
        return grid
    }

    private func refreshStatus() {
        micStatus.stringValue = MicrophonePermission.statusLabel
        micStatus.textColor = MicrophonePermission.isGranted ? .systemGreen : .systemRed
        accessibilityStatus.stringValue = AccessibilityPermission.isTrusted ? "Granted" : "Clipboard fallback"
        accessibilityStatus.textColor = AccessibilityPermission.isTrusted ? .systemGreen : .secondaryLabelColor
        deepgramStatus.stringValue = DeepgramKeyStore.hasKey ? "Configured" : "Missing"
        deepgramStatus.textColor = DeepgramKeyStore.hasKey ? .systemGreen : .systemRed
        continueButton.isEnabled = MicrophonePermission.isGranted
    }

    @objc private func grantMicrophoneClicked(_ sender: Any?) {
        MicrophonePermission.request { [weak self] in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    @objc private func openAccessibilityClicked(_ sender: Any?) {
        AccessibilityPermission.promptAndOpenSettings()
        refreshStatus()
    }

    @objc private func openDeepgramClicked(_ sender: Any?) {
        DeepgramKeyStore.openSignup()
    }

    @objc private func refreshClicked(_ sender: Any?) {
        refreshStatus()
    }

    @objc private func continueClicked(_ sender: Any?) {
        refreshStatus()
        guard MicrophonePermission.isGranted else {
            NSSound.beep()
            return
        }
        store.settings.hasCompletedOnboarding = true
        store.saveSettings()
        onDone()
    }
}

@MainActor
final class SettingsViewController: NSViewController {
    private let store: RecordingStore
    private let onChange: () -> Void
    private let provider = NSPopUpButton()
    private let language = NSPopUpButton()
    private let localModel = NSPopUpButton()
    private let shortcut = NSPopUpButton()
    private let historyLimit = NSTextField()
    private let autoPaste = NSButton(checkboxWithTitle: "Auto paste after transcription", target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let deepgramStatus = NSTextField(labelWithString: "")

    init(store: RecordingStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        let form = NSGridView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 12
        form.columnSpacing = 12

        provider.addItems(withTitles: ProviderMode.allCases.map(\.label))
        language.addItems(withTitles: LanguageMode.allCases.map(\.label))
        localModel.addItems(withTitles: LocalWhisperModel.allCases.map(\.label))
        shortcut.addItems(withTitles: ShortcutPreset.allCases.map(\.label))
        historyLimit.placeholderString = "50"

        addRow("Provider", provider, to: form)
        addRow("Language", language, to: form)
        addRow("Local model", localModel, to: form)
        addRow("Hotkey", shortcut, to: form)
        addRow("History limit", historyLimit, to: form)
        addRow("", autoPaste, to: form)
        addRow("Deepgram key", deepgramStatus, to: form)
        addRow("Accessibility", accessibilityStatus, to: form)

        let note = NSTextField(wrappingLabelWithString: "Auto language is tuned for Russian dictation with English terms. If Deepgram gets weird, retry the saved audio with Local Whisper.")
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let permissions = NSTextField(wrappingLabelWithString: "Permissions: macOS will ask for Microphone on first recording. Auto paste requires Accessibility permission for FreeWhisper in System Settings.")
        permissions.textColor = .secondaryLabelColor
        permissions.translatesAutoresizingMaskIntoConstraints = false

        let openAccessibility = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilityClicked(_:)))
        openAccessibility.translatesAutoresizingMaskIntoConstraints = false
        let openDeepgram = NSButton(title: "Get Deepgram Key", target: self, action: #selector(openDeepgramClicked(_:)))
        openDeepgram.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked(_:)))
        save.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(form)
        view.addSubview(note)
        view.addSubview(permissions)
        view.addSubview(openAccessibility)
        view.addSubview(openDeepgram)
        view.addSubview(save)

        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            note.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            note.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 18),
            permissions.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            permissions.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            permissions.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            openAccessibility.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            openAccessibility.topAnchor.constraint(equalTo: permissions.bottomAnchor, constant: 12),
            openDeepgram.leadingAnchor.constraint(equalTo: openAccessibility.trailingAnchor, constant: 10),
            openDeepgram.centerYAnchor.constraint(equalTo: openAccessibility.centerYAnchor),
            save.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            save.topAnchor.constraint(equalTo: openAccessibility.bottomAnchor, constant: 20)
        ])
        loadSettings()
    }

    private func addRow(_ label: String, _ control: NSView, to form: NSGridView) {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        form.addRow(with: [labelView, control])
    }

    private func loadSettings() {
        provider.selectItem(withTitle: store.settings.providerMode.label)
        language.selectItem(withTitle: store.settings.languageMode.label)
        localModel.selectItem(withTitle: store.settings.localModel.label)
        shortcut.selectItem(withTitle: store.settings.shortcut.label)
        historyLimit.stringValue = "\(store.settings.historyLimit)"
        autoPaste.state = store.settings.autoPaste ? .on : .off
        deepgramStatus.stringValue = DeepgramKeyStore.hasKey ? "Configured" : "Missing"
        deepgramStatus.textColor = DeepgramKeyStore.hasKey ? .systemGreen : .systemRed
        accessibilityStatus.stringValue = AccessibilityPermission.isTrusted ? "Granted" : "Missing"
        accessibilityStatus.textColor = AccessibilityPermission.isTrusted ? .systemGreen : .systemRed
    }

    @objc private func saveClicked(_ sender: Any?) {
        if let value = ProviderMode.allCases.first(where: { $0.label == provider.titleOfSelectedItem }) {
            store.settings.providerMode = value
        }
        if let value = LanguageMode.allCases.first(where: { $0.label == language.titleOfSelectedItem }) {
            store.settings.languageMode = value
        }
        if let value = LocalWhisperModel.allCases.first(where: { $0.label == localModel.titleOfSelectedItem }) {
            store.settings.localModel = value
        }
        if let value = ShortcutPreset.allCases.first(where: { $0.label == shortcut.titleOfSelectedItem }) {
            store.settings.shortcut = value
        }
        store.settings.historyLimit = max(1, Int(historyLimit.stringValue) ?? 50)
        store.settings.autoPaste = autoPaste.state == .on
        store.prune()
        onChange()
    }

    @objc private func openAccessibilityClicked(_ sender: Any?) {
        AccessibilityPermission.promptAndOpenSettings()
        loadSettings()
    }

    @objc private func openDeepgramClicked(_ sender: Any?) {
        DeepgramKeyStore.openSignup()
    }
}

enum MicrophonePermission {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isGranted: Bool {
        status == .authorized
    }

    static var statusLabel: String {
        switch status {
        case .authorized: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    static func request(completion: @escaping @Sendable () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in completion() }
    }
}

final class RecordButton: NSButton {
    var recordID: UUID?
}

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var currentURL: URL?

    func start(url: URL) throws {
        resetEngine()
        let newEngine = AVAudioEngine()
        engine = newEngine
        currentURL = url
        let input = newEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        file = try AVAudioFile(forWriting: url, settings: inputFormat.settings)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            try? file.write(from: buffer)
        }

        newEngine.prepare()
        try newEngine.start()
    }

    func stop() throws -> URL {
        resetEngine()
        file = nil
        guard let url = currentURL else { throw FreeWhisperError.message("No active recording") }
        currentURL = nil
        return url
    }

    private func resetEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
        }
        engine = nil
        file = nil
    }
}

@MainActor
final class RecordingStore {
    private(set) var records: [RecordingItem] = []
    var settings = FreeWhisperSettings()
    private let fm = FileManager.default
    private let baseURL: URL
    private let settingsURL: URL
    private var pendingID: UUID?

    init() {
        let applicationSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let root = applicationSupport.appendingPathComponent("FreeWhisper")
        baseURL = root.appendingPathComponent("Recordings")
        settingsURL = root.appendingPathComponent("settings.json")
    }

    func load() {
        try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        loadSettings()
        records = (try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil))
            .orEmpty
            .compactMap { dir in
                let metadata = dir.appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metadata) else { return nil }
                return try? JSONDecoder.freeWhisper.decode(RecordingItem.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
        recoverInterruptedRecords()
        prune()
    }

    func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder.freeWhisper.decode(FreeWhisperSettings.self, from: data) else {
            saveSettings()
            return
        }
        settings = decoded
    }

    func saveSettings() {
        try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.freeWhisper.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    func createPendingRecording() throws -> RecordingItem {
        try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let id = UUID()
        let dir = baseURL.appendingPathComponent(id.uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var record = RecordingItem(id: id, createdAt: Date(), status: .recording)
        record.directoryPath = dir.path
        record.audioPath = dir.appendingPathComponent("audio.wav").path
        record.provider = settings.providerMode.rawValue
        pendingID = id
        records.insert(record, at: 0)
        try save(record)
        return record
    }

    func markRecorded(audioURL: URL) throws {
        guard let id = pendingID else { return }
        update(id) {
            $0.status = .recorded
            $0.durationSeconds = WavInfo.durationSeconds(url: audioURL)
        }
        pendingID = nil
        prune()
    }

    func update(_ id: UUID, mutate: (inout RecordingItem) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        try? save(records[index])
    }

    func record(id: UUID) -> RecordingItem? {
        records.first { $0.id == id }
    }

    var needsOnboarding: Bool {
        !settings.hasCompletedOnboarding || !MicrophonePermission.isGranted
    }

    var hasTranscribingRecord: Bool {
        records.contains { $0.status == .transcribing }
    }

    func prune() {
        let overflow = records.dropFirst(settings.historyLimit)
        for item in overflow {
            try? fm.removeItem(at: item.directoryURL)
        }
        records = Array(records.prefix(settings.historyLimit))
    }

    private func save(_ record: RecordingItem) throws {
        let data = try JSONEncoder.freeWhisper.encode(record)
        try data.write(to: record.directoryURL.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func recoverInterruptedRecords() {
        for index in records.indices {
            switch records[index].status {
            case .transcribing:
                records[index].status = .failed
                records[index].errorMessage = "Transcription was interrupted before FreeWhisper could finish it. Audio is preserved; retry manually."
                try? save(records[index])
            case .recording:
                records[index].status = .failed
                records[index].durationSeconds = WavInfo.durationSeconds(url: records[index].audioURL)
                records[index].errorMessage = "Recording was interrupted before FreeWhisper could stop it cleanly. Audio is preserved; retry manually if it is playable."
                try? save(records[index])
            case .recorded, .transcribed, .failed:
                break
            }
        }
    }
}

struct FreeWhisperSettings: Codable, Sendable {
    var historyLimit = 50
    var languageMode = LanguageMode.autoCodeSwitch
    var providerMode = ProviderMode.deepgram
    var localModel = LocalWhisperModel.small
    var shortcut = ShortcutPreset.optionSpace
    var autoPaste = true
    var hasCompletedOnboarding = false
}

enum ProviderMode: String, Codable, CaseIterable, Sendable {
    case auto
    case deepgram
    case localWhisper

    var label: String {
        switch self {
        case .auto: "Auto: Deepgram -> Local"
        case .deepgram: "Deepgram Nova-3"
        case .localWhisper: "Local Whisper"
        }
    }
}

enum LanguageMode: String, Codable, CaseIterable, Sendable {
    case autoCodeSwitch
    case ru
    case en
    case es

    var label: String {
        switch self {
        case .autoCodeSwitch: "Multilingual / RU with English terms"
        case .ru: "Russian"
        case .en: "English"
        case .es: "Spanish"
        }
    }

    var whisperValue: String? {
        switch self {
        case .autoCodeSwitch: nil
        case .ru: "ru"
        case .en: "en"
        case .es: "es"
        }
    }
}

enum LocalWhisperModel: String, Codable, CaseIterable, Sendable {
    case tiny
    case base
    case small
    case largeV3Turbo

    var label: String {
        switch self {
        case .tiny: "tiny"
        case .base: "base"
        case .small: "small"
        case .largeV3Turbo: "large-v3-turbo"
        }
    }

    var cliValue: String { label }
}

enum ShortcutPreset: String, Codable, CaseIterable, Sendable {
    case optionSpace
    case controlSpace
    case commandShiftSpace
    case optionD

    var label: String {
        switch self {
        case .optionSpace: "Option + Space"
        case .controlSpace: "Control + Space"
        case .commandShiftSpace: "Command + Shift + Space"
        case .optionD: "Option + D"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .optionSpace, .controlSpace, .commandShiftSpace: UInt32(kVK_Space)
        case .optionD: UInt32(kVK_ANSI_D)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .optionD: UInt32(optionKey)
        }
    }
}

struct RecordingItem: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var status: RecordingStatus
    var provider = ProviderMode.auto.rawValue
    var transcript: String?
    var errorMessage: String?
    var durationSeconds: Double?
    var directoryPath = ""
    var audioPath = ""

    var directoryURL: URL { URL(fileURLWithPath: directoryPath) }
    var audioURL: URL { URL(fileURLWithPath: audioPath) }

    var shortTime: String { DateFormatter.shortTime.string(from: createdAt) }
    var fullTime: String { DateFormatter.fullTime.string(from: createdAt) }
    var durationLabel: String {
        guard let durationSeconds else { return "unknown" }
        return String(format: "%.1fs", durationSeconds)
    }
}

enum RecordingStatus: String, Codable, Sendable {
    case recording
    case recorded
    case transcribing
    case transcribed
    case failed

    var menuLabel: String {
        switch self {
        case .recording: "recording"
        case .recorded: "recorded"
        case .transcribing: "transcribing"
        case .transcribed: "done"
        case .failed: "failed"
        }
    }
}

struct TranscriptionService: Sendable {
    private let keyCenter = KeyCenter()

    func transcribe(record: RecordingItem, settings: FreeWhisperSettings, forceProvider: ProviderMode?) async throws -> String {
        let provider = forceProvider ?? settings.providerMode
        switch provider {
        case .deepgram:
            return try await transcribeDeepgram(record: record, settings: settings)
        case .localWhisper:
            return try transcribeLocal(record: record, settings: settings)
        case .auto:
            do {
                return try await transcribeDeepgram(record: record, settings: settings)
            } catch {
                return try transcribeLocal(record: record, settings: settings)
            }
        }
    }

    private func transcribeDeepgram(record: RecordingItem, settings: FreeWhisperSettings) async throws -> String {
        let key = try keyCenter.deepgramAPIKey()
        let payload = DeepgramAudioPayload.prepare(record: record)
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var query = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true")
        ]
        switch settings.languageMode {
        case .autoCodeSwitch:
            query.append(URLQueryItem(name: "language", value: "multi"))
        case .ru, .en, .es:
            query.append(URLQueryItem(name: "language", value: settings.languageMode.rawValue))
        }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(payload.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: payload.url)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FreeWhisperError.message("Deepgram returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FreeWhisperError.message("Deepgram HTTP \(http.statusCode): \(body)")
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        let transcript = decoded.results.channels.first?.alternatives.first?.transcript ?? ""
        return try nonEmpty(transcript, source: "Deepgram")
    }

    private func transcribeLocal(record: RecordingItem, settings: FreeWhisperSettings) throws -> String {
        let whisper = try LocalWhisper.findExecutable()
        let outDir = record.directoryURL.appendingPathComponent("local-whisper", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var args = [
            record.audioURL.path,
            "--model", settings.localModel.cliValue,
            "--output_dir", outDir.path,
            "--output_format", "txt",
            "--verbose", "False"
        ]
        if let language = settings.languageMode.whisperValue {
            args.append(contentsOf: ["--language", language])
        }

        let result = try LocalWhisper.run(executable: whisper, arguments: args, timeout: 90)
        guard result.exitCode == 0 else {
            throw FreeWhisperError.message("Local Whisper failed: \(result.stderr.prefix(1000))")
        }

        let txtFiles = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil))
            .orEmpty
            .filter { $0.pathExtension == "txt" }
        guard let txt = txtFiles.first else {
            throw FreeWhisperError.message("Local Whisper produced no text file")
        }
        let transcript = try String(contentsOf: txt, encoding: .utf8)
        return try nonEmpty(transcript, source: "Local Whisper")
    }

    private func nonEmpty(_ text: String, source: String) throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw FreeWhisperError.message("\(source) returned an empty transcript") }
        return cleaned
    }
}

struct DeepgramAudioPayload {
    let url: URL
    let contentType: String

    static func prepare(record: RecordingItem) -> DeepgramAudioPayload {
        let source = record.audioURL
        guard let ffmpeg = findFFmpeg() else {
            return DeepgramAudioPayload(url: source, contentType: "audio/wav")
        }

        let output = record.directoryURL.appendingPathComponent("deepgram-16k.flac")
        if FileManager.default.fileExists(atPath: output.path) {
            return DeepgramAudioPayload(url: output, contentType: "audio/flac")
        }

        do {
            try runFFmpeg(
                executable: ffmpeg,
                arguments: [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-i", source.path,
                    "-ac", "1",
                    "-ar", "16000",
                    "-compression_level", "5",
                    output.path
                ],
                timeout: 15
            )
            return DeepgramAudioPayload(url: output, contentType: "audio/flac")
        } catch {
            return DeepgramAudioPayload(url: source, contentType: "audio/wav")
        }
    }

    private static func findFFmpeg() -> String? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func runFFmpeg(executable: String, arguments: [String], timeout: TimeInterval) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw FreeWhisperError.message("Audio optimization timed out")
        }
        guard process.terminationStatus == 0 else {
            throw FreeWhisperError.message("Audio optimization failed")
        }
    }
}

struct KeyCenter: Sendable {
    private let envPath = "\(NSHomeDirectory())/Library/Application Support/FreeWhisper/secrets.env"

    func deepgramAPIKey() throws -> String {
        if let value = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !value.isEmpty {
            return value
        }
        guard let text = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            throw FreeWhisperError.message(DeepgramKeyStore.missingKeyMessage)
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DEEPGRAM_API_KEY=") else { continue }
            let raw = trimmed.dropFirst("DEEPGRAM_API_KEY=".count)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        throw FreeWhisperError.message(DeepgramKeyStore.missingKeyMessage)
    }
}

enum DeepgramKeyStore {
    static var secretsPath: String {
        "\(NSHomeDirectory())/Library/Application Support/FreeWhisper/secrets.env"
    }

    static var hasKey: Bool {
        if let key = try? KeyCenter().deepgramAPIKey() {
            return !key.isEmpty
        }
        return false
    }

    static var missingKeyMessage: String {
        """
        Deepgram API key is missing.

        Get a key at https://console.deepgram.com/signup. Deepgram currently advertises a free $200 credit on the Pay As You Go plan.

        Then add it to:
        \(secretsPath)

        Format:
        DEEPGRAM_API_KEY=YOUR_KEY
        """
    }

    @MainActor
    static func openSignup() {
        if let url = URL(string: "https://console.deepgram.com/signup") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LocalWhisper {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func findExecutable() throws -> String {
        for path in ["/opt/homebrew/bin/whisper", "/usr/local/bin/whisper"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw FreeWhisperError.message("Local whisper executable not found")
    }

    static func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning {
                process.interrupt()
            }
            throw FreeWhisperError.message("Local Whisper timed out after \(Int(timeout))s")
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }
}

struct DeepgramResponse: Codable {
    struct Results: Codable {
        struct Channel: Codable {
            struct Alternative: Codable {
                var transcript: String
            }
            var alternatives: [Alternative]
        }
        var channels: [Channel]
    }
    var results: Results
}

@MainActor
final class HotKeyController {
    private let shortcut: ShortcutPreset
    private let callback: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init(shortcut: ShortcutPreset, callback: @escaping () -> Void) {
        self.shortcut = shortcut
        self.callback = callback
    }

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.callback()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(UInt32(0x56494E4B)), id: 1)
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeyRef = nil
        eventHandler = nil
    }
}

enum PasteboardInserter {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func insert(_ text: String, target: PasteTarget? = nil) {
        copy(text)
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            postPasteShortcut()
            if !AccessibilityPermission.isTrusted {
                NSSound.beep()
            }
        }
    }

    @MainActor
    private static func postPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

struct PasteTarget: Sendable {
    let processIdentifier: pid_t
    let localizedName: String?

    @MainActor
    static func current() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard app.processIdentifier != ownPID else { return nil }
        return PasteTarget(processIdentifier: app.processIdentifier, localizedName: app.localizedName)
    }

    @MainActor
    func activate() {
        NSRunningApplication(processIdentifier: processIdentifier)?
            .activate()
    }
}

enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func promptAndOpenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum WavInfo {
    static func durationSeconds(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

enum FreeWhisperError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

extension JSONEncoder {
    static var freeWhisper: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var freeWhisper: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let fullTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

extension Optional where Wrapped == [URL] {
    var orEmpty: [URL] { self ?? [] }
}
