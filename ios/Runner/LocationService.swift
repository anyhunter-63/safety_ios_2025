// ios/Runner/LocationService.swift

import Foundation
import CoreLocation
import AVFAudio
import UserNotifications

final class LocationService: NSObject, CLLocationManagerDelegate {

  static let shared = LocationService()

  private let manager = CLLocationManager()
  private var timer: DispatchSourceTimer?
  private var lastLocation: CLLocation?

  private var isRunning = false

  // 주기(초)
  private let intervalSec: Int = 30

  // 음성 플레이어
  private var voicePlayer: AVAudioPlayer?

  // 마지막으로 안내한 거리/레벨(같은 상태 반복 안내 조금 줄이고 싶으면 사용)
  private var lastAnnouncedLevel: String?
  private var lastAnnouncedBucket: String?

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters   // 배터리 아끼기
    manager.distanceFilter = 20                                  // 20m 이상 움직일 때만 업데이트
    manager.allowsBackgroundLocationUpdates = true
    manager.pausesLocationUpdatesAutomatically = true            // 가만히 있으면 iOS가 자동 pause
  }

  // MARK: - Public

  func start() {
    guard !isRunning else { return }
    isRunning = true

    NSLog("[LocationService] start")

    // 권한 상태 보고 적절히 시작
    let status = CLLocationManager.authorizationStatus()
    if status == .notDetermined {
      manager.requestAlwaysAuthorization()
    }

    manager.startUpdatingLocation()
    startTimerIfNeeded()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false

    NSLog("[LocationService] stop")

    stopTimerIfNeeded()
    manager.stopUpdatingLocation()
    lastLocation = nil
    lastAnnouncedLevel = nil
    lastAnnouncedBucket = nil

    stopVoice()
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.last else { return }
    lastLocation = loc
    NSLog("[LocationService] didUpdateLocations: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[LocationService] didFailWithError: \(error.localizedDescription)")
  }

  // MARK: - Timer

  private func startTimerIfNeeded() {
    guard timer == nil else { return }

    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
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
  }

  private func stopTimerIfNeeded() {
    timer?.cancel()
    timer = nil
  }

  // 30초마다 서버 호출 + 음성 안내
  private func tick() {
    guard isRunning else {
      NSLog("[LocationService] tick but not running")
      return
    }

    guard let loc = lastLocation else {
      NSLog("[LocationService] tick but no location yet")
      return
    }

    let lat = loc.coordinate.latitude
    let lng = loc.coordinate.longitude

    NSLog("[LocationService] tick -> call civil_safety_ping: \(lat), \(lng)")

    callSafetyPing(lat: lat, lng: lng)
  }

  // MARK: - Networking: civil_safety_ping.php

  private func callSafetyPing(lat: Double, lng: Double) {
    // deviceId는 iOS 고유값 (간단히 identifierForVendor 사용)
    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "IOS-DEVICE"

    guard let url = URL(string: "https://m.kowildlife.com/BIO/civil_safety_ping.php") else {
      NSLog("[LocationService] invalid URL")
      return
    }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    let bodyStr = "deviceId=\(deviceId)&lat=\(lat)&lng=\(lng)"
    req.httpBody = bodyStr.data(using: .utf8)
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let task = URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
      if let error = error {
        NSLog("[LocationService] ping error: \(error.localizedDescription)")
        return
      }
      guard let data = data else {
        NSLog("[LocationService] ping no data")
        return
      }

      // body 안에 앞뒤로 HTML 섞여 있을 수 있으니 순수 JSON만 추출
      guard let bodyStr = String(data: data, encoding: .utf8) else {
        NSLog("[LocationService] ping body decode error")
        return
      }

      guard let jsonRangeStart = bodyStr.firstIndex(of: "{"),
            let jsonRangeEnd = bodyStr.lastIndex(of: "}") else {
        NSLog("[LocationService] ping no JSON object in body: \(bodyStr)")
        return
      }

      let jsonStr = String(bodyStr[jsonRangeStart...jsonRangeEnd])
      guard let jsonData = jsonStr.data(using: .utf8) else {
        NSLog("[LocationService] ping json string -> data fail")
        return
      }

      do {
        if let dict = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
          self?.handlePingResponse(dict)
        } else {
          NSLog("[LocationService] ping json is not dict")
        }
      } catch {
        NSLog("[LocationService] ping json parse error: \(error.localizedDescription)")
      }
    }

    task.resume()
  }

  private func handlePingResponse(_ data: [String: Any]) {
    // minDistance / distance
    var dist: Int = -1
    if let raw = data["minDistance"] ?? data["distance"] {
      if let v = raw as? Int { dist = v }
      else if let v = raw as? Double { dist = Int(v.rounded()) }
      else if let v = raw as? String, let iv = Int(v) { dist = iv }
    }

    let within150 = parseIntField(data["within150"])
    let within200 = parseIntField(data["within200"])
    let within500 = parseIntField(data["within500"])

    // 거리 기준 레벨 계산 (Dart와 동일)
    var level = "SAFE"
    if dist >= 0 {
      if dist <= 100      { level = "위험" }
      else if dist <= 150 { level = "경계" }
      else if dist <= 200 { level = "주의" }
      else if dist <= 500 { level = "관심" }
      else               { level = "SAFE" }
    }

    NSLog("[LocationService] result dist=\(dist), level=\(level), 150=\(within150), 200=\(within200), 500=\(within500)")

    // 음성 안내 + (선택) 로컬 알림
    DispatchQueue.main.async { [weak self] in
      self?.announce(level: level,
                     dist: dist,
                     within150: within150,
                     within200: within200,
                     within500: within500)
    }
  }

  private func parseIntField(_ raw: Any?) -> Int {
    if let v = raw as? Int { return v }
    if let v = raw as? Double { return Int(v.rounded()) }
    if let s = raw as? String, let iv = Int(s) { return iv }
    return 0
  }

  // MARK: - Announce (음성 + 알림)

  private func announce(level: String, dist: Int, within150: Int, within200: Int, within500: Int) {
    // dist < 0 이면 안내 안 함
    if dist < 0 { return }

    var bucket = "SAFE"

    if dist > 500 {
      bucket = "SAFE"
      playVoice("safe_area")
      // 필요하면 SAFE일 때는 알림 안 띄워도 됨
      return
    }

    if dist <= 150 {
      bucket = "<=150"
      playVoice("danger_150m")
    } else if dist <= 200 {
      bucket = "<=200"
      playVoice("danger_200m")
    } else { // dist <= 500
      bucket = "<=500"
      playVoice("danger_500m")
    }

    lastAnnouncedLevel = level
    lastAnnouncedBucket = bucket

    // 원하면 여기서 로컬 알림도 추가할 수 있음 (지금은 음성만 사용)
  }

  // MARK: - Voice

  private func playVoice(_ filename: String) {
    guard let url = Bundle.main.url(forResource: filename, withExtension: "mp3") else {
      NSLog("[LocationService] mp3 not found: \(filename)")
      return
    }

    do {
      voicePlayer = try AVAudioPlayer(contentsOf: url)
      voicePlayer?.prepareToPlay()
      voicePlayer?.play()
      NSLog("[LocationService] playing: \(filename)")
    } catch {
      NSLog("[LocationService] audio error: \(error.localizedDescription)")
    }
  }

  private func stopVoice() {
    voicePlayer?.stop()
    voicePlayer = nil
  }
}
