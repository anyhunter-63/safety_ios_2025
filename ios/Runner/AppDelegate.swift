import UIKit
import Flutter
import CoreLocation
import AVFAudio

// MARK: - 안전지키미용 백그라운드 Location 엔진
//
//  - iOS에서 화면이 꺼져도, 홈으로 나가도
//    위치 서비스 + 타이머를 유지해서 앱이 쉽게 죽지 않도록 해주는 역할
//  - civil_safety_ping.php 호출은 여기가 아니라 Flutter(Dart) 쪽에서만 수행
final class LocationService: NSObject, CLLocationManagerDelegate {

  static let shared = LocationService()

  private let manager = CLLocationManager()
  private var timer: DispatchSourceTimer?
  private var lastLocation: CLLocation?

  /// 30초 주기
  private let intervalSec: Int = 30

  private override init() {
    super.init()

    manager.delegate = self
    // 수렵인용과 유사한 저전력 설정
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = 20

    // 백그라운드 위치 허용 (Info.plist에 UIBackgroundModes / Always 권한 필수)
    manager.allowsBackgroundLocationUpdates = true

    // 가만히 있으면 iOS가 알아서 일시중지해서 배터리 절약
    manager.pausesLocationUpdatesAutomatically = true
  }

  // MARK: - Public 제어 메서드

  /// 스캔 시작 시 Flutter에서 호출해줄 메서드
  func start() {
    NSLog("[LocationService] start() called")

    let status = manager.authorizationStatus
    if status == .notDetermined {
      manager.requestAlwaysAuthorization()
    }

    // 저전력 + BG 유지에 유리한 significant-change 모드
    manager.startMonitoringSignificantLocationChanges()

    startTimerIfNeeded()
  }

  /// 스캔 중지 시 Flutter에서 호출해줄 메서드
  func stop() {
    NSLog("[LocationService] stop() called")

    stopTimerIfNeeded()
    manager.stopMonitoringSignificantLocationChanges()
    lastLocation = nil
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.last else { return }
    lastLocation = loc
    NSLog("[LocationService] didUpdateLocations lat=\(loc.coordinate.latitude), lng=\(loc.coordinate.longitude)")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[LocationService] didFailWithError: \(error.localizedDescription)")
  }

  // MARK: - Timer

  private func startTimerIfNeeded() {
    guard timer == nil else { return }

    let queue = DispatchQueue.global(qos: .background)
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(
      deadline: .now() + .seconds(intervalSec),
      repeating: .seconds(intervalSec),
      leeway: .seconds(1)
    )
    t.setEventHandler { [weak self] in
      self?.tick()
    }
    t.resume()
    timer = t

    NSLog("[LocationService] timer started (interval \(intervalSec)s)")
  }

  private func stopTimerIfNeeded() {
    if let t = timer {
      t.cancel()
      timer = nil
      NSLog("[LocationService] timer stopped")
    }
  }

  /// 30초마다 호출되는 곳 (지금은 위치 유무만 체크하고 로그만 찍음)
  private func tick() {
    guard let loc = lastLocation else {
      NSLog("[LocationService] tick() but no lastLocation yet")
      return
    }

    NSLog("[LocationService] tick() lat=\(loc.coordinate.latitude), lng=\(loc.coordinate.longitude)")

    // ⚠️ 여기서 civil_safety_ping.php를 직접 호출하지 않는다.
    //    실제 서버 호출은 Dart(main.dart)의 Timer가 단독으로 수행.
  }
}

// MARK: - AppDelegate

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
      //  - startService → LocationService.start()
      //  - stopService  → LocationService.stop()
      let nativeServiceChannel = FlutterMethodChannel(
        name: nativeServiceChannelName,
        binaryMessenger: controller.binaryMessenger
      )

      nativeServiceChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "startService":
          NSLog("native_service startService → LocationService.start()")
          LocationService.shared.start()
          result(true)

        case "stopService":
          NSLog("native_service stopService → LocationService.stop()")
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
      try session.setCategory(.playback, options: [.mixWithOthers])
      try session.setActive(true)
      NSLog("Audio session configured for background playback")
    } catch {
      NSLog("Audio session error: \(error.localizedDescription)")
    }
  }
}
