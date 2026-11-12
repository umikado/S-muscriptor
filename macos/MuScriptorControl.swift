import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var helper: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var incoming = Data()
    private var generation = UUID()
    private var quitting = false
    private var busy = false
    private let defaults = UserDefaults.standard
    private let statusLabel = NSTextField(wrappingLabelWithString: "已停止")
    private let cacheLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let models = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startButton = NSButton(title: "启动服务", target: nil, action: nil)
    private let openButton = NSButton(title: "打开页面", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止服务", target: nil, action: nil)
    private let logButton = NSButton(title: "查看日志", target: nil, action: nil)
    private var settingsItems: [NSMenuItem] = []
    private var bundled: [String: Any] = [:]
    private var diagnosticLog: URL?
    private let serverURL = URL(string: "http://127.0.0.1:8222")!
    private let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MuScriptor Control", isDirectory: true)
    private var logURL: URL { logDirectory.appendingPathComponent("server.log") }
    private var repository: String {
        defaults.string(forKey: "repository")
            ?? (bundled["RepositoryPath"] as? String ?? "")
    }
    private var cacheDirectory: String {
        defaults.string(forKey: "cacheDirectory")
            ?? (bundled["HFHubCachePath"] as? String ?? "")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let value = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            bundled = value as? [String: Any] ?? [:]
        }
        buildMenu()
        buildWindow()
        launchHelper()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu(title: "MuScriptor Control")
        appMenu.autoenablesItems = false
        for (title, action) in [
            ("选择项目文件夹…", #selector(chooseRepository)),
            ("选择模型缓存文件夹…", #selector(chooseCache)),
            ("使用默认模型缓存", #selector(resetCache)),
        ] {
            let setting = NSMenuItem(title: title, action: action, keyEquivalent: "")
            setting.target = self
            appMenu.addItem(setting)
            settingsItems.append(setting)
        }
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MuScriptor Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 325),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "MuScriptor Control"
        window.isReleasedWhenClosed = false
        window.center()
        let root = window.contentView!
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        let title = NSTextField(labelWithString: "MuScriptor")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "本地音频转 MIDI")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        stack.addArrangedSubview(heading)

        models.addItems(withTitles: ["Medium（推荐）", "Large", "Small"])
        let saved = defaults.string(forKey: "model") ?? "medium"
        models.selectItem(at: ["medium", "large", "small"].firstIndex(of: saved) ?? 0)
        models.target = self
        models.action = #selector(modelChanged)
        let modelRow = NSStackView(views: [NSTextField(labelWithString: "转录模型"), models])
        modelRow.spacing = 12
        stack.addArrangedSubview(modelRow)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.maximumNumberOfLines = 3
        statusLabel.font = .systemFont(ofSize: 13)
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.spacing = 8
        stack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        startButton.target = self
        startButton.action = #selector(startService)
        startButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openPage)
        stopButton.target = self
        stopButton.action = #selector(stopService)
        for button in [startButton, openButton, stopButton] {
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 130).isActive = true
        }
        let actions = NSStackView(views: [startButton, openButton, stopButton])
        actions.spacing = 10
        stack.addArrangedSubview(actions)

        cacheLabel.font = .systemFont(ofSize: 11)
        cacheLabel.textColor = .secondaryLabelColor
        cacheLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(cacheLabel)
        cacheLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshCacheLabel()
        logButton.bezelStyle = .inline
        logButton.target = self
        logButton.action = #selector(openLog)
        let note = NSTextField(labelWithString: "退出应用时会自动停止服务")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [logButton, note])
        footer.spacing = 16
        stack.addArrangedSubview(footer)
        update(state: "stopped", message: "已停止", owned: false, canOpen: false)
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshCacheLabel() {
        let cache = cacheDirectory
        cacheLabel.stringValue = cache.isEmpty ? "模型缓存：默认位置" : "模型缓存：\(cache)"
        cacheLabel.toolTip = cache.isEmpty ? "使用 Hugging Face 默认缓存" : cache
    }

    @objc private func modelChanged() {
        defaults.set(selectedModel, forKey: "model")
    }

    private var selectedModel: String {
        ["medium", "large", "small"][max(0, models.indexOfSelectedItem)]
    }

    private func launchHelper() {
        guard helper == nil else { return }
        let repo = URL(fileURLWithPath: repository, isDirectory: true)
        let python = repo.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let script = Bundle.main.url(forResource: "service_controller", withExtension: "py") else {
            update(state: "error", message: "找不到项目 Python 环境。请在菜单中选择项目文件夹，并先完成 uv sync --frozen。", owned: false, canOpen: false)
            return
        }
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let diagnostics = logDirectory.appendingPathComponent("controller.log")
            diagnosticLog = nil
            if !FileManager.default.fileExists(atPath: diagnostics.path) {
                _ = FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
            }
            let errors = try FileHandle(forWritingTo: diagnostics)
            _ = try errors.seekToEnd()
            defer { try? errors.close() }
            let process = Process()
            let toHelper = Pipe()
            let fromHelper = Pipe()
            let token = UUID()
            generation = token
            incoming = Data()
            process.executableURL = python
            process.arguments = [script.path, "--repo", repo.path, "--log-file", logURL.path]
            process.currentDirectoryURL = repo
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUTF8"] = "1"
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment
            process.standardInput = toHelper
            process.standardOutput = fromHelper
            process.standardError = errors
            fromHelper.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async {
                    guard let self = self, self.generation == token else { return }
                    self.receive(data)
                }
            }
            process.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async {
                    guard let self = self, self.helper === ended else { return }
                    self.output?.fileHandleForReading.readabilityHandler = nil
                    self.helper = nil
                    self.input = nil
                    self.output = nil
                    self.generation = UUID()
                    if self.quitting {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } else {
                        self.diagnosticLog = diagnostics
                        self.update(state: "error", message: "控制程序已退出，请查看 controller.log 或重新启动应用。", owned: false, canOpen: false)
                    }
                }
            }
            try process.run()
            helper = process
            input = toHelper
            output = fromHelper
        } catch {
            update(state: "error", message: "无法启动控制程序：\(error.localizedDescription)", owned: false, canOpen: false)
        }
    }

    private func receive(_ data: Data) {
        incoming.append(data)
        while let newline = incoming.firstIndex(of: 10) {
            let line = incoming.subdata(in: 0..<newline)
            incoming.removeSubrange(0...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let value = object as? [String: Any],
                  let state = value["state"] as? String,
                  let message = value["message"] as? String else { continue }
            update(state: state, message: message, owned: value["owned"] as? Bool ?? false,
                   canOpen: value["can_open"] as? Bool ?? false)
        }
    }

    @discardableResult
    private func send(_ command: [String: Any]) -> Bool {
        guard let pipe = input, helper?.isRunning == true else { return false }
        do {
            var data = try JSONSerialization.data(withJSONObject: command)
            data.append(10)
            try pipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            update(state: "error", message: "无法连接控制程序，请重新启动应用。", owned: false, canOpen: false)
            return false
        }
    }

    private func update(state: String, message: String, owned: Bool, canOpen: Bool) {
        busy = owned || state == "starting" || state == "stopping"
        statusLabel.stringValue = message
        statusLabel.textColor = state == "error" ? .systemRed : .labelColor
        startButton.isEnabled = !busy && !quitting
        stopButton.isEnabled = owned && state != "stopping" && !quitting
        openButton.isEnabled = canOpen && !quitting
        models.isEnabled = !busy && !quitting
        for item in settingsItems { item.isEnabled = !busy && !quitting }
        if state == "starting" || state == "stopping" {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    @objc private func startService() {
        launchHelper()
        guard helper != nil else { return }
        if send(["action": "start", "model": selectedModel, "cache_dir": cacheDirectory]) {
            update(state: "starting", message: "正在启动服务…", owned: true, canOpen: false)
        }
    }

    @objc private func stopService() {
        if send(["action": "stop"]) {
            update(state: "stopping", message: "正在停止服务…", owned: true, canOpen: false)
        }
    }

    @objc private func openPage() { NSWorkspace.shared.open(serverURL) }

    @objc private func openLog() {
        let target = diagnosticLog ?? (FileManager.default.fileExists(atPath: logURL.path)
            ? logURL : logDirectory.appendingPathComponent("controller.log"))
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.open(target)
        }
    }

    @objc private func chooseCache() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择模型缓存文件夹"
        panel.prompt = "使用此文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            defaults.set(url.path, forKey: "cacheDirectory")
            refreshCacheLabel()
        }
    }

    @objc private func resetCache() {
        guard !busy else { return }
        defaults.set("", forKey: "cacheDirectory")
        refreshCacheLabel()
    }

    @objc private func chooseRepository() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 S-muscriptor 项目文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("muscriptor/__main__.py").path) else {
                let alert = NSAlert()
                alert.messageText = "请选择 MuScriptor 仓库的根目录"
                alert.runModal()
                return
            }
            send(["action": "quit"])
            try? input?.fileHandleForWriting.close()
            output?.fileHandleForReading.readabilityHandler = nil
            helper = nil
            input = nil
            output = nil
            generation = UUID()
            defaults.set(url.path, forKey: "repository")
            update(state: "stopped", message: "已停止", owned: false, canOpen: false)
            launchHelper()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard helper?.isRunning == true else { return .terminateNow }
        quitting = true
        update(state: "stopping", message: "正在停止服务并退出…", owned: true, canOpen: false)
        send(["action": "quit"])
        try? input?.fileHandleForWriting.close()
        return .terminateLater
    }
}

@main
enum MuScriptorControl {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
