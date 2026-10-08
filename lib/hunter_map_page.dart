import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geomag/geomag.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class HunterMapPage extends StatefulWidget {
  const HunterMapPage({
    super.key,
    required this.deviceId,
  });

  final String deviceId;

  @override
  State<HunterMapPage> createState() => _HunterMapPageState();
}

class _HunterMapPageState extends State<HunterMapPage> {
  static const Duration _refreshInterval = Duration(seconds: 5);
  static const Duration _recenterDelay = Duration(seconds: 10);
  static const double _defaultZoom = 15.5;
  static const double _zoomStep = 0.5;

  // 이동방향/정지방향 전환 기준.
  static const double _movingEnterSpeedMps = 1.2; // 약 4.3km/h
  static const double _movingExitSpeedMps = 0.6;  // 약 2.2km/h
  static const Duration _stationaryConfirmDuration = Duration(seconds: 4);

  final MapController _mapController = MapController();

  Timer? _timer;
  Timer? _recenterTimer;
  StreamSubscription<CompassEvent>? _compassSub;

  LatLng? _myPosition;
  List<_HunterPoint> _hunters = const [];

  bool _loading = true;
  bool _refreshing = false;
  bool _mapReady = false;

  String _statusText = '현재 위치를 확인하고 있습니다.';
  DateTime? _lastUpdated;

  // 사용자가 조절한 줌은 자동 갱신으로 덮어쓰지 않는다.
  double _currentZoom = _defaultZoom;

  // 사용자가 지도를 이동한 경우 10초 동안 자동 중심이동을 막는다.
  bool _userPanning = false;

  // Heading-up 상태.
  bool _usingMovementHeading = false;
  DateTime? _slowMotionSince;
  double _compassHeading = 0.0;
  double _movementHeading = 0.0;
  double _mapHeading = 0.0;

  // 정지 상태 Compass의 자기북 -> 진북 보정.
  final GeoMag _geoMag = GeoMag();
  double _magneticDeclination = 0.0;

  double? _declinationLat;
  double? _declinationLng;

  @override
  void initState() {
    super.initState();

    _startCompass();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startRealtimeMap();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recenterTimer?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  Future<void> _startRealtimeMap() async {
    await _refresh();

    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) {
      _refresh();
    });
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) {
        setState(() {
          _loading = false;
          _statusText = '휴대폰의 위치 서비스를 켜 주세요.';
        });
      }
      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() {
          _loading = false;
          _statusText = '지도보기를 사용하려면 위치 권한이 필요합니다.';
        });
      }
      return false;
    }

    return true;
  }

  void _updateMagneticDeclination(Position pos) {
    // 자기편차는 짧은 거리에서는 거의 변하지 않으므로
    // 최초 1회 또는 1km 이상 이동했을 때만 다시 계산한다.
    if (_declinationLat != null && _declinationLng != null) {
      final moved = Geolocator.distanceBetween(
        _declinationLat!,
        _declinationLng!,
        pos.latitude,
        pos.longitude,
      );

      if (moved < 1000.0) {
        return;
      }
    }

    try {
      // geomag의 고도 단위는 feet.
      final heightFeet =
          pos.altitude.isFinite ? pos.altitude * 3.280839895 : 0.0;

      final result = _geoMag.calculate(
        pos.latitude,
        pos.longitude,
        heightFeet,
        DateTime.now(),
      );

      _magneticDeclination = result.dec;
      _declinationLat = pos.latitude;
      _declinationLng = pos.longitude;
    } catch (e) {
      debugPrint('⚠️ magnetic declination update failed: $e');
      _magneticDeclination = 0.0;
    }
  }

  double _normalizeMapHeading(double bearingDegrees) {
    if (!bearingDegrees.isFinite) return _mapHeading;

    // 진행방향이 화면 위쪽을 향하도록 지도는 반대 방향으로 회전.
    return (((-bearingDegrees) % 360) + 360) % 360;
  }

  double _headingDelta(double a, double b) {
    var delta = (a - b).abs();
    if (delta > 180) delta = 360 - delta;
    return delta;
  }

  void _updateMovementHeading(Position pos) {
    final speed = pos.speed.isFinite && pos.speed > 0 ? pos.speed : 0.0;
    final now = DateTime.now();

    if (!_usingMovementHeading) {
      if (speed >= _movingEnterSpeedMps) {
        _usingMovementHeading = true;
        _slowMotionSince = null;
      }
    } else {
      if (speed <= _movingExitSpeedMps) {
        _slowMotionSince ??= now;

        if (now.difference(_slowMotionSince!) >=
            _stationaryConfirmDuration) {
          _usingMovementHeading = false;
          _slowMotionSince = null;
          _mapHeading = _compassHeading;
        }
      } else {
        _slowMotionSince = null;
      }
    }

    if (_usingMovementHeading && pos.heading.isFinite) {
      final next = _normalizeMapHeading(pos.heading);

      if (_movementHeading == 0.0 ||
          _headingDelta(next, _movementHeading) >= 1.0) {
        _movementHeading = next;
      }

      _mapHeading = _movementHeading;
    } else {
      _mapHeading = _compassHeading;
    }

    _applyMapHeading();
  }

  double _blendAngles(
    double a,
    double b,
    double t,
  ) {
    final clamped = t.clamp(0.0, 1.0);
    final delta = ((b - a + 540.0) % 360.0) - 180.0;
    return (a + delta * clamped + 360.0) % 360.0;
  }


  void _startCompass() {
    _compassSub = FlutterCompass.events?.listen((event) {
      final magneticHeading = event.heading;

      if (magneticHeading == null || magneticHeading.isNaN) {
        return;
      }

      // 자기북 방향에 자기편차를 더해
      // 진북 기준으로 변환한다.
      final trueBearing =
          magneticHeading + _magneticDeclination;
      final next = _normalizeMapHeading(trueBearing);

      // 정지상태의 나침반 미세 떨림 억제.
      if (_headingDelta(next, _compassHeading) < 2.0) {
        return;
      }

      _compassHeading = next;

      // 이동 중에는 GPS 실제 진행방향이 우선이다.
      if (!_usingMovementHeading) {
        _mapHeading = _compassHeading;
        _applyMapHeading();
      }
    });
  }

  void _applyMapHeading() {
    if (!_mapReady) return;

    try {
      _mapController.rotate(_mapHeading);
    } catch (_) {}
  }

  void _scheduleRecenter() {
    _recenterTimer?.cancel();

    _userPanning = true;

    _recenterTimer = Timer(_recenterDelay, () {
      if (!mounted) return;

      _userPanning = false;

      final myPos = _myPosition;
      if (myPos == null || !_mapReady) return;

      // 사용자가 선택한 줌은 그대로 두고 중심만 현재 위치로 복귀.
      try {
        _mapController.move(myPos, _currentZoom);
        _applyMapHeading();
      } catch (_) {}
    });
  }

  void _zoomIn() {
    if (!_mapReady) return;

    try {
      final camera = _mapController.camera;
      final nextZoom = (camera.zoom + _zoomStep).clamp(5.0, 19.0);

      _currentZoom = nextZoom;
      _mapController.move(camera.center, nextZoom);
    } catch (_) {}
  }

  void _zoomOut() {
    if (!_mapReady) return;

    try {
      final camera = _mapController.camera;
      final nextZoom = (camera.zoom - _zoomStep).clamp(5.0, 19.0);

      _currentZoom = nextZoom;
      _mapController.move(camera.center, nextZoom);
    } catch (_) {}
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;

    try {
      final allowed = await _ensureLocationPermission();
      if (!allowed) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final myPos = LatLng(pos.latitude, pos.longitude);

      _updateMagneticDeclination(pos);
      _updateMovementHeading(pos);

      final uri = Uri.parse(
        'https://m.kowildlife.com/BIO/civil_safety_ping.php',
      );

      final response = await http
          .post(
            uri,
            body: {
              'deviceId': widget.deviceId,
              'lat': pos.latitude.toString(),
              'lng': pos.longitude.toString(),
              // 지도만 열었을 때는 CIVIL_GPS_LOG에 별도 저장하지 않음.
              'mapOnly': '1',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final body = response.body.trim();
      final start = body.indexOf('{');
      final end = body.lastIndexOf('}');

      if (start < 0 || end <= start) {
        throw const FormatException('JSON 응답을 찾을 수 없습니다.');
      }

      final decoded = jsonDecode(body.substring(start, end + 1));
      final list =
          decoded is Map<String, dynamic> ? decoded['hunters'] : null;

      final hunters = <_HunterPoint>[];

      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;

          final lat = _toDouble(item['lat']);
          final lng = _toDouble(item['lng']);
          final distance = _toInt(item['distance']);

          if (lat == null || lng == null) continue;
          if (lat.abs() > 90 || lng.abs() > 180) continue;

          hunters.add(
            _HunterPoint(
              position: LatLng(lat, lng),
              distance: distance,
            ),
          );
        }
      }

      hunters.sort((a, b) => a.distance.compareTo(b.distance));

      if (!mounted) return;

      final firstFix = _myPosition == null;

      setState(() {
        _myPosition = myPos;
        _hunters = hunters;
        _lastUpdated = DateTime.now();
        _loading = false;
        _statusText = hunters.isEmpty
            ? '1km 이내 확인된 엽사가 없습니다.'
            : '1km 이내 엽사 ${hunters.length}명';
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_mapReady) return;

        /*
         * 최초 위치 확인 때만 기본 중심/배율을 적용한다.
         *
         * 이후 5초 갱신에서는:
         * - 사용자가 확대/축소한 배율을 절대 초기화하지 않는다.
         * - 사용자가 지도를 이동하지 않은 경우만 현재 위치를 따라간다.
         * - 사용자가 이동했다면 10초 후에만 현재 위치로 복귀한다.
         */
        if (firstFix) {
          _mapController.move(myPos, _currentZoom);
          _applyMapHeading();
          return;
        }

        if (!_userPanning) {
          _mapController.move(myPos, _currentZoom);
          _applyMapHeading();
        }
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _statusText = '주변 위치 정보를 갱신하지 못했습니다.';
      });

      debugPrint('❌ hunter map refresh error: $e');
    } finally {
      _refreshing = false;
    }
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? -1;
  }

  String _distanceText(int distance) {
    if (distance < 0) return '';
    if (distance < 1000) return '${distance}m';
    return '${(distance / 1000).toStringAsFixed(1)}km';
  }

  Color _hunterColor(int distance) {
    if (distance >= 0 && distance <= 150) return Colors.red.shade700;
    if (distance >= 0 && distance <= 200) return Colors.orange.shade700;
    if (distance >= 0 && distance <= 500) return Colors.amber.shade800;
    return Colors.deepOrange.shade400;
  }

  @override
  Widget build(BuildContext context) {
    final myPosition = _myPosition;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '주변 수렵인 지도',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _refreshing ? null : _refresh,
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            color: Colors.white,
            child: Row(
              children: [
                const Icon(
                  Icons.my_location,
                  size: 18,
                  color: Colors.blue,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _statusText,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_lastUpdated != null)
                  Text(
                    '${_lastUpdated!.hour.toString().padLeft(2, '0')}:'
                    '${_lastUpdated!.minute.toString().padLeft(2, '0')}:'
                    '${_lastUpdated!.second.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                if (myPosition != null)
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: myPosition,
                      initialZoom: _defaultZoom,
                      minZoom: 5,
                      maxZoom: 19,

                      /*
                       * hasGesture=true인 경우에만 사용자 조작으로 본다.
                       * 자동 move()/rotate()는 사용자 확대/이동 상태를 건드리지 않는다.
                       */
                      onPositionChanged: (camera, hasGesture) {
                        _mapReady = true;

                        if (!hasGesture) return;

                        final previousZoom = _currentZoom;
                        _currentZoom = camera.zoom;

                        /*
                         * 줌 변화만 있으면 배율만 기억한다.
                         * 확대/축소했다고 해서 10초 후 원래 배율로 돌리지 않는다.
                         */
                        final zoomChanged =
                            (camera.zoom - previousZoom).abs() > 0.001;

                        if (!zoomChanged) {
                          // 사용자가 지도를 드래그한 경우만 10초 복귀 타이머 시작.
                          _scheduleRecenter();
                        }
                      },

                      onMapReady: () {
                        _mapReady = true;
                        _applyMapHeading();
                      },
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.civilsafety.app',
                      ),
                      CircleLayer(
                        circles: [
                          // 안전지키미 거리 가늠용 원.
                          // 배경은 최대한 옅게 두고 테두리만 구분되게 표시한다.
                          CircleMarker(
                            point: myPosition,
                            radius: 200,
                            useRadiusInMeter: true,
                            color: Colors.transparent,
                            borderColor: Colors.red.withOpacity(0.45),
                            borderStrokeWidth: 1.0,
                          ),
                          CircleMarker(
                            point: myPosition,
                            radius: 300,
                            useRadiusInMeter: true,
                            color: Colors.transparent,
                            borderColor: Colors.orange.withOpacity(0.42),
                            borderStrokeWidth: 1.0,
                          ),
                          CircleMarker(
                            point: myPosition,
                            radius: 500,
                            useRadiusInMeter: true,
                            color: Colors.transparent,
                            borderColor: Colors.amber.shade700.withOpacity(0.40),
                            borderStrokeWidth: 1.0,
                          ),
                        ],
                      ),
                      MarkerLayer(
                        // 지도가 Heading-up으로 회전해도
                        // 마커 아이콘/거리표시는 화면 기준 정방향을 유지한다.
                        rotate: true,
                        markers: [
                          Marker(
                            point: myPosition,
                            width: 58,
                            height: 68,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.blue.shade700,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 3,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 5,
                                        color: Colors.black26,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.person,
                                    size: 18,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade700,
                                    borderRadius:
                                        BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    '내 위치',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ..._hunters.map(
                            (hunter) => Marker(
                              point: hunter.position,
                              width: 76,
                              height: 72,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color:
                                          _hunterColor(hunter.distance),
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2.5,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          blurRadius: 5,
                                          color: Colors.black26,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.person_pin_circle,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withOpacity(0.94),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      border: Border.all(
                                        color:
                                            _hunterColor(hunter.distance),
                                      ),
                                    ),
                                    child: Text(
                                      _distanceText(hunter.distance),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color:
                                            _hunterColor(hunter.distance),
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      RichAttributionWidget(
                        attributions: const [
                          TextSourceAttribution(
                            'OpenStreetMap contributors',
                          ),
                        ],
                      ),
                    ],
                  )
                else
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _statusText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                if (myPosition != null)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.white.withOpacity(0.96),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '확대',
                            onPressed: _zoomIn,
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 44,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.add, size: 28),
                          ),
                          const SizedBox(
                            width: 34,
                            child: Divider(height: 1),
                          ),
                          IconButton(
                            tooltip: '축소',
                            onPressed: _zoomOut,
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 44,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.remove, size: 28),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (_loading)
                  Container(
                    color: Colors.white.withOpacity(0.65),
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(),
                  ),
              ],
            ),
          ),

          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                icon: const Icon(
                  Icons.close_fullscreen,
                  size: 21,
                ),
                label: const Text(
                  '지도 닫기',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HunterPoint {
  const _HunterPoint({
    required this.position,
    required this.distance,
  });

  final LatLng position;
  final int distance;
}
