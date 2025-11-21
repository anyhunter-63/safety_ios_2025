// ios/Runner/AppDelegate.swift

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

    // 플러터 플러그인 등록
    GeneratedPluginRegistrant.register(with: self)

    // ✅ 백그라운드 오디오 세션 설정 (무음이어도 세션이 살아있어야 안정적)
    configureAudioSession()

    // ✅ Flutter <-> iOS 브릿지 채널 (안전지키미용)
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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Audio Session (백그라운드 유지용)

  private func configureAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      // playback + mixWithOthers 로 백그라운드 오디오 유지
      try session.setCategory(.playback, options: [.mixWithOthers])
      try session.setActive(true)
      NSLog("[AppDelegate] Audio session configured for background playback")
    } catch {
      NSLog("[AppDelegate] Audio session error: \(error.localizedDescription)")
    }
  }
}
