import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SafetyGuide {
  static const _agreeKey = 'agreeSafetyGuide';

  static Future<bool> isAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_agreeKey) ?? false;
  }

  static Future<void> setAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_agreeKey, true);
  }

  static Future<bool> _requestLocationPermissionIos() async {
    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  static Future<bool> showGuideDialog(BuildContext context) async {
    final isIos = Platform.isIOS;

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              title: const Text(
                '안전지키미 사용 안내',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              content: SizedBox(
                height: 280,
                width: double.maxFinite,
                child: ScrollConfiguration(
                  behavior: _NoScrollbarBehavior(),
                  child: SingleChildScrollView(
                    child: Text(
                      isIos
                          ? '이 앱은 주변 엽사들의 위치 정보를 활용하여\n'
                              '위험 상황을 경고하는 안전 목적의 앱입니다.\n\n'
                              '이 기능을 제공하기 위해서는 위치 권한이 필요합니다.\n'
                              '계속 진행하면 시스템 위치 권한 요청이 표시됩니다.'
                          : '이 앱은 사용자 주변 엽사들의 위치 정보를 이용하여 안전 관련 경보를 제공하는 공공 목적의 앱입니다.\n'
                              '위치 정보 접근이 필요하며 앱은 주기적으로 경보 및 진동을 발생시킬 수 있습니다.\n'
                              '최근 빈번하게 발생하는 총기 오발(오인)사고를 줄이기 위한 목적이며 엽사가 전용앱을 사용하지 않으면 도움이 되지 않습니다.\n'
                              '반드시 거주지역 지자체, 또는 방문하려는 지자체에 엽사들이 전용앱을 사용하는지 확인하세요.\n'
                              '동의하시면 서비스를 계속 이용하실 수 있습니다. 만약 동의하지 않으시면 앱이 종료됩니다.',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
              ),
              actions: isIos
                  ? [
                      ElevatedButton(
                        onPressed: () async {
                          await _requestLocationPermissionIos();
                          await setAgreed();
                          if (ctx.mounted) Navigator.of(ctx).pop(true);
                        },
                        child: const Text('계속'),
                      ),
                    ]
                  : [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('동의 안함'),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          // Android 권한은 동의 직후 별도의 '필수 권한 설정' 화면에서
                          // 한 번에 안내/설정한다.
                          await setAgreed();
                          if (ctx.mounted) Navigator.of(ctx).pop(true);
                        },
                        child: const Text('동의함'),
                      ),
                    ],
            );
          },
        ) ??
        false;
  }
}

class _NoScrollbarBehavior extends ScrollBehavior {
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
