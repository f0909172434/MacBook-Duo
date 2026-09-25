import AppKit
import ScreenCaptureKit
import Carbon
import CoreMedia

// AppKit must not constrain this borderless overlay onto the main display.
private final class DesktopGlassPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// Capture and render are local only. No recordings or network output.
@MainActor
final class GlobalDesktopController: NSObject, @preconcurrency SCStreamOutput, SCStreamDelegate {
    private let model: AppModel
    private weak var setupWindow: NSWindow?
    private var overlay: NSWindow?
    private var renderer: GlassMetalView?
    private var stream: SCStream?
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var generation = 0
    private var starting = false
    private var startedAt = Date()
    private var captureFPS: Int32 = 30
    private var updatingCaptureRate = false
    private var receivedFrame = false
    private var requestedVisible = false
    private var previewUntil = Date.distantPast
    private var previewRequested = false
    private var frameCount = 0
    private var capturedDisplayID: CGDirectDisplayID?
    private var statusLine: NSMenuItem!
    private var statusTick = 0
    private var observers: [NSObjectProtocol] = []
    private var resumeWanted = false
    private var sleepReasons = Set<String>()
    private var recoveryTimer: Timer?
    private var recoveryFailures = 0
    private var nextRecoveryAttempt = Date.distantPast
    private var captureDormant = false
    private var stoppingForDormancy = false
    private var wakingDormantCapture = false
    private var dormantWakeRequested = false
    private var lastHingeMotionAt = CACurrentMediaTime()
    // The setup window is hidden during capture. After wake, on-screen content
    // may omit our process, but the SCApplication from this process remains valid.
    private var captureApplication: SCRunningApplication?

    init(model: AppModel, setupWindow: NSWindow) {
        self.model = model
        self.setupWindow = setupWindow
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "MacBookDuo", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
        }
        statusItem.button?.setAccessibilityLabel("MacBook Duo")
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "尚未启动", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        for (title, action) in [
            ("测试实时效果（8秒）", #selector(preview)),
            ("开启 / 停止全局效果   ⌘⇧G", #selector(toggle)),
            ("保存当前铰链终点   ⌘⇧K", #selector(calibrate)),
            ("打开设置   ⌘⇧Esc", #selector(showSetup)),
            ("修复屏幕录制权限…", #selector(repairPermissions)),
            ("退出 MacBook Duo", #selector(quit))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        registerKeys()
        model.sensor.motionHandler = { [weak self] in
            self?.hingeDidMove()
        }
        // Session activation notifications alone do not cover ordinary screen locking.
        for (name, locked) in [("com.apple.screenIsLocked", true),
                               ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if locked {
                        self.sleepReasons.insert("lock")
                        self.suspend(reason: "屏幕已锁定，解锁后自动恢复")
                    } else {
                        self.sleepReasons.remove("lock")
                        self.recoveryFailures = 0
                        self.nextRecoveryAttempt = .distantPast
                        self.recoverIfReady()
                    }
                }
            })
        }
        for (name, key) in [(NSWorkspace.willSleepNotification, "system"),
                            (NSWorkspace.screensDidSleepNotification, "display"),
                            (NSWorkspace.sessionDidResignActiveNotification, "session")] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.sleepReasons.insert(key)
                        self?.suspend(reason: "已暂停，开盖唤醒后自动恢复")
                    }
                })
        }
        for (name, key) in [(NSWorkspace.didWakeNotification, "system"),
                            (NSWorkspace.screensDidWakeNotification, "display"),
                            (NSWorkspace.sessionDidBecomeActiveNotification, "session")] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.sleepReasons.remove(key)
                        self?.recoverIfReady()
                    }
                })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Retain the texture across Space changes; sleep/session guards
            // prevent the desktop overlay from being drawn over a locked session.
            MainActor.assumeIsolated {
                self?.overlay?.orderOut(nil)
                self?.startedAt = Date()
            }
        })
    }

    @objc func preview() {
        if stream != nil {
            previewUntil = Date().addingTimeInterval(8)
            previewRequested = false
            if captureDormant {
                requestDormantCaptureWake()
            } else if timer == nil {
                resumeRendering()
            }
        } else {
            previewRequested = true
            start()
        }
    }

    @objc private func toggle() {
        if stream != nil || starting || resumeWanted { stop(reason: "全局效果已停止") } else { start() }
    }
    @objc private func calibrate() {
        guard model.sensor.isAvailable else { return }
        // Global mode always calibrates the real hinge, never a preview slider.
        model.useSensor = true
        model.saveOpenAngle()
    }
    @objc func showSetup() {
        stop(reason: "全局效果已停止")
        model.returnToSetup()
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() {
        stop(reason: "已停止")
        NSApp.terminate(nil)
    }

    @objc private func repairPermissions() {
        let alert = NSAlert()
        alert.messageText = "重置 MacBook Duo 的屏幕录制权限？"
        alert.informativeText = "仅在授权异常时使用。将停止实时效果；重置后请退出并重新打开软件，再允许屏幕录制。不会修改其他应用的权限。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "重置本应用权限")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        stop(reason: "正在修复录屏权限")
        model.permissionsPreparing = true
        Task { @MainActor in
            let success = await ScreenCapturePermissionPreparation.reset(userConfirmed: true)
            model.permissionsPreparing = false
            model.globalStatus = success ? "权限已重置，请退出并重新打开软件后授权" : "重置失败，请在系统设置中检查屏幕录制权限"
            statusLine.title = model.globalStatus
        }
    }

    func start(automatically: Bool = false) {
        guard !model.permissionsPreparing else { return }
        guard !starting && stream == nil else { return }
        guard !hotKeys.isEmpty else {
            model.globalStatus = "紧急停止快捷键注册失败，未启用覆盖层"
            return
        }
        guard model.sensor.isAvailable else {
            model.globalStatus = "没有可用的真实铰链传感器，请使用截图测试模式"
            return
        }
        if !automatically {
            recoveryFailures = 0
            nextRecoveryAttempt = .distantPast
        }
        resumeWanted = true
        guard sleepReasons.isEmpty else {
            suspend(reason: "等待屏幕唤醒后自动恢复")
            return
        }
        starting = true
        generation += 1
        let token = generation
        model.globalStatus = "正在请求桌面捕获；如出现系统提示，请允许屏幕录制"
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard token == generation else { return }
                // Target the built-in panel. External displays aren't hinge-driven.
                guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
                      let screen = NSScreen.screens.first(where: {
                          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                      }) else { throw GlobalError.noInternalDisplay }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                if let application = content.applications.first(where: { $0.processID == ownPID }) {
                    captureApplication = application
                }
                guard let application = captureApplication, application.processID == ownPID else {
                    throw GlobalError.cannotExcludeSelf
                }
                let excluded = [application]
                let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                let config = SCStreamConfiguration()
                // Logical resolution for prototype power budget; native panel output.
                config.width = Int(screen.frame.width)
                config.height = Int(screen.frame.height)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 3
                config.showsCursor = false
                config.capturesAudio = false
                let renderer = self.renderer ?? GlassMetalView()
                guard renderer.device != nil else { throw GlobalError.noGPU }
                let overlay = (self.overlay as? DesktopGlassPanel) ?? DesktopGlassPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
                overlay.hidesOnDeactivate = false
                overlay.becomesKeyOnlyIfNeeded = true
                overlay.isReleasedWhenClosed = false
                overlay.backgroundColor = .black
                overlay.hasShadow = false
                overlay.ignoresMouseEvents = true
                // A nonactivating panel may join other applications' native
                // fullscreen spaces without taking their keyboard focus.
                // Include Dock/Launchpad, menu bar and ordinary pop-up menus in
                // the live composite. Keep below screen saver/security surfaces.
                // Mouse events still pass through; global emergency keys remain.
                overlay.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
                overlay.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                              .fullScreenAuxiliary, .stationary, .ignoresCycle]
                overlay.contentView = renderer
                overlay.setFrame(screen.frame, display: false)
                self.renderer = renderer
                self.overlay = overlay
                capturedDisplayID = display.displayID
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                self.stream = stream
                captureDormant = false
                stoppingForDormancy = false
                wakingDormantCapture = false
                dormantWakeRequested = false
                model.sensor.setLowPowerPollingEnabled(false)
                captureFPS = 30
                updatingCaptureRate = false
                frameCount = 0
                model.sensor.setUIMotionUpdatesEnabled(false)
                setupWindow?.orderOut(nil)
                NSApp.presentationOptions = []
                startedAt = Date()
                if !automatically { receivedFrame = false }
                try await stream.startCapture()
                guard token == generation else {
                    try? await stream.stopCapture()
                    return
                }
                starting = false
                if !sleepReasons.isEmpty {
                    suspend(reason: "保留画面，等待开盖继续")
                    return
                }
                recoveryTimer?.invalidate()
                recoveryTimer = nil
                if previewRequested {
                    previewUntil = Date().addingTimeInterval(8)
                    previewRequested = false
                }
                model.globalRunning = true
                model.globalStatus = "实时桌面已启用 · ⌘⇧Esc 停止并恢复设置"
                statusItem.button?.toolTip = model.globalStatus
                NSLog("Global capture started")
                resumeRendering()
            } catch {
                guard token == generation else { return }
                let failedStream = self.stream
                self.stream = nil
                starting = false
                if let failedStream { Task { try? await failedStream.stopCapture() } }
                if automatically || !sleepReasons.isEmpty {
                    recoveryFailures += 1
                    nextRecoveryAttempt = Date().addingTimeInterval(LiveEffectPolicy.retryDelay(failures: recoveryFailures))
                    suspend(reason: "等待解锁或桌面捕获恢复：\(error.localizedDescription)")
                    return
                }
                stop(reason: "无法启动：\(error.localizedDescription)。请检查系统设置 → 隐私与安全性 → 屏幕录制权限。")
                setupWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func suspend(reason: String) {
        guard resumeWanted || stream != nil || starting else { return }
        // Suspension must not destroy the window, GPU textures, or healthy stream.
        timer?.invalidate()
        timer = nil
        renderer?.isPaused = true
        overlay?.orderOut(nil)
        model.globalRunning = true
        model.globalStatus = reason
        statusLine?.title = reason
        NSLog("Global suspended (resources retained): %@", reason)
        if recoveryTimer == nil {
            let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverIfReady() }
            }
            recoveryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func recoverIfReady() {
        // On some clamshell wake cycles the panel is already lit several
        // seconds before macOS posts its full system-wake notification. The
        // old capture is gone by then, but its last complete Metal texture is
        // still valid. Animate that retained texture as soon as the display,
        // session and hinge sensor are usable; a fresh capture replaces it
        // after FullWake. Lock/session guards keep stale desktop content off
        // security surfaces.
        resumeRetainedWakeFrameIfReady()
        guard resumeWanted, sleepReasons.isEmpty, !starting,
              Date() >= nextRecoveryAttempt,
              !model.permissionsPreparing, model.sensor.isAvailable,
              Date().timeIntervalSince(model.sensor.lastSuccessfulUpdate) < 0.5,
              NSScreen.screens.contains(where: {
                  guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
                  return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
              }) else { return }
        if stream != nil {
            recoveryTimer?.invalidate()
            recoveryTimer = nil
            startedAt = Date()
            if captureDormant {
                let remaining = LiveEffectPolicy.remaining(angle: model.sensor.angle, velocity: model.sensor.velocity,
                                                           endpoint: model.openAngle, preview: Date() < previewUntil)
                if remaining > 0.008 || requestedVisible || overlay?.isVisible == true {
                    requestDormantCaptureWake()
                }
            } else {
                resumeRendering()
            }
            model.globalStatus = "开盖继续显示 · 窗口与画面已保留"
            NSLog("Global resumed using existing stream and renderer")
            return
        }
        // Wake recovery must never open a fresh permission prompt by itself.
        guard CGPreflightScreenCaptureAccess() else {
            nextRecoveryAttempt = Date().addingTimeInterval(5)
            suspend(reason: "等待屏幕录制权限恢复；若权限已撤销，请到系统设置重新允许")
            return
        }
        start(automatically: true)
    }

    private func resumeRetainedWakeFrameIfReady() {
        guard LiveEffectPolicy.canRenderRetainedWakeFrame(sleepReasons: sleepReasons),
              resumeWanted, !starting,
              !model.permissionsPreparing, model.sensor.isAvailable,
              Date().timeIntervalSince(model.sensor.lastSuccessfulUpdate) < 0.5,
              receivedFrame, let renderer, renderer.readyForDisplay,
              let overlay, let id = capturedDisplayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
              }), CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) != 0,
              overlay.frame == screen.frame else { return }
        let remaining = LiveEffectPolicy.remaining(angle: model.sensor.angle, velocity: model.sensor.velocity,
                                                   endpoint: model.openAngle, preview: Date() < previewUntil)
        guard remaining > 0.008 else { return }
        requestedVisible = true
        renderer.setLiveAngle(remaining * 80)
        if timer == nil { resumeRendering() }
        if !overlay.isVisible { overlay.orderFrontRegardless() }
    }

    private func resumeRendering() {
        renderer?.isPaused = false
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        update()
    }

    private func hingeDidMove() {
        lastHingeMotionAt = CACurrentMediaTime()
        guard resumeWanted else { return }
        if !sleepReasons.isEmpty {
            recoverIfReady()
            return
        }
        if captureDormant {
            requestDormantCaptureWake()
        } else if timer == nil {
            resumeRendering()
        }
    }

    private func enterDormantCapture() {
        guard !captureDormant, !stoppingForDormancy, !wakingDormantCapture, let stream else { return }
        captureDormant = true
        stoppingForDormancy = true
        dormantWakeRequested = false
        timer?.invalidate()
        timer = nil
        renderer?.isPaused = true
        Task { @MainActor in
            do {
                try await stream.stopCapture()
                guard self.stream === stream, captureDormant else { return }
                stoppingForDormancy = false
                if dormantWakeRequested {
                    wakeDormantCapture()
                } else {
                    model.sensor.setLowPowerPollingEnabled(true)
                    NSLog("Global capture dormant while hinge is stable")
                }
            } catch {
                guard self.stream === stream else { return }
                captureDormant = false
                stoppingForDormancy = false
                dormantWakeRequested = false
                NSLog("Failed to enter dormant capture: %@", error.localizedDescription)
                resumeRendering()
            }
        }
    }

    private func requestDormantCaptureWake() {
        guard captureDormant else { return }
        model.sensor.setLowPowerPollingEnabled(false)
        dormantWakeRequested = true
        if !stoppingForDormancy { wakeDormantCapture() }
    }

    private func wakeDormantCapture() {
        guard captureDormant, !stoppingForDormancy, !wakingDormantCapture, let stream else { return }
        model.sensor.setLowPowerPollingEnabled(false)
        dormantWakeRequested = false
        captureDormant = false
        wakingDormantCapture = true
        receivedFrame = false
        startedAt = Date()
        Task { @MainActor in
            do {
                try await stream.startCapture()
                guard self.stream === stream else { return }
                wakingDormantCapture = false
                captureFPS = 30
                NSLog("Global dormant capture restarted")
            } catch {
                guard self.stream === stream else { return }
                wakingDormantCapture = false
                self.stream = nil
                recoveryFailures += 1
                nextRecoveryAttempt = Date().addingTimeInterval(LiveEffectPolicy.retryDelay(failures: recoveryFailures))
                suspend(reason: "等待桌面捕获从节能状态恢复：\(error.localizedDescription)")
            }
        }
    }

    func stop(reason: String, preserveIntent: Bool = false) {
        if !preserveIntent {
            resumeWanted = false
            recoveryTimer?.invalidate()
            recoveryTimer = nil
        }
        generation += 1
        starting = false
        captureDormant = false
        stoppingForDormancy = false
        wakingDormantCapture = false
        dormantWakeRequested = false
        model.sensor.setLowPowerPollingEnabled(false)
        overlay?.orderOut(nil)
        overlay = nil
        renderer = nil
        capturedDisplayID = nil
        timer?.invalidate()
        timer = nil
        let oldStream = stream
        stream = nil
        if let oldStream { Task { try? await oldStream.stopCapture() } }
        receivedFrame = false
        requestedVisible = false
        previewRequested = false
        previewUntil = .distantPast
        model.globalRunning = preserveIntent
        model.globalStatus = reason
        statusItem?.button?.toolTip = reason
        statusItem?.button?.title = preserveIntent ? " 待" : " 停"
        statusLine?.title = reason
        NSLog("Global stopped: %@", reason)
    }

    func screenConfigurationChanged() {
        // Menu/Dock visibility also posts screen-parameter notifications.
        // Only stop for a real change to the captured display or its full frame.
        guard let id = capturedDisplayID, let overlay else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if screen == nil || screen!.frame != overlay.frame {
            overlay.orderOut(nil)
            generation += 1
            starting = false
            let oldStream = stream
            stream = nil
            receivedFrame = false
            if let oldStream { Task { try? await oldStream.stopCapture() } }
            if let screen {
                overlay.setFrame(screen.frame, display: false)
            }
            suspend(reason: "内建显示器变化，等待恢复实时效果")
        }
    }

    private func update() {
        // Rendering a retained, already-captured texture is safe while the
        // system-wake reason is still pending. Display/session/lock reasons
        // continue to block the overlay entirely.
        guard !sleepReasons.contains("display"),
              !sleepReasons.contains("session"),
              !sleepReasons.contains("lock") else { return }
        guard let renderer, let overlay else { return }
        guard let id = capturedDisplayID,
              let targetScreen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
              }), CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) != 0 else {
            screenConfigurationChanged()
            suspend(reason: "等待 MacBook 内建屏幕恢复")
            return
        }
        if overlay.frame != targetScreen.frame {
            screenConfigurationChanged()
            return
        }
        if Date().timeIntervalSince(model.sensor.lastSuccessfulUpdate) > 2 {
            suspend(reason: "等待铰链数据恢复后自动继续")
            return
        }
        if !receivedFrame && Date().timeIntervalSince(startedAt) > 8 {
            let stalledStream = stream
            stream = nil
            if let stalledStream { Task { try? await stalledStream.stopCapture() } }
            nextRecoveryAttempt = Date().addingTimeInterval(2)
            suspend(reason: "等待唤醒后的桌面画面，正在重新连接")
            return
        }
        // A static desktop may legitimately produce no new complete frames.
        // Keep the last valid texture; explicit stream errors still stop immediately.
        let remaining = LiveEffectPolicy.remaining(angle: model.sensor.angle, velocity: model.sensor.velocity,
                                                   endpoint: model.openAngle, preview: Date() < previewUntil)
        if sleepReasons.isEmpty {
            updateCaptureRate(LiveEffectPolicy.captureFPS(remaining: remaining, velocity: model.sensor.velocity), screen: targetScreen)
        }
        renderer.setLiveAngle(remaining * 80)
        // Hysteresis prevents overlay flicker near the calibrated endpoint.
        if remaining > 0.008 { requestedVisible = true }
        if remaining == 0 && renderer.settled { requestedVisible = false }
        if requestedVisible && receivedFrame && renderer.readyForDisplay {
            if !overlay.isVisible { overlay.orderFrontRegardless() }
        } else if overlay.isVisible {
            overlay.orderOut(nil)
        }
        if sleepReasons.isEmpty, captureFPS == 2,
           LiveEffectPolicy.shouldEnterDormantCapture(
               remaining: remaining, velocity: model.sensor.velocity, settled: renderer.settled,
               overlayVisible: overlay.isVisible, previewActive: Date() < previewUntil,
               secondsSinceMotion: CACurrentMediaTime() - lastHingeMotionAt
           ) {
            enterDormantCapture()
            return
        }
        statusTick += 1
        if statusTick % 30 == 0 {
            let state = overlay.isVisible ? "效果显示中" : "原桌面"
            statusItem.button?.title = " \(Int(model.sensor.angle))°"
            statusLine.title = "\(state) · 已捕获 \(frameCount) 帧 · 终点 \(Int(model.openAngle))°"
            if statusTick % 120 == 0 { NSLog("%@", statusLine.title) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .screen, sampleBuffer.isValid else { return }
        guard sleepReasons.isEmpty else { return }
        guard !captureDormant else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderer?.receive(buffer)
        recoveryFailures = 0
        receivedFrame = true
        frameCount += 1
        if wakingDormantCapture {
            wakingDormantCapture = false
        }
        if timer == nil && resumeWanted { resumeRendering() }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            model.sensor.setLowPowerPollingEnabled(false)
            self.stream = nil
            recoveryFailures += 1
            nextRecoveryAttempt = Date().addingTimeInterval(LiveEffectPolicy.retryDelay(failures: recoveryFailures))
            suspend(reason: "捕获暂时中断，解锁后自动重试：\(error.localizedDescription)")
        }
    }

    private func updateCaptureRate(_ fps: Int32, screen: NSScreen) {
        guard fps != captureFPS, !updatingCaptureRate, let stream else { return }
        updatingCaptureRate = true
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width)
        config.height = Int(screen.frame.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        Task { @MainActor in
            do {
                try await stream.updateConfiguration(config)
                guard self.stream === stream else { return }
                captureFPS = fps
            } catch {
                // Keep the functioning stream if a power-saving update fails.
                guard self.stream === stream else { return }
                captureFPS = fps
                NSLog("Capture rate update failed: %@", error.localizedDescription)
            }
            updatingCaptureRate = false
        }
    }

    private func registerKeys() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let controller = Unmanaged<GlobalDesktopController>.fromOpaque(pointer).takeUnretainedValue()
            switch id.id {
            case 1: controller.showSetup()
            case 2: controller.toggle()
            case 3: controller.calibrate()
            default: break
            }
            return noErr
        }, 1, &event, pointer, &eventHandler)
        for (id, code) in [(UInt32(1), UInt32(kVK_Escape)), (2, UInt32(kVK_ANSI_G)), (3, UInt32(kVK_ANSI_K))] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(cmdKey | shiftKey),
                EventHotKeyID(signature: 0x48474C53, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { hotKeys.append(ref) }
            else if id == 1 { break } // Never start without an emergency exit.
        }
    }

    enum GlobalError: LocalizedError {
        case noInternalDisplay, cannotExcludeSelf, noGPU
        var errorDescription: String? {
            switch self {
            case .noInternalDisplay: return "未找到内建显示屏"
            case .cannotExcludeSelf: return "无法排除自身窗口，为避免重复捕获已取消"
            case .noGPU: return "Metal 不可用"
            }
        }
    }
}
