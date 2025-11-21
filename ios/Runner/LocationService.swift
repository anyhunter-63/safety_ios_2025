// ios/Runner/LocationService.swift

import Foundation
import CoreLocation

/// 안전지키미 iOS용 백그라운드 위치 서비스
///
/// - 역할:
///   1) 백그라운드에서도 CLLocationManager를 유지해서
///      iOS가 앱을 쉽게 suspend 하지 않도록 만듦
///   2) 최근 위치를 lastLocation에 계속 보관
///   3) 30초마다 tick()이 불리면서 위치 상태를 체크 (지금은 로그만)
///
/// ⚠️ 실제 civil_safety_ping.php 호출은
///    지금처럼 Dart(main.dart) 쪽 Timer에서 계속 수행하고,
///    이 클래스는 "백그라운드에서 앱을 살려두는 엔진" 역할만 한다.
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
        // 수렵인용과 동일하게 너무 높은 정확도는 피하고, 배터리 절약 모드
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 20  // 20m 이상 이동 시에만 업데이트

        // 백그라운드 위치 업데이트 허용
        manager.allowsBackgroundLocationUpdates = true

        // 가만히 있을 때는 iOS가 알아서 일시 중지 (배터리 절약)
        manager.pausesLocationUpdatesAutomatically = true
    }

    // MARK: - Public 제어 메서드

    /// 스캔 시작 시 Flutter에서 호출해줄 메서드
    func start() {
        NSLog("[LocationService] start() called")

        // 권한 상태 보고 필요하면 요청
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestAlwaysAuthorization()
        }

        // "중요한 위치 변화" 모드로 시작 (저전력 + 백그라운드 유지에 유리)
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

        // ⚠️ 여기에서 civil_safety_ping.php를 직접 호출할 수도 있지만,
        //    현재 구조에서는 Dart(main.dart)의 Timer가 PHP를 호출하고 있으므로
        //    iOS 네이티브는 "프로세스를 살려두는 역할"만 한다.
        //
        //    나중에 정말 필요하면:
        //    - 여기서 URLSession으로 PHP를 직접 호출하거나,
        //    - MethodChannel/EventChannel을 통해 Flutter로 위치를 보내는 코드만 추가하면 됨.
    }
}
