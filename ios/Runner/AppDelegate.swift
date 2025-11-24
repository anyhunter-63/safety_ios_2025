import UIKit
import Flutter
import AVFAudio

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {

  // 🔹 안전지키미에서 사용하는 네이티브 서비스 채널 (Android와 동일 이름)
  private let nativeServiceChannelName = "com.civilsafety.app/native_service"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // 1) 플러터 플러그인 등록
    GeneratedPluginRegistrant.register(with: self)

    // 2) 오디오 세션 먼저 구성 (TTS 포함 전체 오디오 공통 세팅)
    configureAudioSession()

    // 3) FlutterAppDelegate 기본 처리
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // 4) Flutter <-> iOS 브릿지 채널 (안전지키미용)
    if let controller = window?.rootViewController as? FlutterViewController {

      // Android에서 쓰는 native_service 채널을 iOS에서도 구현
      let nativeServiceChannel = FlutterMethodChannel(
        name: nativeServiceChannelName,
        binaryMessenger: controller.binaryMessenger
      )

      nativeServiceChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "startService":
          NSLog("[native_service] startService -> LocationService.start()")
          LocationService.shared.start()
          result(true)

        case "stopService":
          NSLog("[native_service] stopService -> LocationService.stop()")
          LocationService.shared.stop()
          result(true)

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return result
  }

  // MARK: - Audio Session (백그라운드 유지 + TTS 최적화)

  private func configureAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      // 🔊 TTS(음성안내)에 맞게 spokenAudio 모드 사용
      try session.setCategory(.playback,
                              mode: .spokenAudio,
                              options: [.mixWithOthers])
      try session.setActive(true)
      NSLog("[AppDelegate] Audio session configured for background playback + spokenAudio")
    } catch {
      NSLog("[AppDelegate] Audio session error: \(error.localizedDescription)")
    }
  }
}
