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
      "한",
      "두",
      "세",
      "네",
      "다섯",
      "여섯",
      "일곱",
      "여덟",
      "아홉"
    ];

    const tensWords = [
      "", // 0
      "열", // 10
      "스물", // 20
      "서른", // 30
      "마흔", // 40
      "쉰", // 50
      "예순", // 60
      "일흔", // 70
      "여든", // 80
      "아흔", // 90
    ];

    // 1 ~ 9
    if (n < 10) {
      return "${unitWords[n - 1]} 명"; // 한 명, 두 명, ...
    }

    // 10 ~ 19 : 열한, 열두, ...
    if (n < 20) {
      if (n == 10) return "열 명";
      final u = n - 10;
      return "열${unitWords[u - 1]} 명";
    }

    // 20 : 스무 명 (예외)
    if (n == 20) {
      return "스무 명";
    }

    // 21 ~ 29 : 스물한, 스물두, ...
    if (n < 30) {
      final u = n - 20;
      return "스물${unitWords[u - 1]} 명";
    }

    // 30 ~ 99
    if (n < 100) {
      final t = n ~/ 10; // 3,4,5...
      final u = n % 10; // 0~9

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
  bool _isDangerBlinkOn = true; // true/false 번갈아가며 깜빡임

  String _level = 'SAFE';
  int _distance = -1;

  int _nearCount150 = 0;
  int _nearCount200 = 0;
  int _nearCount500 = 0;

  String _deviceId = '';
  DateTime? _lastCheck;

  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _tts = FlutterTts();

  // 🔹 네이티브에서 오는 위치 스트림 (안드로이드에서만 사용)
  StreamSubscription<Map>? _bgLocationSub;
  double? _lastLat;
  double? _lastLng;

  void _startDangerBlink() {
    _dangerBlinkTimer?.cancel();
    _isDangerBlinkOn = true;

    _dangerBlinkTimer = Timer.periodic(
      const Duration(milliseconds: 600),
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

    if (mounted) {
      setState(() {
        _isDangerBlinkOn = true;
      });
    }
  }

  @override
  void initState() {
    super.initState();

    // 🔊 TTS는 context 안 써서 그냥 바로 초기화
    _initTts();

    // ⚠️ context / Navigator 쓰는 것들은 첫 프레임 이후로 미룸
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _initDeviceId();
      } catch (e) {
        debugPrint('❌ deviceId init error: $e');
      }

      try {
        await _checkFirstAgreement();
      } catch (e) {
        debugPrint('❌ _checkFirstAgreement error: $e');
      }
    });
  }

  Future<void> _speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('❌ TTS speak error: $e');
    }
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
    } catch (e) {
      debugPrint('❌ TTS init error: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _progressTimer?.cancel();
    _player.dispose();
    _tts.stop();
    _dangerBlinkTimer?.cancel();
    _bgLocationSub?.cancel();
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
      return false;
    }

    if (perm == LocationPermission.always) {
      return true;
    }

    if (!mounted) return false;

    final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text(
              '백그라운드 위치 권한 필요',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
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
      await Geolocator.openAppSettings();
    }

    return false; // '항상 허용' 아니면 스캔 시작 안 함
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
    await _speak("안전지키미가 스캔을 시작합니다.");

    await startNativeService();

    if (Platform.isAndroid) {
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
    }

    setState(() => _running = true);

    _timer?.cancel();
    await _checkSafetyImmediate();

    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkSafety();
    });

    _progress = 0.0;
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!_running) return;
      setState(() {
        _progress += 0.01;
        if (_progress >= 1.0) _progress = 1.0;
      });
    });
  }

  // 🔹 네이티브 서비스 + 타이머 정지
  Future<void> _stop() async {
    setState(() {
      _running = false;
    });

    _timer?.cancel();
    _progressTimer?.cancel();
    _stopDangerBlink();

    await _bgLocationSub?.cancel();
    _bgLocationSub = null;

    await _stopAllAlerts();

    await _speak("스캔을 중지합니다.");

    await stopNativeService();

    await _sendStopToServer();

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

      final rawDist = data['minDistance'] ?? data['distance'];
      int dist = -1;
      if (rawDist is int) {
        dist = rawDist;
      } else if (rawDist is double) {
        dist = rawDist.round();
      } else if (rawDist is String) {
        dist = int.tryParse(rawDist) ?? -1;
      }

      final within150 = _parseIntField(data['within150']);
      final within200 = _parseIntField(data['within200']);
      final within500 = _parseIntField(data['within500']);

      if (!_running) {
        debugPrint('ℹ️ _processSafety called while not running. ignore.');
        return;
      }

      String level = 'SAFE';
      if (dist >= 0) {
        if (dist <= 100) {
          level = '위험';
        } else if (dist <= 150) {
          level = '경계';
        } else if (dist <= 200) {
          level = '주의';
        } else if (dist <= 500) {
          level = '관심';
        }
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

      if (!_running) {
        debugPrint('ℹ️ _processSafety: stopped during update. skip alerts.');
        return;
      }

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

  // 🔹 스캔 시작 직후 1회
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
      if (Platform.isIOS) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );

        _lastLat = pos.latitude;
        _lastLng = pos.longitude;

        debugPrint('📍 periodic position (iOS): ${pos.latitude}, ${pos.longitude}');
        await _processSafety(pos.latitude, pos.longitude);
      } else {
        if (_lastLat == null || _lastLng == null) {
          debugPrint('📍 아직 네이티브 위치가 없습니다. 다음 주기까지 대기.');
          return;
        }

        await _processSafety(_lastLat!, _lastLng!);
      }
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
    if (!_running) {
      debugPrint('ℹ️ alertByDistance: not running, skip alert');
      return;
    }

    if (dist < 0) return;

    // 500m 밖
    if (dist > 500) {
      await _speak("현재 안전구역 오백 미터 안에 엽사가 없습니다.");
      return;
    }

    // 150m 이내
    if (dist <= 150) {
      await _vibrate(high: true);
      await _playBeep();
      await _speak(
        "현재 백오십 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount150)} 있습니다. 즉시 주변을 경계하세요.",
      );
      return;
    }

    // 200m 이내
    if (dist <= 200) {
      await _vibrate(high: true);
      await _playBeep();
      await _speak(
        "현재 이백 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount200)} 있습니다. 주의하세요.",
      );
      return;
    }

    // 500m 이내
    if (dist <= 500) {
      await _vibrate(high: false);
      await _speak(
        "현재 오백 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount500)} 있습니다.",
      );
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

  Future<void> _playBeep() async {
    try {
      await _player.stop();

      await _player.play(
        AssetSource('mp3/alarm.mp3'),
      );

      await Future.delayed(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint('❌ beep play error: $e');
    }
  }

  // ----------------------------------------------------------
  // 뒤로가기 처리
  // ----------------------------------------------------------
  Future<bool> _handleBackPressed() async {
    if (_running) {
      if (!mounted) return false;

      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 36,
                  color: Colors.red,
                ),
                const SizedBox(height: 12),
                const Text(
                  '안전모드 동작 중',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '안전모드(근접경보)가 동작 중입니다.\n\n'
                  '종료를 원하시면 앱 하단의 주변 스캔 중지를 누르세요.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('확인'),
                  ),
                ),
              ],
            ),
          );
        },
      );

      return false;
    }

    if (Platform.isAndroid) {
      SystemNavigator.pop();
    } else if (Platform.isIOS) {
      exit(0);
    }
    return true;
  }

  // ----------------------------------------------------------
  // UI 색/텍스트
  // ----------------------------------------------------------
  Color _levelColorByDistance() {
    if (_distance < 0 || _distance > 500) {
      return Colors.green.shade400;
    }

    if (_distance <= 100) {
      return Colors.red.shade400;
    }

    if (_distance <= 150) {
      return Colors.deepOrange.shade400;
    }

    if (_distance <= 200) {
      return Colors.orange.shade400;
    }

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

  // ----------------------------------------------------------
  // 하단 메뉴: 회사정보 / 고객센터
  // ----------------------------------------------------------
  void _showCompanyInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('회사정보'),
        content: const Text(
          '앱 이름: 안전지키미\n'
          '제작: Light City Software\n'
          '\t(빛고을소프트웨어)\n\n'
          '본 앱은 엽사(수렵인)와의 거리 정보를 기반으로 총기 오인사고를 예방하기 위해 제작되었습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  void _showContactDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('고객센터'),
        content: const Text(
          '문의 이메일\n\n'
          'anyhunter63@gmail.com\n\n'
          '사용 중 불편사항이나 오류가 있으면 위 메일로 상세 내용을 보내 주세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // 하단 UI: 뒤로가기 버튼 + 푸터
  // ----------------------------------------------------------
  Widget _buildBottom() {
    return SizedBox(
      height: 50.0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              await _handleBackPressed();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final last = _lastCheck == null
        ? '없음'
        : "${_lastCheck!.hour.toString().padLeft(2, '0')}:${_lastCheck!.minute.toString().padLeft(2, '0')}";

    final caution = _cautionText();

    final baseColor = _levelColorByDistance();

    final Color circleColor;
    if (_level == '위험') {
      circleColor =
          _isDangerBlinkOn ? baseColor : baseColor.withOpacity(0.2);
    } else {
      circleColor = baseColor;
    }

    return WillPopScope(
      onWillPop: _handleBackPressed,
      child: Scaffold(
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
                  backgroundColor:
                      _running ? Colors.green.shade700 : Colors.green,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 60,
                    vertical: 18,
                  ),
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
              const SizedBox(height: 20),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ① 뒤로가기(종료) 버튼
              _buildBottom(),

              // ② 푸터 메뉴
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(
                    top: BorderSide(
                      color: Colors.grey.shade300,
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    // 회사정보
                    Expanded(
                      child: TextButton(
                        onPressed: () => _showCompanyInfo(context),
                        style: TextButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.info_outline,
                              size: 18,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 2),
                            Text(
                              '회사정보',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 고객센터
                    Expanded(
                      child: TextButton(
                        onPressed: () => _showContactDialog(context),
                        style: TextButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.mail_outline,
                              size: 18,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 2),
                            Text(
                              '고객센터',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 개인정보
                    Expanded(
                      child: TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const PrivacyPolicyPage(),
                            ),
                          );
                        },
                        style: TextButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.privacy_tip_outlined,
                              size: 18,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 2),
                            Text(
                              '개인정보',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 📶 스캔 진행 바
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
      duration: const Duration(milliseconds: 1300),
    )..repeat();
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
            final barWidth = fullWidth * 0.18;

            return Stack(
              children: [
                Container(
                  width: fullWidth,
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                AnimatedBuilder(
                  animation: _controller,
                  builder: (_, __) {
                    final t = _controller.value;
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

// 📄 개인정보처리방침 화면
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    const policyText = '''
[안전지키미 개인정보처리방침]

Light City Software(이하 "회사")는 안전지키미 서비스 제공을 위하여 아래와 같이 이용자의 개인정보를 수집·이용하며, 개인정보 보호 관련 법령을 준수합니다.

1. 수집하는 개인정보 항목
- 위치정보: 위도, 경도, 수집 시각
- 기기 정보: 기기 고유 식별자(디바이스 ID), OS 버전 등
- 서비스 이용 기록: 접속 로그

2. 개인정보의 수집 및 이용 목적
- 주변 수렵인(엽사)과의 거리 계산 및 위험 수준 판단
- 안전 경보(음성 안내, 진동, 알림) 제공
- 관련 법령 준수 및 분쟁 발생 시 확인·대응

3. 위치정보 처리에 관한 사항
- 안전지키미는 사용자가 "주변 스캔 시작" 기능을 활성화한 동안, 약 30초 간격으로 위치정보를 서버로 전송합니다.
- 위치정보는 m.kowildlife.com 서버에 저장되며, 주변 위험요소(엽사 위치)와의 거리를 계산하는 용도로만 사용됩니다.
- 사용자가 "주변 스캔 중지" 버튼을 누르거나 앱을 종료하면, 더 이상 새로운 위치정보가 수집·전송되지 않으며 위치정보, 기기 정보는 즉시 자동 파기됩니다.

4. 개인정보의 보유 및 이용 기간
- 위치 및 로그 정보: 안전지키미는 사용자가 "주변 스캔 시작" 기능을 사용하는 동안에 한하여 위치 및 관련 로그를 서버에서 처리합니다. 사용자가 "주변 스캔 중지" 버튼을 누르거나 앱을 종료하면, 해당 기기의 위치정보 및 관련 로그는 지체 없이 삭제되며 장기간 보관하지 않습니다.
- 다만, 관계 법령에서 일정 기간 보존을 의무화하는 정보가 있는 경우에는, 해당 법령에서 정한 기간 동안 최소한의 정보만 별도 보관할 수 있습니다.

5. 개인정보의 제3자 제공 및 처리위탁
- 회사는 이용자의 개인정보를 원칙적으로 외부에 제공하지 않습니다.
- 다만, 법령에 따른 요청 또는 이용자의 동의가 있는 경우에 한하여 예외적으로 제공될 수 있습니다.
- 서비스 운영 및 서버 관리 등을 위하여 외부 업체에 처리를 위탁하는 경우, 위탁받는 자와 그 업무 내용을 별도로 고지합니다.

6. 이용자의 권리
- 이용자는 언제든지 개인정보 열람·정정·삭제를 요청할 수 있습니다.
- 위치정보 수집을 원하지 않는 경우, 앱 내 "주변 스캔 중지" 기능을 사용하거나 앱을 삭제함으로써 수집을 중단할 수 있습니다.
- 권리 행사는 아래 연락처로 요청하실 수 있습니다.

7. 개인정보의 안전성 확보 조치
- 회사는 개인정보의 안전한 처리를 위하여 다음과 같은 조치를 취하고 있습니다.
  · 전송 구간 암호화(HTTPS) 적용
  · 접근권한 관리 및 접속 기록 보관
  · 서버 보안 업데이트 및 취약점 점검

8. 개인정보 보호책임자
- 성명: 권성현
- 이메일: anyhunter63@gmail.com

9. 개인정보처리방침의 변경
- 본 개인정보처리방침은 서비스 운영상 또는 관련 법령 변경에 따라 개정될 수 있습니다.
- 중요한 내용 변경 시 앱 내 공지 또는 별도 안내를 통하여 고지합니다.

시행일자: 2025-11-01
''';

    return Scaffold(
      appBar: AppBar(
        title: const Text('개인정보처리방침'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: Text(
                  policyText,
                  style: TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
