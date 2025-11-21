import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

class SafetyGuide {
  static const _agreeKey = 'agreeSafetyGuide';
  static const _permissionAskedKey = 'locationPermissionAsked'; // ← 추가

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

  /// 이미 위치권한을 요청한 적 있는지?
  static Future<bool> _askedPermission() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_permissionAskedKey) ?? false;
  }

  /// 위치권한을 최초 1회만 요청
  static Future<bool> _requestLocationPermissionOnce() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyAsked = await _askedPermission();

    // 이미 요청했던 경우 → 현재 권한만 확인
    if (alreadyAsked) {
      LocationPermission permission = await Geolocator.checkPermission();
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    }

    // 최초 한 번만 실제 시스템 권한창 요청
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // 최초 요청 플래그 저장
    await prefs.setBool(_permissionAskedKey, true);

    // 최종 권한 결과 반환
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// 안내 다이얼로그
  /// 스크롤 O, 스크롤바 X
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

          /// ❗ 스크롤바 숨긴 스크롤 영역
          content: SizedBox(
            height: 280,
            width: double.maxFinite,
            child: ScrollConfiguration(
              behavior: _NoScrollbarBehavior(),
              child: const SingleChildScrollView(
                child: Text(
                  "이 앱은 사용자 주변에 엽사들의 위치 정보를 이용하여 안전 관련 경보를 제공하는 공공 목적의 앱입니다.\n"
                  "위치 정보 접근이 필요하며 앱은 주기적으로 경보 및 진동을 발생시킬 수 있습니다.\n"
                  "최근 빈번하게 발생하는 총기 오발(오인)사고를 줄이기 위한 목적이며 엽사가 전용앱을 사용하지 않으면 도움이 되지 않습니다.\n"
                  "반드시 거주지역 지자체, 또는 방문하려는 지자체에 엽사들이 전용앱을 사용하는지 확인하세요.\n"
                  "동의하시면 서비스를 계속 이용하실 수 있습니다. 만약 동의하지 않으시면 앱이 종료됩니다.",
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop(false); // 비동의
              },
              child: const Text("동의 안함"),
            ),
            ElevatedButton(
              onPressed: () async {
                // 1) 위치 권한 최초 1회 요청
                await _requestLocationPermissionOnce();

                // 2) 동의 저장
                await setAgreed();

                // 3) 닫기
                Navigator.of(ctx).pop(true);
              },
              child: const Text("동의함"),
            ),
          ],
        );
      },
    ) ?? false;
  }
}

/// 스크롤바를 완전히 숨기는 Behavior
class _NoScrollbarBehavior extends ScrollBehavior {
  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    return child; // 스크롤바 숨김
  }
}
