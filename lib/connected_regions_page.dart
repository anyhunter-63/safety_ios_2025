import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ConnectedRegionsPage extends StatefulWidget {
  const ConnectedRegionsPage({super.key});

  @override
  State<ConnectedRegionsPage> createState() => _ConnectedRegionsPageState();
}

class _ConnectedRegionsPageState extends State<ConnectedRegionsPage> {
  static final Uri _endpoint =
      Uri.parse('https://m.kowildlife.com/BIO/civil_safety_regions.php');

  bool _loading = true;
  String? _error;
  String _asOf = '';
  List<_ConnectedRegion> _regions = const [];

  static const List<String> _groupOrder = [
    '수도권',
    '강원권',
    '충청권',
    '전라권',
    '경상권',
    '제주권',
    '기타',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final response = await http
          .get(
            _endpoint,
            headers: const {
              'Accept': 'application/json',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        throw Exception('invalid response');
      }

      final raw = decoded['regions'];
      final regions = <_ConnectedRegion>[];

      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            regions.add(
              _ConnectedRegion.fromJson(
                Map<String, dynamic>.from(item),
              ),
            );
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _regions = regions;
        _asOf = (decoded['asOf'] ?? '').toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '연동 지자체 정보를 불러오지 못했습니다.\n잠시 후 다시 시도해 주세요.';
      });
    }
  }

  Map<String, List<_ConnectedRegion>> get _grouped {
    final result = <String, List<_ConnectedRegion>>{};

    for (final region in _regions) {
      result.putIfAbsent(region.group, () => []).add(region);
    }

    return result;
  }

  IconData _iconForGroup(String group) {
    switch (group) {
      case '수도권':
        return Icons.apartment_rounded;
      case '강원권':
        return Icons.terrain_rounded;
      case '충청권':
        return Icons.park_rounded;
      case '전라권':
        return Icons.grass_rounded;
      case '경상권':
        return Icons.landscape_rounded;
      case '제주권':
        return Icons.waves_rounded;
      default:
        return Icons.place_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1C2528),
        elevation: 0.8,
        centerTitle: true,
        title: const Text(
          '연동지자체',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const _LoadingView()
            : _error != null
                ? _ErrorView(message: _error!, onRetry: _load)
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 17),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF0F766E),
                              Color(0xFF22A55A),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x220F766E),
                              blurRadius: 18,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.18),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.hub_rounded,
                                color: Colors.white,
                                size: 29,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '현재 안전지키미 연동 지자체',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_regions.length}곳',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 30,
                                      height: 1.1,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_asOf.isNotEmpty)
                              Text(
                                '$_asOf 기준',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.85),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF5F1),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 20,
                              color: Color(0xFF0F766E),
                            ),
                            SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                '현재 야생생물관리시스템과 안전지키미가 연동되는 지역만 표시합니다.',
                                style: TextStyle(
                                  color: Color(0xFF35524E),
                                  fontSize: 13,
                                  height: 1.45,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (_regions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 50),
                          child: Center(
                            child: Text(
                              '현재 연동 중인 지자체가 없습니다.',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                        )
                      else
                        for (final group in _groupOrder)
                          if ((grouped[group] ?? const []).isNotEmpty) ...[
                            _RegionGroupCard(
                              title: group,
                              icon: _iconForGroup(group),
                              regions: grouped[group]!,
                            ),
                            const SizedBox(height: 12),
                          ],
                      const SizedBox(height: 4),
                      Text(
                        '연동 지자체 목록은 자동 갱신됩니다.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.black45,
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _RegionGroupCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<_ConnectedRegion> regions;

  const _RegionGroupCard({
    required this.title,
    required this.icon,
    required this.regions,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE3E9EA)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: Color(0xFFE9F6EF),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: const Color(0xFF18864B), size: 20),
              ),
              const SizedBox(width: 9),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF263238),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F4F5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${regions.length}곳',
                  style: const TextStyle(
                    color: Color(0xFF607D8B),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final region in regions)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7FAF8),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: const Color(0xFFD9E7DF)),
                  ),
                  child: Text(
                    region.displayName,
                    style: const TextStyle(
                      color: Color(0xFF30443F),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 180),
        Center(child: CircularProgressIndicator()),
        SizedBox(height: 14),
        Center(child: Text('연동 지자체 정보를 확인하고 있습니다.')),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.cloud_off_rounded, size: 54, color: Colors.black38),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, height: 1.45),
        ),
        const SizedBox(height: 18),
        Center(
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('다시 불러오기'),
          ),
        ),
      ],
    );
  }
}

class _ConnectedRegion {
  final String instCd;
  final String name;
  final String displayName;
  final String sido;
  final String group;

  const _ConnectedRegion({
    required this.instCd,
    required this.name,
    required this.displayName,
    required this.sido,
    required this.group,
  });

  factory _ConnectedRegion.fromJson(Map<String, dynamic> json) {
    return _ConnectedRegion(
      instCd: (json['instCd'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      displayName: (json['displayName'] ?? json['name'] ?? '').toString(),
      sido: (json['sido'] ?? '').toString(),
      group: (json['group'] ?? '기타').toString(),
    );
  }
}
