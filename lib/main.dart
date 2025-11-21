import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safety_guard/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_storage/get_storage.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 이미 있으면 생략

void main() {
  runApp(const SafeApp());
}

// 🔹 top-level 에서는 static 사용 불가 → static 제거
const platform = MethodChannel("com.civilsafety.app/native_service");

Future<void> startNativeService() async {
  try {
    await platform.invokeMethod("startService");
  } catch (e) {
    print("❌ startService error: $e");
  }
}

Future<void> stopNativeService() async {
  try {
    await platform.invokeMethod("stopService");
  } catch (e) {
    print("❌ stopService error: $e");
  }
}

class BackgroundLocation {
  static const EventChannel _channel =
      EventChannel("com.civilsafety.app/locationStream");

  static Stream<Map> get stream =>
      _channel.receiveBroadcastStream().map((e) => Map.from(e));
}

class SafeApp extends StatelessWidget {
  const SafeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '안전지키미',
      debugShowCheckedModeBanner: false,
      home: const SafetyHome(),
    );
  }
}

class SafetyHome extends StatefulWidget {
  const SafetyHome({super.key});

  @override
  State<SafetyHome> createState() => _SafetyHomeState();
}

class _SafetyHomeState extends State<SafetyHome> {

String toKoreanPersonCount(int n) {
  if (n <= 0) return "0명";

  const unitWords = [
    "한", "두", "세", "네",
    "다섯", "여섯", "일곱", "여덟", "아홉"
  ];

  const tensWords = [
    "",      // 0
    "열",    // 10
    "스물",  // 20 (← n == 20일 때는 따로 처리)
    "서른",  // 30
    "마흔",  // 40
    "쉰",    // 50
    "예순",  // 60
    "일흔",  // 70
    "여든",  // 80
    "아흔",  // 90
  ];

  // 1 ~ 9
  if (n < 10) {
    return "${unitWords[n - 1]} 명"; // 한 명, 두 명, ...
  }

  // 10 ~ 19 : 열한, 열두, ...
  if (n < 20) {
    if (n == 10) return "열 명";
    final u = n - 10;
    return "열${unitWords[u - 1]} 명"; // 열한 명, 열두 명 ...
  }

  // 20 : 스무 명 (예외)
  if (n == 20) {
    return "스무 명";
  }

  // 21 ~ 29 : 스물한, 스물두, ...
  if (n < 30) {
    final u = n - 20;
    return "스물${unitWords[u - 1]} 명"; // 스물한 명, 스물두 명 ...
  }

  // 30 ~ 99
  if (n < 100) {
    final t = n ~/ 10;   // 3,4,5...
    final u = n % 10;    // 0~9

    final tens = tensWords[t];

    if (u == 0) {
      // 30, 40, 50... → 서른 명, 마흔 명, 쉰 명...
      return "$tens 명";
    }

    // 31, 32, ... → 서른한 명, 마흔두 명, 쉰세 명...
    final unit = unitWords[u - 1];
    return "$tens$unit 명";
  }

  // 100 이상은 그냥 숫자+명
  return "$n명";
}

  double _progress = 0.0;
  Timer? _progressTimer;

  Timer? _timer;
  bool _running = false;

  Timer? _dangerBlinkTimer;
  bool _isDangerBlinkOn = true;      // true/false 번갈아가며 깜빡임

  String _level = 'SAFE';
  int _distance = -1;

  int _nearCount150 = 0;
  int _nearCount200 = 0;
  int _nearCount500 = 0;

  String _deviceId = '';
  DateTime? _lastCheck;

  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _tts = FlutterTts();

  // 🔹 네이티브에서 오는 위치 스트림
  StreamSubscription<Map>? _bgLocationSub;
  double? _lastLat;
  double? _lastLng;

void _startDangerBlink() {
  _dangerBlinkTimer?.cancel(); // 혹시 돌고 있던 거 있으면 정리
  _isDangerBlinkOn = true;

  _dangerBlinkTimer = Timer.periodic(
    const Duration(milliseconds: 600), // 깜빡이는 속도 (원하면 조절)
    (_) {
      if (!mounted) return;
      setState(() {
        _isDangerBlinkOn = !_isDangerBlinkOn;
      });
    },
  );
}

void _stopDangerBlink() {
  _dangerBlinkTimer?.cancel();
  _dangerBlinkTimer = null;

  // 꺼질 때는 원을 항상 기본색(진한 색)으로
  if (mounted) {
    setState(() {
      _isDangerBlinkOn = true;
    });
  }
}

  @override
  void initState() {
    super.initState();
    _initDeviceId();
    _checkFirstAgreement();

    // 🔊 TTS 초기 설정
    _initTts();
  }

  Future<void> _speak(String text) async {
    try {
      // await _tts.stop(); // 이전 음성 중지
      await _tts.speak(text);
    } catch (e) {
      debugPrint('❌ TTS speak error: $e');
    }
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('ko-KR'); // 한국어
      await _tts.setSpeechRate(0.5);   // 속도 (0.0 ~ 1.0)
      await _tts.setPitch(1.0);        // 피치

      // 🔹 이 줄 추가: speak()가 끝날 때까지 await가 기다리게 설정
      await _tts.awaitSpeakCompletion(true);
    } catch (e) {
      debugPrint('❌ TTS init error: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _player.dispose();
    _tts.stop(); // 🔊 말하던 거 있으면 정지
    _dangerBlinkTimer?.cancel();
    super.dispose();
  }

  // ----------------------------------------------------------
  // ★ 첫 실행 시 동의 안내 + 권한 요청
  // ----------------------------------------------------------
  Future<void> _checkFirstAgreement() async {
    final agreed = await SafetyGuide.isAgreed();
    if (agreed) return;

    if (!mounted) return;

    final result = await SafetyGuide.showGuideDialog(context);

    if (!result) {
      exit(0);
    }

    // showGuideDialog 안에서 이미 권한 요청 + 동의 저장이 수행됨.
  }

  // ----------------------------------------------------------
  // 디바이스 ID
  // ----------------------------------------------------------
  Future<void> _initDeviceId() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        _deviceId = android.id;
      } else {
        _deviceId = 'IOS-DEVICE';
      }
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('❌ deviceId init error: $e');
    }
  }

  // ----------------------------------------------------------
  // 스캔 중지 시 서버에 CIVIL_GPS_LOG 삭제 요청
  // ----------------------------------------------------------
  Future<void> _sendStopToServer() async {
    try {
      // deviceId가 아직 비어 있으면 한 번 더 초기화 시도
      if (_deviceId.isEmpty) {
        await _initDeviceId();
        if (_deviceId.isEmpty) {
          debugPrint('❌ stop: deviceId 비어 있어서 stop 호출 생략');
          return;
        }
      }

      final uri =
          Uri.parse('https://m.kowildlife.com/BIO/civil_safety_stop.php');

      final res = await http.post(uri, body: {
        'deviceId': _deviceId,
      });

      debugPrint('🛑 stop status=${res.statusCode}');
      debugPrint('🛑 stop body=${res.body}');
    } catch (e) {
      debugPrint('❌ stop call error: $e');
    }
  }

  // ----------------------------------------------------------
  // ★ 버튼 눌렀을 때 권한 체크
  // ----------------------------------------------------------
  Future<bool> _ensureAlwaysLocationPermission() async {
    LocationPermission perm = await Geolocator.checkPermission();

    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      // 기본 권한도 없으면 그냥 false
      return false;
    }

    // 🔹 여기서 whileInUse vs always 구분
    if (perm == LocationPermission.always) {
      return true;
    }

    // 여기까지 오면 "앱 사용 중에만 허용" 상태
    if (!mounted) return false;

    final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text(
              '백그라운드 위치 권한 필요',
              style: TextStyle(
                fontSize: 18, // 👈 원하는 크기로 조절
                fontWeight: FontWeight.w600, // 기존 굵기 유지하고 싶으면 추가
              ),
            ),
            content: const Text(
              '화면을 꺼도 근접경보가 계속 작동하게 하려면\n'
              '\'항상 허용\'으로 위치 권한을 바꿔야 합니다.\n\n'
              '설정 화면으로 이동하시겠습니까?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('설정 열기'),
              ),
            ],
          ),
        ) ??
        false;

    if (ok) {
      // 앱 설정 / 위치 설정 화면 열기
      await Geolocator.openAppSettings();
    }

    return false; // '항상 허용' 아니면 스캔 시작 안 함 (정책 A)
  }

  // ----------------------------------------------------------
  // 스캔 ON/OFF
  // ----------------------------------------------------------
  void _toggle() async {
    if (_running) {
      await _stop();
    } else {
      if (!await _ensureAlwaysLocationPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("백그라운드 동작을 위해 위치권한을 '항상 허용'으로 설정하세요."),
          ),
        );
        return;
      }
      await _start();
    }
  }

  // 🔹 네이티브 ForegroundService + 타이머 시작
  Future<void> _start() async {
    // 🔊 스캔 시작 안내
    await _speak("안전지키미가 스캔을 시작합니다.");

    // 안드로이드 네이티브 ForegroundService 시작
    await startNativeService();

    // 🔹 네이티브 LocationService 에서 오는 위치 스트림 구독
    _bgLocationSub ??= BackgroundLocation.stream.listen((event) {
      try {
        final lat = (event['lat'] as num).toDouble();
        final lng = (event['lng'] as num).toDouble();
        _lastLat = lat;
        _lastLng = lng;
      } catch (e) {
        debugPrint('❌ background location parse error: $e');
      }
    });

    setState(() => _running = true);

    _timer?.cancel();
    // 한 번 즉시 체크
    await _checkSafetyImmediate();

    // 이후 30초마다 서버 체크
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkSafety();
    });

    _progress = 0.0;
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!_running) return; // 안전장치
      setState(() {
        _progress += 0.01; // 약 30초에 1.0 도달
        if (_progress >= 1.0) _progress = 1.0;
      });
    });
  }

  // 🔹 네이티브 서비스 + 타이머 정지
  Future<void> _stop() async {
    // 1️⃣ 우선 논리적으로 '중지 상태'로 먼저 바꾸기
    setState(() {
      _running = false;
    });

    // 2️⃣ 지금 돌고 있는 것들부터 전부 끊기 (타이머/애니메이션/스트림)
    _timer?.cancel();
    _progressTimer?.cancel();
   _stopDangerBlink();

    await _bgLocationSub?.cancel();
    _bgLocationSub = null;

    // 3️⃣ 지금 울리고 있는 경보(음성/알람/진동) 모두 즉시 정지
    await _stopAllAlerts();  // 이 안에서 TTS.stop(), player.stop(), Vibration.cancel()

    // 4️⃣ 스캔 중지 안내 음성 한 번만
    await _speak("스캔을 중지합니다.");

    // 5️⃣ 네이티브 ForegroundService 중지
    await stopNativeService();

    // 6️⃣ CIVIL_GPS_LOG에서 내 좌표 삭제 요청
    await _sendStopToServer();

    // 7️⃣ 화면 상태 초기화
    setState(() {
      _level = 'SAFE';
      _distance = -1;
      _nearCount150 = 0;
      _nearCount200 = 0;
      _nearCount500 = 0;
      _lastCheck = null;
      _progress = 0.0;
    });
  }

Future<void> _processSafety(double lat, double lng) async {
  try {
    if (_deviceId.isEmpty) {
      await _initDeviceId();
      if (_deviceId.isEmpty) return;
    }

    final uri =
        Uri.parse('https://m.kowildlife.com/BIO/civil_safety_ping.php');

    final res = await http.post(uri, body: {
      'deviceId': _deviceId,
      'lat': lat.toString(),
      'lng': lng.toString(),
    });

    debugPrint('🔎 ping status=${res.statusCode}');
    debugPrint('🔎 ping body=${res.body}');

    if (res.statusCode != 200) return;

    final body = res.body.trim();
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      debugPrint('❌ no JSON object found in body');
      return;
    }

    final data = jsonDecode(body.substring(start, end + 1));

    // 거리 파싱
    final rawDist = data['minDistance'] ?? data['distance'];
    int dist = -1;
    if (rawDist is int) dist = rawDist;
    else if (rawDist is double) dist = rawDist.round();
    else if (rawDist is String) dist = int.tryParse(rawDist) ?? -1;

    int within150 = _parseIntField(data['within150']);
    int within200 = _parseIntField(data['within200']);
    int within500 = _parseIntField(data['within500']);

    // ⛔ 여기서 먼저 _running 확인 (버튼 안 누른 상태면 다 무시)
    if (!_running) {
      debugPrint('ℹ️ _processSafety called while not running. ignore.');
      return;
    }

    String level = 'SAFE';
    if (dist >= 0) {
      if (dist <= 100) level = '위험';
      else if (dist <= 150) level = '경계';
      else if (dist <= 200) level = '주의';
      else if (dist <= 500) level = '관심';
    }

    if (!mounted) return;
    setState(() {
      _level = level;
      _distance = dist;
      _nearCount150 = within150;
      _nearCount200 = within200;
      _nearCount500 = within500;
      _lastCheck = DateTime.now();
    });

    // 혹시 중간에 사용자가 스캔 중지 눌렀으면 여기서도 한 번 더 체크
    if (!_running) {
      debugPrint('ℹ️ _processSafety: stopped during update. skip alerts.');
      return;
    }

    // 🔴 level 바뀔 때 깜빡이 on/off
    if (level == '위험') {
      _startDangerBlink();
    } else {
      _stopDangerBlink();
    }

    await _alertByDistance(dist);
  } catch (e) {
    debugPrint('❌ safety check error: $e');
  }
}

  // 🔹 스캔 시작 직후 1회: Geolocator로 즉시 위치를 가져와서 바로 체크
  Future<void> _checkSafetyImmediate() async {
    try {
      if (!await _ensureAlwaysLocationPermission()) {
        debugPrint('❌ immediate check: no location permission');
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _lastLat = pos.latitude;
      _lastLng = pos.longitude;

      debugPrint('📍 immediate position: ${pos.latitude}, ${pos.longitude}');

      await _processSafety(pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('❌ immediate safety check error: $e');
    }
  }

  // ----------------------------------------------------------
  // 스캔(거리 계산)
  // ----------------------------------------------------------
  Future<void> _checkSafety() async {
    try {
      if (_lastLat == null || _lastLng == null) {
        debugPrint('📍 아직 네이티브 위치가 없습니다. 다음 주기까지 대기.');
        return;
      }

      await _processSafety(_lastLat!, _lastLng!);
    } catch (e) {
      debugPrint('❌ safety check (native) error: $e');
    }

    setState(() => _progress = 0.0);
  }

  int _parseIntField(dynamic raw) {
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  // ----------------------------------------------------------
  // 경보 즉시 모두 중지 (음성, 알람, 진동)
  // ----------------------------------------------------------
  Future<void> _stopAllAlerts() async {
    try {
      // 진동 중지
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.cancel();
      }
    } catch (e) {
      debugPrint('❌ vibration cancel error: $e');
    }

    try {
      await _player.stop();
    } catch (e) {
      debugPrint('❌ audio stop error: $e');
    }

    try {
      await _tts.stop();
    } catch (e) {
      debugPrint('❌ TTS stop error: $e');
    }
  }

  // ----------------------------------------------------------
  // 경보
  // ----------------------------------------------------------
Future<void> _alertByDistance(int dist) async {
  // 스캔 중이 아니면 어떤 알림도 내지 않음
  if (!_running) {
    debugPrint('ℹ️ alertByDistance: not running, skip alert');
    return;
  }

  // dist < 0 이면 아무 것도 안 함
  if (dist < 0) return;

  // 500m 밖 → 안전 안내
  if (dist > 500) {
    await _speak("현재 안전구역 오백 미터 안에 엽사가 없습니다.");
    return;
  }

  // 150m 이내
  if (dist <= 150) {
    await _vibrate(high: true);
    await _playAlarm();
    await _speak("현재 백오십 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount150)} 있습니다. 즉시 주변을 경계하세요.");
    return;
  }

  // 200m 이내
  if (dist <= 200) {
    await _vibrate(high: true);
    await _speak("현재 이백 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount200)} 있습니다. 주의하세요.");
    return;
  }

  // 500m 이내
  if (dist <= 500) {
    await _vibrate(high: false);
    await _speak("현재 오백 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount500)} 있습니다.");
    return;
  }
}

  Future<void> _vibrate({required bool high}) async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        if (high) {
          Vibration.vibrate(pattern: [0, 500, 200, 1200]);
        } else {
          Vibration.vibrate(duration: 600);
        }
      }
    } catch (e) {
      debugPrint('❌ vibration error: $e');
    }
  }

  Future<void> _playAlarm() async {
    try {
      await _player.stop();
      await _player.play(
        AssetSource('mp3/alarm.mp3'),
      );
    } catch (e) {
      debugPrint('❌ audio play error: $e');
    }
  }

  // ----------------------------------------------------------
  // UI
  // ----------------------------------------------------------
Color _levelColorByDistance() {
  // 500m 넘으면 SAFE (초록)
  if (_distance < 0 || _distance > 500) {
    return Colors.green.shade400;
  }

  // 0 ~ 100m → 위험 (빨강)
  if (_distance <= 100) {
    return Colors.red.shade400;
  }

  // 100 ~ 150m → 경계 (진한 주황빛)
  if (_distance <= 150) {
    return Colors.deepOrange.shade400;
  }

  // 150 ~ 200m → 주의 (노란빛)
  if (_distance <= 200) {
    return Colors.orange.shade400;
  }

  // 200 ~ 500m → 관심 (연노랑)
  return Colors.yellow.shade600;
}


  Widget _buildRangeMessage() {
    if (_distance < 0) {
      return const Text("");
    }

    if (_distance > 500) {
      return const Text(
        "현재 안전구역 500m 내에 엽사가 없습니다",
        style: TextStyle(fontSize: 18),
      );
    }

    if (_distance > 200) {
      return Text(
        "500m 이내 엽사 $_nearCount500명",
        style: const TextStyle(fontSize: 18),
      );
    }

    if (_distance > 150) {
      return Text(
        "150m 이내 엽사 $_nearCount200명",
        style: const TextStyle(fontSize: 18),
      );
    }

    return Text(
      "150m 이내 엽사 $_nearCount150명",
      style: const TextStyle(fontSize: 18),
    );
  }

  String _distanceText() {
    if (_distance < 0) return "";
    return "가장 근접한 엽사와 약 $_distance m";
  }

  String _cautionText() {
    if (_distance < 0) return "";
    if (_distance > 500) return "현재는 안전한 상태입니다";
    if (_distance <= 150) return "즉시 주변을 경계하세요";
    return "주의하세요";
  }

  @override
  Widget build(BuildContext context) {
    final last = _lastCheck == null
        ? '없음'
        : "${_lastCheck!.hour.toString().padLeft(2, '0')}:${_lastCheck!.minute.toString().padLeft(2, '0')}";

    final caution = _cautionText();

      // 🔹 원 기본색 (거리 기준)
      final baseColor = _levelColorByDistance();

      // 🔴 "위험"일 때는 깜빡이는 색 적용
      final Color circleColor;
      if (_level == '위험') {
        circleColor = _isDangerBlinkOn
            ? baseColor                  // 켜진 상태 (진한 빨강 계열)
            : baseColor.withOpacity(0.2); // 꺼진 상태 (옅은 색)
      } else {
        circleColor = baseColor;          // 위험 아니면 그냥 기본색
      }

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 2,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/icon/app_icon_s.png',
              width: 46,
              height: 46,
            ),
            const SizedBox(width: 8),
            const Text(
              '안전지키미',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 30),
            Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: circleColor,
                boxShadow: [
                  BoxShadow(
                    color: circleColor.withOpacity(0.7),
                    blurRadius: 30,
                    spreadRadius: 5,
                  )
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                _level,
                style: const TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 30),
            _buildRangeMessage(),
            const SizedBox(height: 8),
            if (_running) const ScanProgressBar(),
            Text(
              _distanceText(),
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            if (caution.isNotEmpty)
              Text(
                caution,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            const SizedBox(height: 16),
            Text("스캔 시각: $last"),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _toggle,
              style: ElevatedButton.styleFrom(
                backgroundColor: _running ? Colors.green.shade700 : Colors.green,
                padding:
                    const EdgeInsets.symmetric(horizontal: 60, vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
              child: Text(
                _running ? "주변 스캔 중지" : "주변 스캔 시작",
                style: TextStyle(
                  fontSize: 22,
                  color: _running ? Colors.yellow : Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScanProgressBar extends StatefulWidget {
  const ScanProgressBar({super.key});

  @override
  State<ScanProgressBar> createState() => _ScanProgressBarState();
}

class _ScanProgressBarState extends State<ScanProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300), // 왕복 속도
    )..repeat(); // 계속 왕복
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
      child: SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fullWidth = constraints.maxWidth;
            final barWidth = fullWidth * 0.18; // 막대 길이

            return Stack(
              children: [
                // 배경 라인
                Container(
                  width: fullWidth,
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),

                // 왕복하는 스캔 바
                AnimatedBuilder(
                  animation: _controller,
                  builder: (_, __) {
                    final t = _controller.value; // 0.0 ~ 1.0
                    // 0→1/2 : 0→1 , 1/2→1 : 1→0  (삼각파)
                    final tri = t <= 0.5 ? t * 2 : (2 - 2 * t);
                    final maxLeft = fullWidth - barWidth;
                    final left = tri * maxLeft;

                    return Positioned(
                      left: left,
                      top: 0,
                      child: Container(
                        width: barWidth,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.green.shade600,
                          borderRadius: BorderRadius.circular(3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.green.withOpacity(0.5),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
