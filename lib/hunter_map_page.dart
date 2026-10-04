import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
  static const double _defaultZoom = 15.5;

  final MapController _mapController = MapController();

  Timer? _timer;
  LatLng? _myPosition;
  List<_HunterPoint> _hunters = const [];
  bool _loading = true;
  bool _refreshing = false;
  String _statusText = '현재 위치를 확인하고 있습니다.';
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startRealtimeMap();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
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
      final list = decoded is Map<String, dynamic>
          ? decoded['hunters']
          : null;

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

      setState(() {
        _myPosition = myPos;
        _hunters = hunters;
        _lastUpdated = DateTime.now();
        _loading = false;
        _statusText = hunters.isEmpty
            ? '1km 이내 확인된 엽사가 없습니다.'
            : '1km 이내 엽사 ${hunters.length}명';
      });

      // 요청대로 평상시/위험시 모두 항상 내 위치가 지도 중심이 되도록 한다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mapController.move(myPos, _defaultZoom);
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: Colors.white,
            child: Row(
              children: [
                const Icon(Icons.my_location, size: 18, color: Colors.blue),
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
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.civilsafety.app',
                      ),
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: myPosition,
                            radius: 150,
                            useRadiusInMeter: true,
                            color: Colors.red.withOpacity(0.05),
                            borderColor: Colors.red.withOpacity(0.45),
                            borderStrokeWidth: 1.2,
                          ),
                          CircleMarker(
                            point: myPosition,
                            radius: 500,
                            useRadiusInMeter: true,
                            color: Colors.amber.withOpacity(0.025),
                            borderColor: Colors.amber.shade700.withOpacity(0.40),
                            borderStrokeWidth: 1.0,
                          ),
                        ],
                      ),
                      MarkerLayer(
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
                                    borderRadius: BorderRadius.circular(8),
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
                                      color: _hunterColor(hunter.distance),
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
                                      color: Colors.white.withOpacity(0.94),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: _hunterColor(hunter.distance),
                                      ),
                                    ),
                                    child: Text(
                                      _distanceText(hunter.distance),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: _hunterColor(hunter.distance),
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
                          TextSourceAttribution('OpenStreetMap contributors'),
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
                if (_loading)
                  Container(
                    color: Colors.white.withOpacity(0.65),
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(),
                  ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            color: Colors.white,
            child: const Text(
              '지도는 5초마다 갱신되며, 사용자의 현재 위치를 중심으로 표시됩니다. '
              '수렵인 위치는 마지막 수신 좌표를 기준으로 하므로 실제 위치와 차이가 있을 수 있습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black54),
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
