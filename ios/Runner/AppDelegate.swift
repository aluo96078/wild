import Flutter
import UIKit
import AVFoundation
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var volumeEventSink: FlutterEventSink?
  private var audioSession: AVAudioSession?
  private var volumeView: MPVolumeView?
  private var silentPlayer: AVAudioPlayer?
  private var previousVolume: Float = 0.5
  private var isObservingVolume = false

  /// HUD 抑制是否已安裝（獨立於事件監聽層）
  private var isHUDSuppressed = false

  /// 音量變化閾值，低於此值視為浮點誤差或重設回彈
  private let volumeThreshold: Float = 0.001

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    let applicationSupportsPath = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
    let controller = self.window?.rootViewController as! FlutterViewController

    let channel = FlutterMethodChannel(name: "methods", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
        Thread {
            if call.method == "dataRoot" {
                result(applicationSupportsPath)
            } else if call.method == "documentRoot" {
               result(documentsPath)
            } else if call.method == "getKeepScreenOn" {
                result(application.isIdleTimerDisabled)
            }
            else if call.method == "setKeepScreenOn" {
                if let args = call.arguments as? Bool {
                    DispatchQueue.main.async { () -> Void in
                        application.isIdleTimerDisabled = args
                    }
                }
                result(NSNull())
            } else if call.method == "reassertAudioSession" {
                self.ensureInfrastructureHealthy()
                result(NSNull())
            } else {
                result(FlutterMethodNotImplemented)
            }
        }.start()
    }

    let volumeChannel = FlutterEventChannel(name: "volume_button", binaryMessenger: controller.binaryMessenger)
    volumeChannel.setStreamHandler(self)

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - HUD 抑制層

  /// 安裝 HUD 抑制：設定 AudioSession + 播放靜音音效 + 安裝 MPVolumeView
  private func installHUDSuppression() {
    guard !isHUDSuppressed else { return }
    isHUDSuppressed = true

    setupAudioSession()
    startSilentPlayback()
    installVolumeView()
    clampVolumeToSafeRange()

    // 監聽 App 回到前景，自動修復可能失效的 HUD 抑制
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  /// 移除 HUD 抑制
  private func removeHUDSuppression() {
    guard isHUDSuppressed else { return }

    stopListening()

    isHUDSuppressed = false
    NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: audioSession)

    silentPlayer?.stop()
    silentPlayer = nil

    let vv = volumeView
    volumeView = nil
    audioSession = nil

    if Thread.isMainThread {
      vv?.removeFromSuperview()
    } else {
      DispatchQueue.main.async { vv?.removeFromSuperview() }
    }
  }

  // MARK: - 事件監聽層

  /// 開始監聽音量變化（進入閱讀器時呼叫）
  private func startListening() {
    if !isHUDSuppressed {
      installHUDSuppression()
    }

    ensureInfrastructureHealthy()

    guard let session = audioSession, !isObservingVolume else { return }

    previousVolume = session.outputVolume
    clampVolumeToSafeRange()

    session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
    isObservingVolume = true
  }

  /// 停止監聯音量變化（離開閱讀器時呼叫）
  private func stopListening() {
    if isObservingVolume {
      audioSession?.removeObserver(self, forKeyPath: "outputVolume")
      isObservingVolume = false
    }
  }

  // MARK: - KVO

  override func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    guard keyPath == "outputVolume",
          let newVolume = change?[.newKey] as? Float else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self, let sink = self.volumeEventSink else { return }

      let delta = newVolume - self.previousVolume

      // 忽略微小變化：重設回彈、浮點誤差
      // 當我們把音量重設回 previousVolume 時，KVO 會再次觸發，
      // 但 delta ≈ 0，自然被忽略，不需要 isResetting flag。
      guard abs(delta) > self.volumeThreshold else { return }

      if delta > 0 {
        sink("UP")
      } else {
        sink("DOWN")
      }

      // 重設回原始音量，確保可連續偵測
      if !self.resetVolume() {
        // 重設失敗（slider 不可用），接受新音量作為基準
        self.previousVolume = newVolume
        self.clampVolumeToSafeRange()
      }
    }
  }

  // MARK: - Private: Setup

  private func setupAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, options: .mixWithOthers)
      try session.setActive(true)
    } catch {}
    audioSession = session
    previousVolume = session.outputVolume

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: session
    )
  }

  private func startSilentPlayback() {
    guard silentPlayer == nil || silentPlayer?.isPlaying == false else { return }
    silentPlayer?.stop()
    if let player = try? AVAudioPlayer(data: makeSilentWavData()) {
      player.numberOfLoops = -1
      player.volume = 0
      player.play()
      silentPlayer = player
    }
  }

  private func installVolumeView() {
    guard volumeView == nil || volumeView?.superview == nil else { return }
    volumeView?.removeFromSuperview()
    let vv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    vv.alpha = 0.01
    if let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) {
      window.addSubview(vv)
    }
    vv.layoutIfNeeded()
    volumeView = vv
  }

  // MARK: - Private: Health Check

  /// 確保所有基礎設施仍然健康（靜音播放器在跑、MPVolumeView 在視窗中）。
  private func ensureInfrastructureHealthy() {
    guard isHUDSuppressed else { return }

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, options: .mixWithOthers)
      try session.setActive(true)
    } catch {}
    audioSession = session

    if silentPlayer == nil || silentPlayer?.isPlaying == false {
      startSilentPlayback()
    }

    if volumeView?.superview == nil {
      installVolumeView()
    }
  }

  // MARK: - Private: Volume Control

  /// 確保音量在安全範圍內（不在邊界 0 或 1），否則某個方向的按鍵不會觸發 KVO。
  private func clampVolumeToSafeRange() {
    let vol = previousVolume
    if vol <= 0.01 || vol >= 0.99 {
      previousVolume = 0.5
      _ = resetVolume()
    }
  }

  /// 透過 MPVolumeView 的 UISlider 將系統音量重設回 previousVolume。
  @discardableResult
  private func resetVolume() -> Bool {
    guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
      return false
    }
    slider.value = previousVolume
    return true
  }

  // MARK: - Notifications

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
    if type == .ended {
      ensureInfrastructureHealthy()
    }
  }

  @objc private func handleDidBecomeActive() {
    ensureInfrastructureHealthy()
  }

  // MARK: - Silent WAV

  /// 產生靜音 WAV 資料（0.1 秒，8000Hz，8-bit mono）
  private func makeSilentWavData() -> Data {
    let sampleRate: UInt32 = 8000
    let dataSize: UInt32 = sampleRate / 10
    var d = Data()
    func appendU32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
    func appendU16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
    d.append(contentsOf: "RIFF".utf8)
    appendU32(36 + dataSize)
    d.append(contentsOf: "WAVE".utf8)
    d.append(contentsOf: "fmt ".utf8)
    appendU32(16)
    appendU16(1)          // PCM
    appendU16(1)          // mono
    appendU32(sampleRate)
    appendU32(sampleRate) // byteRate
    appendU16(1)          // blockAlign
    appendU16(8)          // bitsPerSample
    d.append(contentsOf: "data".utf8)
    appendU32(dataSize)
    d.append(contentsOf: [UInt8](repeating: 0x80, count: Int(dataSize)))
    return d
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    volumeEventSink = events
    startListening()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    volumeEventSink = nil
    removeHUDSuppression()
    return nil
  }
}
