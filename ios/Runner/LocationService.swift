// ios/Runner/LocationService.swift

import Foundation
import CoreLocation

final class LocationService: NSObject, CLLocationManagerDelegate {

  static let shared = LocationService()

  private let manager = CLLocationManager()
  private var isRunning = false

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = 20
    manager.allowsBackgroundLocationUpdates = true
    manager.pausesLocationUpdatesAutomatically = true
  }

  // MARK: - Public

  func start() {
    guard !isRunning else { return }
    isRunning = true

    NSLog("[LocationService] start")

    let status = CLLocationManager.authorizationStatus()
    if status == .notDetermined {
      manager.requestAlwaysAuthorization()
    }

    manager.startUpdatingLocation()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false

    NSLog("[LocationService] stop")

    manager.stopUpdatingLocation()
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.last else { return }
    NSLog("[LocationService] didUpdateLocations: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[LocationService] didFailWithError: \(error.localizedDescription)")
  }
}
