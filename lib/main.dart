import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:safety_guard/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_storage/get_storage.dart';

import 'package:http/http.dart' as http;
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'hunter_map_page.dart';


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

Future<bool> isIgnoringBatteryOptimizations() async {
  if (!Platform.isAndroid) return true;

  try {
    final result = await platform.invokeMethod("isIgnoringBatteryOptimizations");
    return result == true;
  } catch (e) {
    debugPrint("❌ isIgnoringBatteryOptimizations error: $e");
    return false;
  }
}

Future<void> requestIgnoreBatteryOptimizations() async {
  if (!Platform.isAndroid) return;

  try {
    await platform.invokeMethod("requestIgnoreBatteryOptimizations");
  } catch (e) {
    debugPrint("❌ requestIgnoreBatteryOptimizations error: $e");

    try {
      await platform.invokeMethod("openBatteryOptimizationSettings");
    } catch (e2) {
      debugPrint("❌ openBatteryOptimizationSettings error: $e2");
    }
  }
}

Future<bool> isPreciseLocationGranted() async {
  if (!Platform.isAndroid) return true;

  try {
    final result = await platform.invokeMethod('isPreciseLocationGranted');
    return result == true;
  } catch (e) {
    debugPrint('❌ precise location permission check error: $e');
    return false;
  }
}

Future<bool> isNotificationPermissionGranted() async {
  if (!Platform.isAndroid) return true;

  try {
    final result = await platform.invokeMethod('isNotificationPermissionGranted');
    return result == true;
  } catch (e) {
    debugPrint('❌ notification permission check error: $e');
    return false;
  }
}

Future<void> requestNotificationPermission() async {
  if (!Platform.isAndroid) return;

  try {
    await platform.invokeMethod('requestNotificationPermission');
  } catch (e) {
    debugPrint('❌ notification permission request error: $e');
  }
}

Future<void> openNotificationSettings() async {
  if (!Platform.isAndroid) return;

  try {
    await platform.invokeMethod('openNotificationSettings');
  } catch (e) {
    debugPrint('❌ notification settings open error: $e');
    try {
      await Geolocator.openAppSettings();
    } catch (_) {}
  }
}

Future<bool> areAndroidRequiredPermissionsReady() async {
  if (!Platform.isAndroid) return true;

  final locationService = await Geolocator.isLocationServiceEnabled();
  final locationPermission = await Geolocator.checkPermission();
  final preciseLocation = await isPreciseLocationGranted();
  final locationOk = locationService &&
      locationPermission == LocationPermission.always &&
      preciseLocation;

  final notificationOk = await isNotificationPermissionGranted();
  final batteryOk = await isIgnoringBatteryOptimizations();

  return locationOk && notificationOk && batteryOk;
}

class BackgroundLocation {
  static const EventChannel _channel =
      EventChannel("com.civilsafety.app/locationStream");

  static Stream<Map> get stream =>
      _channel.receiveBroadcastStream().map((e) => Map.from(e));
}

class CivilDeviceId {
  static const String _prefKey = 'civil_safety_install_device_id';

  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString(_prefKey);

    if (saved != null && saved.trim().isNotEmpty && !_isBadDeviceId(saved)) {
      return saved.trim();
    }

    final prefix = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
            ? 'ios'
            : 'app';

    final newId = '$prefix-${_makeUuidLike()}';

    await prefs.setString(_prefKey, newId);

    return newId;
  }

  static bool _isBadDeviceId(String value) {
    final v = value.trim();

    if (v.isEmpty) return true;
    if (v == 'IOS-DEVICE') return true;
    if (v.length < 20) return true;

    /*
     * Android Build.ID 예:
     * BP4A.251205.006
     * AP3A.240905.015.A2
     */
    final androidBuildIdPattern =
        RegExp(r'^[A-Z]{2,4}[0-9A-Z]?\.[0-9]{6}\.[0-9]{3}(\.[A-Z0-9]+)?$');

    if (androidBuildIdPattern.hasMatch(v)) return true;

    final lower = v.toLowerCase();
    if (lower == 'android' ||
        lower == 'iphone' ||
        lower == 'ios' ||
        lower == 'unknown' ||
        lower == 'null' ||
        lower == 'device') {
      return true;
    }

    return false;
  }

  static String _makeUuidLike() {
    final r = Random.secure();

    String hex(int length) {
      const chars = '0123456789abcdef';
      final sb = StringBuffer();

      for (int i = 0; i < length; i++) {
        sb.write(chars[r.nextInt(chars.length)]);
      }

      return sb.toString();
    }

    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }
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

  bool _batteryGuideDialogShowing = false;

  Timer? _dangerBlinkTimer;
  bool _isDangerBlinkOn = true;      // true/false 번갈아가며 깜빡임

  String _level = 'SAFE';
  int _distance = -1;

  int _nearCount20 = 0;
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

    _initTts();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Platform.isAndroid) {
        await _clearLegacyBatteryGuideFlag();
      }

      await _initDeviceId();
      await _checkFirstAgreement();

      if (Platform.isAndroid && mounted) {
        await _showRequiredPermissionsIfNeeded(requiredMode: true);
      }
    });
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
    _progressTimer?.cancel();
    _bgLocationSub?.cancel();
    _player.dispose();
    _tts.stop();
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

    // Android는 여기서 동의만 받고, 권한은 '필수 권한 설정' 화면에서 안내한다.
  }

  Future<bool> _showRequiredPermissionsIfNeeded({bool requiredMode = false}) async {
    if (!Platform.isAndroid) return true;

    final ready = await areAndroidRequiredPermissionsReady();
    if (ready) return true;
    if (!mounted) return false;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RequiredPermissionPage(requiredMode: requiredMode),
      ),
    );

    return await areAndroidRequiredPermissionsReady();
  }

  Future<void> _openRequiredPermissionPage() async {
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const RequiredPermissionPage(requiredMode: false),
      ),
    );
  }

  // ----------------------------------------------------------
  // 디바이스 ID
  // ----------------------------------------------------------
Future<void> _initDeviceId() async {
  try {
    _deviceId = await CivilDeviceId.getDeviceId();

    debugPrint('✅ civil deviceId=$_deviceId');

    if (mounted) {
      setState(() {});
    }
  } catch (e) {
    debugPrint('❌ deviceId init error: $e');
  }
}

Future<void> _clearLegacyBatteryGuideFlag() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('battery_optimization_guide_done');
  } catch (e) {
    debugPrint('❌ clear legacy battery guide flag error: $e');
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

Future<bool> _ensureBatteryOptimizationDisabled() async {
  if (!Platform.isAndroid) return true;

  /*
   * 중요:
   * 배터리 제한 상태는 매번 실제 상태를 다시 확인한다.
   * 예전에 설정 화면에 다녀왔다는 이유만으로 통과시키면,
   * 사용자가 나중에 "최적화"로 바꿨을 때 다시 안내가 뜨지 않는다.
   */
  final ignored = await isIgnoringBatteryOptimizations();

  if (ignored) {
    debugPrint('✅ battery optimization ignored');
    return true;
  }

  if (!mounted) return false;

  if (_batteryGuideDialogShowing) {
    return false;
  }

  _batteryGuideDialogShowing = true;

  final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text(
            '배터리 제한 해제 필요',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: const Text(
            '안전을 위해 안전지키미가 화면이 꺼진 상태에서도 계속 동작하려면\n'
            '배터리 사용을 "제한 없음" 또는 "최적화 제외"로 설정해야 합니다.\n\n'
            '설정 화면으로 이동하시겠습니까?\n\n'
            '설정을 마친 뒤 앱으로 돌아와\n'
            '주변 스캔 시작 버튼을 다시 눌러 주세요.',
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

  _batteryGuideDialogShowing = false;

  if (!ok) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("상시 감시를 위해 배터리 사용을 '제한 없음'으로 설정하세요."),
        ),
      );
    }

    return false;
  }

  await requestIgnoreBatteryOptimizations();

  /*
   * 설정 화면으로 이동했으므로 이번 시작은 중단한다.
   * 사용자가 설정 후 앱으로 돌아와 다시 시작 버튼을 누르면
   * isIgnoringBatteryOptimizations()를 다시 확인한다.
   */
  return false;
}

  // ----------------------------------------------------------
  // 스캔 ON/OFF
  // ----------------------------------------------------------
void _toggle() async {
  if (_running) {
    await _stop();
    return;
  }

  if (Platform.isAndroid) {
    final ok = await _showRequiredPermissionsIfNeeded(requiredMode: false);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('필수 권한 설정을 완료해야 주변 스캔을 시작할 수 있습니다.'),
          ),
        );
      }
      return;
    }
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
  }

  await _start();
}

  // 🔹 네이티브 ForegroundService + 타이머 시작
  Future<void> _start() async {
    // 🔊 스캔 시작 안내
    await _speak("안전지키미가 스캔을 시작합니다.");

    // 안드로이드 네이티브 ForegroundService 시작
    await startNativeService();

    // Android는 네이티브 ForegroundService 위치 스트림을 사용한다.
    // iOS는 아래의 주기 체크에서 Geolocator로 현재 위치를 직접 갱신한다.
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
      _nearCount20 = 0;
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

      int within20 = _parseIntField(data['within20']);
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
        if (dist <= 20) level = '주의';
        else if (dist <= 100) level = '위험';
        else if (dist <= 150) level = '경계';
        else if (dist <= 200) level = '주의';
        else if (dist <= 500) level = '관심';
      }

      if (!mounted) return;
      setState(() {
        _level = level;
        _distance = dist;
        _nearCount20 = within20;
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

      await _alertByDistance();
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
      if (Platform.isIOS) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        _lastLat = pos.latitude;
        _lastLng = pos.longitude;
      }

      if (_lastLat == null || _lastLng == null) {
        debugPrint('📍 아직 위치가 없습니다. 다음 주기까지 대기.');
        return;
      }

      await _processSafety(_lastLat!, _lastLng!);
    } catch (e) {
      debugPrint('❌ safety check error: $e');
    }

    if (mounted) {
      setState(() => _progress = 0.0);
    }
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
Future<void> _alertByDistance() async {
  if (!_running) return;

  if (_distance < 0) return;

  /*
   * 20m 이내는 경보 없음.
   * 화면 텍스트만 표시한다.
   * 진동, 비프음, TTS 모두 실행하지 않는다.
   */
  if (_distance <= 20) {
    debugPrint("ℹ️ 20m 이내 → 경보 없이 텍스트만 표시");
    await _stopAllAlerts();
    return;
  }

  /*
   * 150m 이내에 20m 바깥 엽사가 있을 때만 강한 경보.
   */
  if (_nearCount150 > _nearCount20) {
    await _vibrate(high: true);
    await _playBeep();
    await _speak(
      "현재 백오십 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount150)} 있습니다. 즉시 주변을 경계하세요."
    );
    return;
  }

  if (_nearCount200 > 0) {
    await _vibrate(high: true);
    await _playBeep();
    await _speak(
      "현재 이백 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount200)} 있습니다."
    );
    return;
  }

  if (_nearCount500 > 0) {
    await _vibrate(high: false);
    await _speak(
      "현재 오백 미터 이내에 엽사가 ${toKoreanPersonCount(_nearCount500)} 있습니다."
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
      // 혹시 재생 중인 소리 있으면 먼저 정지
      await _player.stop();

      // 짧은 삐 소리 재생
      await _player.play(
        AssetSource('mp3/alarm.mp3'),
      );

      // 삐 소리가 너무 끊기지 않게 약간 기다렸다가 TTS 시작
      await Future.delayed(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint('❌ beep play error: $e');
    }
  }

  // ----------------------------------------------------------
  // UI
  // ----------------------------------------------------------
Color _levelColorByDistance() {
  /*
   * 20m 이내는 최우선.
   * _nearCount500이 0으로 와도 황색 표시가 되도록 가장 먼저 처리한다.
   */
  if (_distance >= 0 && _distance <= 20) {
    return Colors.orange.shade300;
  }

  if (_nearCount20 > 0) {
    return Colors.orange.shade300;
  }

  /*
   * 아무도 없거나 거리값이 없으면 초록
   */
  if (_distance < 0 || _nearCount500 == 0) {
    return Colors.green.shade400;
  }

  /*
   * 150m 이내에 20m 바깥 엽사 존재
   */
  if ((_nearCount150 - _nearCount20) > 0) {
    return Colors.red.shade400;
  }

  /*
   * 200m 이내에 150m 바깥 엽사 존재
   */
  if ((_nearCount200 - _nearCount150) > 0) {
    return Colors.orange.shade400;
  }

  /*
   * 500m 이내
   */
  if (_nearCount500 > 0) {
    return Colors.yellow.shade600;
  }

  return Colors.green.shade400;
}

Widget _buildRangeMessage() {
  /*
   * 20m 이내는 최우선.
   * minDistance가 -1로 와도 within20 값이 있으면 텍스트 표시.
   */
  if (_nearCount20 > 0 || (_distance >= 0 && _distance <= 20)) {
    return Text(
      "20m 이내 엽사 $_nearCount20명",
      style: const TextStyle(fontSize: 15),
    );
  }

  if (_distance < 0) return const SizedBox();

  if (_distance > 500) {
    return const Text(
      "안전구역 500m 내에 엽사 없음",
      style: TextStyle(fontSize: 15),
    );
  }

  if (_distance <= 150) {
    return Text(
      "150m 이내 엽사 $_nearCount150명",
      style: const TextStyle(fontSize: 15),
    );
  }

  if (_distance <= 200) {
    return Text(
      "200m 이내 엽사 $_nearCount200명",
      style: const TextStyle(fontSize: 15),
    );
  }

  return Text(
    "500m 이내 엽사 $_nearCount500명",
    style: const TextStyle(fontSize: 15),
  );
}

  String _distanceText() {
    if (_distance < 0) return "";
    return "가장 근접한 엽사와 약 $_distance m";
  }

String _cautionText() {
  if (_nearCount20 > 0 || (_distance >= 0 && _distance <= 20)) {
    return "초근접거리에 엽사가 있습니다.\n주의하세요";
  }

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
          '제작: Bitgoeul Software\n'
	  '(빛고을소프트웨어)\n\n'
	  'TEL: 062-716-3212\n\n'
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

  Future<void> _openHunterMap() async {
    if (_deviceId.isEmpty) {
      await _initDeviceId();
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HunterMapPage(deviceId: _deviceId),
      ),
    );
  }

  void _showContactDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('고객센터'),
        content: const Text(
          '문의 이메일\n'
          'any-hunter@hanmail.net\n\n'
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                minHeight: constraints.maxHeight,
              ),
              child: IntrinsicHeight(
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
              style: const TextStyle(fontSize: 15),
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
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: SizedBox(
                      height: 58,
                      child: OutlinedButton.icon(
                        onPressed: _openHunterMap,
                        icon: const Icon(Icons.map_outlined, size: 22),
                        label: const Text(
                          '지도보기',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue.shade700,
                          side: BorderSide(
                            color: Colors.blue.shade500,
                            width: 1.5,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(29),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 6,
                    child: SizedBox(
                      height: 58,
                      child: ElevatedButton(
                        onPressed: _toggle,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              _running ? Colors.green.shade700 : Colors.green,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(29),
                          ),
                        ),
                        child: Text(
                          _running ? "주변 스캔 중지" : "주변 스캔 시작",
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _running ? Colors.yellow : Colors.white,
                          ),
                        ),
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
        },
      ),

      // 🔻 하단 푸터: 제작사 / 고객센터 / 개인정보처리방침
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              top: BorderSide(color: Colors.grey.shade300, width: 1),
            ),
          ),
          child: Row(
            children: [
              // 회사정보
              Expanded(
                child: TextButton(
                  onPressed: () => _showCompanyInfo(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.info_outline, size: 18, color: Colors.grey),
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
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.mail_outline, size: 18, color: Colors.grey),
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

              // 권한설정 (Android)
              if (Platform.isAndroid)
                Expanded(
                  child: TextButton(
                    onPressed: _openRequiredPermissionPage,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.admin_panel_settings_outlined,
                          size: 18, color: Colors.grey),
                      SizedBox(height: 2),
                      Text(
                        '권한설정',
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
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.privacy_tip_outlined,
                          size: 18, color: Colors.grey),
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
      ),


    );
  }
}

class RequiredPermissionPage extends StatefulWidget {
  final bool requiredMode;

  const RequiredPermissionPage({
    super.key,
    this.requiredMode = false,
  });

  @override
  State<RequiredPermissionPage> createState() => _RequiredPermissionPageState();
}

class _RequiredPermissionPageState extends State<RequiredPermissionPage>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _locationOk = false;
  bool _notificationOk = false;
  bool _batteryOk = false;
  bool _notificationRequestedOnce = false;

  final ScrollController _scrollController = ScrollController();

  bool get _allOk => _locationOk && _notificationOk && _batteryOk;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future.delayed(const Duration(milliseconds: 300), _refresh);
    }
  }

  Future<void> _refresh() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        setState(() {
          _locationOk = true;
          _notificationOk = true;
          _batteryOk = true;
          _loading = false;
        });
      }
      return;
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final locationPermission = await Geolocator.checkPermission();
      final preciseLocation = await isPreciseLocationGranted();
      final notificationOk = await isNotificationPermissionGranted();
      final batteryOk = await isIgnoringBatteryOptimizations();

      if (!mounted) return;

      setState(() {
        _locationOk = serviceEnabled &&
            locationPermission == LocationPermission.always &&
            preciseLocation;
        _notificationOk = notificationOk;
        _batteryOk = batteryOk;
        _loading = false;
      });
    } catch (e) {
      debugPrint('❌ required permission refresh error: $e');
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reqLocation() async {
    final alreadyOk = _locationOk;

    if (alreadyOk) {
      await _refresh();
      return;
    }

    // 1) 휴대폰 자체 위치(GPS)부터 확인
    bool serviceEnabled = true;

    if (Platform.isAndroid) {
      final serviceStatus = await Permission.locationWhenInUse.serviceStatus;
      serviceEnabled = serviceStatus.isEnabled;
    } else {
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
    }

    if (!serviceEnabled) {
      if (!mounted) return;

      final open = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text(
            '⚠️ 휴대폰 위치 기능을 켜주세요',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            '먼저 휴대폰의 위치(GPS) 기능을 켜야 합니다.\n\n'
            '"위치 켜기"를 누른 후 위치 기능을 켜주세요.',
            style: TextStyle(fontSize: 17, height: 1.5),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('위치 켜기'),
            ),
          ],
        ),
      );

      if (open == true) {
        try {
          await Geolocator.openLocationSettings();
        } catch (_) {}
      }
      return;
    }

    // 2) 먼저 '앱 사용 중' 위치 권한을 시스템 창에서 바로 요청
    var whenInUse = await Permission.locationWhenInUse.status;

    if (!whenInUse.isGranted) {
      whenInUse = await Permission.locationWhenInUse.request();

      if (!whenInUse.isGranted) {
        if (whenInUse.isPermanentlyDenied) {
          if (!mounted) return;

          final open = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text(
                '⚠️ 위치 권한이 필요합니다',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              ),
              content: const Text(
                '위치 권한이 차단되어 있습니다.\n\n'
                '"설정 열기"를 누른 후\n'
                '권한 → 위치 → 항상 허용\n'
                '순서로 설정해 주세요.',
                style: TextStyle(fontSize: 16, height: 1.6),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('설정 열기'),
                ),
              ],
            ),
          );

          if (open == true) {
            await openAppSettings();
          }
        }

        await _refresh();
        return;
      }
    }

    // 3) 이어서 '항상 허용' 요청.
    // Android 11 이상에서는 OS가 안전지키미의 위치 권한 화면으로
    // 직접 연결하므로 사용자는 '항상 허용'만 선택하면 된다.
    final current = await Geolocator.checkPermission();
    final preciseOk = await isPreciseLocationGranted();

    if (current == LocationPermission.always && preciseOk) {
      await _refresh();
      return;
    }

    final alwaysResult = await Permission.locationAlways.request();

    if (alwaysResult.isGranted) {
      await _refresh();
      return;
    }

    // 사용자가 설정 화면에서 돌아오면 lifecycle resumed에서
    // _refresh()가 자동 실행되어 완료 상태가 갱신된다.
    await _refresh();
  }

  Future<void> _reqNotification() async {
    if (_notificationOk) {
      await _refresh();
      return;
    }

    if (!_notificationRequestedOnce) {
      _notificationRequestedOnce = true;
      await requestNotificationPermission();
      await Future.delayed(const Duration(milliseconds: 500));
      await _refresh();

      if (_notificationOk) return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '알림 권한 설정',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '알림 권한이 꺼져 있습니다.\n\n'
          '안전지키미의 백그라운드 동작과 안전 알림을 위해 알림을 허용해 주세요.',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('설정 열기'),
          ),
        ],
      ),
    );
    await openNotificationSettings();
  }

  Future<void> _reqBattery() async {
    if (_batteryOk) {
      await _refresh();
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '배터리 제한 해제',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '화면이 꺼진 상태에서도 안전지키미가 계속 작동하려면 배터리 최적화 제한을 해제해야 합니다.\n\n'
          '다음 화면에서 안전지키미의 배터리 사용을 허용해 주세요.',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('설정하기'),
          ),
        ],
      ),
    );

    await requestIgnoreBatteryOptimizations();
  }

  Widget _tile({
    required String title,
    required String description,
    required bool ok,
    required VoidCallback onPress,
    String buttonText = '허용하기',
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ok ? Colors.green.shade300 : Colors.grey.shade300,
          width: ok ? 1.5 : 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ok ? Colors.green.shade50 : Colors.orange.shade50,
            ),
            alignment: Alignment.center,
            child: Icon(
              ok ? Icons.check_rounded : Icons.priority_high_rounded,
              color: ok ? Colors.green.shade700 : Colors.orange.shade800,
              size: 23,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (ok)
                      const Text(
                        '설정 완료',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: Colors.grey.shade800,
                  ),
                ),
                if (!ok) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onPress,
                      child: Text(buttonText),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.requiredMode || _allOk,
      onPopInvoked: (didPop) {
        if (!didPop && widget.requiredMode && !_allOk) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('안전지키미 사용을 위해 필수 권한 설정을 완료해 주세요.'),
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: Colors.grey.shade100,
        appBar: AppBar(
          automaticallyImplyLeading: !widget.requiredMode,
          title: const Text('⚠️ 필수 권한 설정'),
          actions: [
            IconButton(
              onPressed: _refresh,
              tooltip: '권한 상태 새로고침',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
                    child: Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF8E1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFFFD54F)),
                          ),
                          child: const Text(
                            '아래에서 "허용하기"를 하나씩 눌러주세요.\n'
                            '설정이 끝난 항목은 초록색 ✓ 표시로 바뀝니다.',
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.45,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _tile(
                          title: '위치 권한',
                          description:
                              '주변 수렵인과의 거리 계산과 백그라운드 안전 경보를 위해 필요합니다. "항상 허용"으로 설정하고 "정확한 위치"를 켜주세요.',
                          ok: _locationOk,
                          onPress: _reqLocation,
                        ),
                        _tile(
                          title: '알림 권한',
                          description:
                              '화면이 꺼진 상태에서도 안전지키미의 실행 상태와 안전 알림을 표시하기 위해 필요합니다.',
                          ok: _notificationOk,
                          onPress: _reqNotification,
                        ),
                        _tile(
                          title: '배터리 최적화 예외',
                          description:
                              '백그라운드 위치 확인이 중단되지 않도록 안전지키미의 배터리 제한을 해제합니다.',
                          ok: _batteryOk,
                          onPress: _reqBattery,
                          buttonText: '설정하기',
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: FilledButton.icon(
                            onPressed: _allOk
                                ? () => Navigator.of(context).pop(true)
                                : null,
                            icon: const Icon(Icons.verified_user_outlined),
                            label: Text(
                              _allOk ? '필수 권한 설정 완료' : '위 권한을 먼저 설정해 주세요',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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

// 📄 개인정보처리방침 화면
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    const policyText = '''
[안전지키미 개인정보처리방침]

Bitgoeul Software(이하 "회사")는 안전지키미 서비스 제공을 위하여 아래와 같이 이용자의 개인정보를 수집·이용하며, 개인정보 보호 관련 법령을 준수합니다.

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
- 이메일: any-hunter@hanmail.net
- 전화: 062-716-3212

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
            // 내용 스크롤
            const Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: Text(
                  policyText,
                  style: TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            ),
            // 닫기 버튼
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