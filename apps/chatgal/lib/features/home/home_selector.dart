import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';

/// Three equal cards: package | save | start. Dark filled bases.
class HomeSelector extends StatelessWidget {
  const HomeSelector({
    super.key,
    required this.theme,
    required this.packageName,
    required this.saveLabel,
    required this.onPackageTap,
    required this.onSaveTap,
    required this.onStart,
  });

  final ChatGalTheme theme;
  final String packageName;
  final String saveLabel;
  final VoidCallback onPackageTap;
  final VoidCallback onSaveTap;
  final VoidCallback? onStart;

  /// Unified outer radius for home large rounded rects.
  static const double outerRadius = 24;
  static const double innerRadius = 14;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final dark = t.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: _SelectCard(
              dark: dark,
              title: '内容包',
              value: packageName,
              onTap: onPackageTap,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SelectCard(
              dark: dark,
              title: '存档',
              value: saveLabel,
              onTap: onSaveTap,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StartCard(
              dark: dark,
              enabled: onStart != null,
              onTap: onStart,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectCard extends StatelessWidget {
  const _SelectCard({
    required this.dark,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final Color dark;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: dark,
      borderRadius: BorderRadius.circular(HomeSelector.outerRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(HomeSelector.outerRadius),
        onTap: onTap,
        child: SizedBox(
          height: 96,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
            child: Column(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.92),
                      borderRadius:
                          BorderRadius.circular(HomeSelector.innerRadius),
                    ),
                    child: Text(
                      value,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF333333),
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StartCard extends StatelessWidget {
  const _StartCard({
    required this.dark,
    required this.enabled,
    required this.onTap,
  });

  final Color dark;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? dark : dark.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(HomeSelector.outerRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(HomeSelector.outerRadius),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: 96,
          child: Center(
            child: Text(
              '开始',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: enabled ? Colors.white : Colors.white54,
                letterSpacing: 4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
