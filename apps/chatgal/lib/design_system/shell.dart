import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';

class ChatGalShell extends StatelessWidget {
  const ChatGalShell({
    super.key,
    required this.theme,
    required this.title,
    required this.body,
    this.actions,
  });

  final ChatGalTheme theme;
  final String title;
  final Widget body;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme.toThemeData(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(title, style: TextStyle(color: theme.ink)),
          actions: actions,
        ),
        body: body,
      ),
    );
  }
}
