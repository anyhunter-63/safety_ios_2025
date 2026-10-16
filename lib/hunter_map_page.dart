import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
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

  final MapController _mapController = MapController();

  Timer? _timer;
  Timer? _recenterTimer;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<Position>? _positionSub;

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

  // Heading-up 상태. 폰의 윗부분이 향하는 방위만 사용한다.
  double _compassHeading = 0.0;
  double _mapHeading = 0.0;

  // Heading-up 회전 떨림 억제용.
  DateTime? _lastHeadingSentAt;
  double? _lastSentHeadingForCompass;
  static const Duration _headingSendInterval = Duration(milliseconds: 60);
  static const double _headingSendMinDelta = 1.5;

  // 지도 좌측 상단 나침반 표시용.
  // 지도 전체를 다시 빌드하지 않고 나침반만 회전시킨다.
  final ValueNotifier<double> _compassDisplayHeading =
      ValueNotifier<double>(0.0);

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
    _positionSub?.cancel();
    _compassDisplayHeading.dispose();
    super.dispose();
  }

  Future<void> _startRealtimeMap() async {
    final allowed = await _ensureLocationPermission();
    if (!mounted || !allowed) return;

    // 내 위치는 서버 조회 결과를 기다리지 않고 별도 스트림에서 갱신한다.
    await _positionSub?.cancel();
    if (!mounted) return;
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen(
      _onPositionChanged,
      onError: (Object error) {
        debugPrint('❌ hunter map GPS stream error: $error');
        if (!mounted || _myPosition != null) return;
        setState(() {
          _loading = false;
          _statusText = '현재 위치를 확인하지 못했습니다.';
        });
      },
    );

    // 타인 좌표는 기존처럼 5초마다 서버에서 확인한다.
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  void _onPositionChanged(Position pos) {
    if (!mounted || !pos.latitude.isFinite || !pos.longitude.isFinite) return;
    if (pos.latitude.abs() > 90 || pos.longitude.abs() > 180) return;

    // 센서 미세 흔들림은 무시하되 걷는 속도에서도 바로 반영한다.
    final next = LatLng(pos.latitude, pos.longitude);
    final previous = _myPosition;
    if (previous != null &&
        Geolocator.distanceBetween(
          previous.latitude,
          previous.longitude,
          next.latitude,
          next.longitude,
        ) < 1.0) {
      return;
    }

    final firstFix = previous == null;
    setState(() {
      _myPosition = next;
      _loading = false;
      _statusText = _hunters.isEmpty
          ? '1km 이내 확인된 엽사가 없습니다.'
          : '1km 이내 엽사 ${_hunters.length}명';
    });

    // 원/내 위치/타인 마커는 setState로 즉시 갱신하며,
    // 지도 중심 이동만 렌더 완료 후 안전하게 실행한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady || _userPanning) return;
      try {
        _mapController.move(next, _currentZoom);
      } catch (_) {}
    });

    // 첫 GPS 위치를 확보하면 첫 서버 조회를 바로 실행한다.
    if (firstFix) _refresh();
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

  double _normalizeMapHeading(double bearingDegrees) {
    if (!bearingDegrees.isFinite) return _mapHeading;

    // flutter_map의 rotate()는 '지도 자체'를 회전시킨다.
    // 사용자의 실제 방위가 화면 위쪽을 향하게 하려면 지도는 반대 방향으로 회전해야 한다.
    return (((-bearingDegrees) % 360) + 360) % 360;
  }

  double _headingDelta(double a, double b) {
    var delta = (a - b).abs();
    if (delta > 180) delta = 360 - delta;
    return delta;
  }

  void _startCompass() {
    _compassSub = FlutterCompass.events?.listen((event) {
      final magneticHeading = event.heading;

      if (magneticHeading == null || magneticHeading.isNaN) {
        return;
      }

      // 실제 단말 테스트 결과 flutter_compass의 event.heading을
      // 그대로 사용할 때 지도의 정북 방향이 가장 정확했다.
      // 별도의 자기편차 보정은 적용하지 않는다.
      final trueBearing = magneticHeading;
      final next = _normalizeMapHeading(trueBearing);

      // 마지막 지도 반영값을 기준으로 미세 떨림과 과도한 회전 호출 억제.
      final lastHeading = _lastSentHeadingForCompass;
      if (lastHeading != null &&
          _headingDelta(next, lastHeading) < _headingSendMinDelta) {
        return;
      }

      final now = DateTime.now();
      final lastSentAt = _lastHeadingSentAt;
      if (lastSentAt != null &&
          now.difference(lastSentAt) < _headingSendInterval) {
        return;
      }

      _lastHeadingSentAt = now;
      _lastSentHeadingForCompass = next;
      _compassHeading = next;
      _mapHeading = _compassHeading;
      _applyMapHeading();
    });
  }

  void _applyMapHeading() {
    // 지도 회전값과 좌측 상단 나침반을 항상 같은 값으로 유지한다.
    _compassDisplayHeading.value = _mapHeading;

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
    if (_refreshing || !mounted) return;
    final myPos = _myPosition;
    if (myPos == null) return; // GPS 첫 수신 전에는 서버 조회하지 않는다.
    _refreshing = true;

    try {
      final uri = Uri.parse(
        'https://m.kowildlife.com/BIO/civil_safety_ping.php',
      );

      final response = await http
          .post(
            uri,
            body: {
              'deviceId': widget.deviceId,
              'lat': myPos.latitude.toString(),
              'lng': myPos.longitude.toString(),
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

      if (!mounted) return;
      // 이동 중 서버가 응답해도 스트림의 최신 내 위치를 덮어쓰지 않는다.
      final livePos = _myPosition ?? myPos;
      hunters.sort((a, b) =>
          _distanceToHunter(a, livePos).compareTo(_distanceToHunter(b, livePos)));
      setState(() {
        _hunters = hunters;
        _lastUpdated = DateTime.now();
        _statusText = hunters.isEmpty
            ? '1km 이내 확인된 엽사가 없습니다.'
            : '1km 이내 엽사 ${hunters.length}명';
      });
    } catch (e) {
      if (!mounted) return;
      // 통신 오류가 발생해도 GPS와 기존 타인 마커는 유지한다.
      debugPrint('❌ hunter map refresh error: $e');
      setState(() {
        _statusText = '주변 위치 정보를 갱신하지 못했습니다.';
      });
    } finally {
      _refreshing = false;
    }
  }

  int _distanceToHunter(_HunterPoint hunter, LatLng myPos) {
    // 서버에서 받은 타인 좌표와 최신 내 GPS로 상대 거리를 바로 재계산한다.
    return Geolocator.distanceBetween(
      myPos.latitude,
      myPos.longitude,
      hunter.position.latitude,
      hunter.position.longitude,
    ).round();
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
          '주변 수렵인 탐색',
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
                            radius: 100,
                            useRadiusInMeter: true,
                            color: Colors.transparent,
                            borderColor: Colors.red.withOpacity(0.65),
                            borderStrokeWidth: 1.0,
                          ),
                          CircleMarker(
                            point: myPosition,
                            radius: 300,
                            useRadiusInMeter: true,
                            color: Colors.transparent,
                            borderColor: Colors.orange.withOpacity(0.65),
                            borderStrokeWidth: 1.0,
                          ),
                          CircleMarker(
                            point: myPosition,
                            radius: 500,
                            useRadiusInMeter: true,
                            color: Colors.transparent,
                            borderColor: Colors.amber.shade700.withOpacity(0.65),
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
                          ..._hunters.map((hunter) {
                            final distance =
                                _distanceToHunter(hunter, myPosition);
                            return Marker(
                              point: hunter.position,
                              width: 62,
                              height: 58,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 28,
                                    height: 34,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Container(
                                          width: 28,
                                          height: 34,
                                          decoration: const BoxDecoration(
                                            boxShadow: [
                                              BoxShadow(
                                                blurRadius: 4,
                                                offset: Offset(0, 1),
                                                color: Colors.black26,
                                              ),
                                            ],
                                          ),
                                          child: const CustomPaint(
                                            painter: _HunterMarkerPainter(),
                                          ),
                                        ),
                                        Positioned(
                                          right: -1,
                                          top: -1,
                                          child: Container(
                                            width: 9,
                                            height: 9,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: _hunterColor(
                                                distance,
                                              ),
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 1.4,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.94),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: _hunterColor(distance),
                                      ),
                                    ),
                                    child: Text(
                                      _distanceText(distance),
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: _hunterColor(distance),
                                        fontWeight: FontWeight.w800,
                                        height: 1.0,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
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
                // 지도 회전에 맞춰 북쪽을 가리키는 나침반.
                // 배경은 고정하고 나침반 바늘만 회전시킨다.
                if (myPosition != null)
                  Positioned(
                    left: 12,
                    top: 12,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                              color: Colors.black.withOpacity(0.18),
                            ),
                          ],
                        ),
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withOpacity(0.98),
                                const Color(0xFFE9EEF3),
                              ],
                            ),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.95),
                              width: 1.5,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                const Positioned.fill(
                                  child: CustomPaint(
                                    painter: _CompassDialPainter(),
                                  ),
                                ),
                                ValueListenableBuilder<double>(
                                  valueListenable: _compassDisplayHeading,
                                  builder: (context, heading, _) {
                                    return Transform.rotate(
                                      angle: heading * math.pi / 180.0,
                                      child: const SizedBox(
                                        width: 36,
                                        height: 36,
                                        child: CustomPaint(
                                          painter: _CompassNeedlePainter(),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(0xFF263238),
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 1.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
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
	  minimum: const EdgeInsets.fromLTRB(12, 8, 12, 14),
	  child: SizedBox(
	    width: double.infinity,
	    height: 48,
	    child: ElevatedButton.icon(
	      style: ElevatedButton.styleFrom(
		side: const BorderSide(
		  color: Color(0xFF64748B), // 선명한 회청색
		  width: 1.5,              // 테두리 굵기
		),
		shape: RoundedRectangleBorder(
		  borderRadius: BorderRadius.circular(12),
		),
		elevation: 2,
	      ),
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



class _HunterMarkerPainter extends CustomPainter {
  const _HunterMarkerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final outlineStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4.0
      ..color = Colors.white;

    final darkStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2.2
      ..color = const Color(0xFF222222);

    final legOutline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4.4
      ..color = Colors.white;

    final legStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2.6
      ..color = const Color(0xFF333333);

    final capFill = Paint()..color = const Color(0xFFF57C00);
    final skinFill = Paint()..color = const Color(0xFFFFE0BD);
    final vestFill = Paint()..color = const Color(0xFFFF6D00);
    final pantsFill = Paint()..color = const Color(0xFF4E4E4E);
    final packFill = Paint()..color = const Color(0xFF353535);
    final rifleStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2.6
      ..color = const Color(0xFF1F1F1F);
    final rifleOutline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4.6
      ..color = Colors.white;

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.34, h * 0.29, w * 0.25, h * 0.27),
      const Radius.circular(5),
    );
    final arm = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.53, h * 0.33, w * 0.11, h * 0.18),
      const Radius.circular(4),
    );
    final pack = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.24, h * 0.31, w * 0.14, h * 0.22),
      const Radius.circular(4),
    );

    final headCenter = Offset(w * 0.50, h * 0.18);
    final headRadius = w * 0.11;

    final cap = ui.Path()
      ..moveTo(w * 0.38, h * 0.11)
      ..quadraticBezierTo(w * 0.49, h * 0.04, w * 0.58, h * 0.11)
      ..lineTo(w * 0.61, h * 0.15)
      ..lineTo(w * 0.37, h * 0.15)
      ..close();
    final brim = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.55, h * 0.125, w * 0.12, h * 0.04),
      const Radius.circular(3),
    );

    final vestStripe = ui.Path()
      ..moveTo(w * 0.425, h * 0.30)
      ..lineTo(w * 0.48, h * 0.56)
      ..lineTo(w * 0.52, h * 0.56)
      ..lineTo(w * 0.465, h * 0.30)
      ..close();

    final neckStart = Offset(w * 0.46, h * 0.24);
    final neckEnd = Offset(w * 0.46, h * 0.29);

    final leftLegStart = Offset(w * 0.41, h * 0.55);
    final leftLegEnd = Offset(w * 0.34, h * 0.88);
    final rightLegStart = Offset(w * 0.51, h * 0.55);
    final rightLegEnd = Offset(w * 0.58, h * 0.86);
    final leftFootEnd = Offset(w * 0.24, h * 0.90);
    final rightFootEnd = Offset(w * 0.66, h * 0.88);

    final rifleStart = Offset(w * 0.23, h * 0.18);
    final rifleEnd = Offset(w * 0.34, h * 0.70);

    canvas.drawLine(rifleStart, rifleEnd, rifleOutline);
    canvas.drawLine(rifleStart, rifleEnd, rifleStroke);

    canvas.drawRRect(pack, Paint()..color = Colors.white);
    canvas.drawRRect(pack, packFill);
    canvas.drawRRect(
      pack,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFF202020),
    );

    canvas.drawCircle(headCenter, headRadius, Paint()..color = Colors.white);
    canvas.drawCircle(headCenter, headRadius, skinFill);
    canvas.drawCircle(
      headCenter,
      headRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = const Color(0xFF2B2B2B),
    );

    canvas.drawPath(cap, capFill);
    canvas.drawPath(
      cap,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = const Color(0xFF2B2B2B),
    );
    canvas.drawRRect(brim, capFill);
    canvas.drawRRect(
      brim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = const Color(0xFF2B2B2B),
    );

    canvas.drawLine(neckStart, neckEnd, outlineStroke);
    canvas.drawLine(neckStart, neckEnd, darkStroke);

    canvas.drawRRect(body, Paint()..color = Colors.white);
    canvas.drawRRect(body, vestFill);
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFF2B2B2B),
    );
    canvas.drawPath(vestStripe, Paint()..color = const Color(0xFFFFB74D));

    canvas.drawRRect(arm, Paint()..color = Colors.white);
    canvas.drawRRect(arm, vestFill);
    canvas.drawRRect(
      arm,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = const Color(0xFF2B2B2B),
    );

    canvas.drawLine(leftLegStart, leftLegEnd, legOutline);
    canvas.drawLine(rightLegStart, rightLegEnd, legOutline);
    canvas.drawLine(leftLegEnd, leftFootEnd, legOutline);
    canvas.drawLine(rightLegEnd, rightFootEnd, legOutline);

    canvas.drawLine(leftLegStart, leftLegEnd, legStroke);
    canvas.drawLine(rightLegStart, rightLegEnd, legStroke);
    canvas.drawLine(leftLegEnd, leftFootEnd, legStroke);
    canvas.drawLine(rightLegEnd, rightFootEnd, legStroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}



class _CompassDialPainter extends CustomPainter {
  const _CompassDialPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;

    final fillPaint = Paint()
      ..shader = ui.Gradient.radial(
        center,
        radius,
        [
          const Color(0xFFFDFEFE),
          const Color(0xFFF0F3F7),
        ],
      );
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const Color(0xFFD5DDE6);
    final innerRingPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0xFFBFCAD5).withOpacity(0.7);
    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, fillPaint);
    canvas.drawCircle(center, radius - 0.8, ringPaint);
    canvas.drawCircle(center, radius - 5.0, innerRingPaint);

    for (int i = 0; i < 24; i++) {
      final angle = (i * 15 - 90) * math.pi / 180.0;
      final isMajor = i % 6 == 0;
      final isMinorMajor = i % 3 == 0;
      final outer = radius - 7.0;
      final inner = outer - (isMajor ? 7.0 : (isMinorMajor ? 5.0 : 3.0));
      tickPaint
        ..strokeWidth = isMajor ? 2.0 : 1.2
        ..color = isMajor
            ? const Color(0xFF607080)
            : const Color(0xFF90A1B2);
      final p1 = Offset(
        center.dx + math.cos(angle) * inner,
        center.dy + math.sin(angle) * inner,
      );
      final p2 = Offset(
        center.dx + math.cos(angle) * outer,
        center.dy + math.sin(angle) * outer,
      );
      canvas.drawLine(p1, p2, tickPaint);
    }

    void drawLabel(String text, double degrees, Color color, double fontSize,
        FontWeight weight) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: weight,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final angle = (degrees - 90) * math.pi / 180.0;
      final labelRadius = radius - 13.0;
      final offset = Offset(
        center.dx + math.cos(angle) * labelRadius - tp.width / 2,
        center.dy + math.sin(angle) * labelRadius - tp.height / 2,
      );
      tp.paint(canvas, offset);
    }

    drawLabel('N', 0, const Color(0xFFD84343), 11, FontWeight.w900);
    drawLabel('E', 90, const Color(0xFF607080), 9, FontWeight.w700);
    drawLabel('S', 180, const Color(0xFF607080), 9, FontWeight.w700);
    drawLabel('W', 270, const Color(0xFF607080), 9, FontWeight.w700);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CompassNeedlePainter extends CustomPainter {
  const _CompassNeedlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final north = ui.Path()
      ..moveTo(center.dx, 2)
      ..lineTo(center.dx - 6, center.dy + 3)
      ..quadraticBezierTo(center.dx, center.dy - 1, center.dx + 6, center.dy + 3)
      ..close();

    final south = ui.Path()
      ..moveTo(center.dx, size.height - 2)
      ..lineTo(center.dx - 5, center.dy - 2)
      ..quadraticBezierTo(center.dx, center.dy + 4, center.dx + 5, center.dy - 2)
      ..close();

    final northFill = Paint()..color = const Color(0xFFE5484D);
    final southFill = Paint()..color = const Color(0xFF4B5B6B);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.white.withOpacity(0.9);

    canvas.drawShadow(north, Colors.black.withOpacity(0.18), 2.5, false);
    canvas.drawPath(north, northFill);
    canvas.drawPath(north, outline);

    canvas.drawShadow(south, Colors.black.withOpacity(0.12), 2.0, false);
    canvas.drawPath(south, southFill);
    canvas.drawPath(south, outline);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HunterPoint {
  const _HunterPoint({
    required this.position,
    required this.distance,
  });

  final LatLng position;
  final int distance;
}
