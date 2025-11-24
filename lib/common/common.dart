import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

class SafetyGuide {
  static const _agreeKey = 'agreeSafetyGuide';

  /// 이미 동의했는지 여부
  static Future<bool> isAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_agreeKey) ?? false;
  }

  /// 동의 저장
  static Future<void> setAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_agreeKey, true);
  }

  /// 위치권한 요청 (항상 실행)
  static Future<bool> requestLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // 최종 권한 결과 반환
    return permission == LocationPermission.always ||
           permission == LocationPermission.whileInUse;
  }

  /// 애플 가이드라인 통과용 안내 다이얼로그
  static Future<bool> showGuideDialog(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text(
            "안전지키미 사용 안내",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),

          content: SizedBox(
            height: 280,
            width: double.maxFinite,
            child: ScrollConfiguration(
              behavior: _NoScrollbarBehavior(),
              child: const SingleChildScrollView(
                child: Text(
                  "이 앱은 주변 엽사들의 위치 정보를 활용하여\n"
                  "위험 상황을 경고하는 안전 목적의 앱입니다.\n\n"
                  "이 기능을 제공하기 위해서는 위치 권한이 필요합니다.\n"
                  "계속 진행하면 시스템 위치 권한 요청이 표시됩니다.",
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),

          actions: [
            ElevatedButton(
              onPressed: () async {
                // 안내 후 즉시 시스템 권한 요청
                await requestLocationPermission();

                // 동의 저장
                await setAgreed();

                Navigator.of(ctx).pop(true);
              },
              child: const Text("계속"),
            ),
          ],
        );
      },
    ) ?? false;
  }
}

class _NoScrollbarBehavior extends ScrollBehavior {
  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    return child; // 스크롤바 숨김
  }
}
