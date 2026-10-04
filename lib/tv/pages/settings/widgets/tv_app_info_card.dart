import 'package:flutter/material.dart';
import 'package:kazumi/request/config/api_endpoints.dart';

/// TV 应用信息卡片
class TVAppInfoCard extends StatelessWidget {
  const TVAppInfoCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Kazumi',
            style: TextStyle(
              color: Color(0xFFfb7299),
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '版本 ${ApiEndpoints.version}',
            style: TextStyle(
              color: Colors.white.withAlpha(180),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'API ${ApiEndpoints.apiLevel}',
            style: TextStyle(
              color: Colors.white.withAlpha(120),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
