import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

const Duration kStillLoadingAfter = Duration(seconds: 10);

class StillLoadingIndicator extends StatefulWidget {
  const StillLoadingIndicator({
    super.key,
    this.after = kStillLoadingAfter,
    this.color,
  });

  final Duration after;
  final Color? color;

  @override
  State<StillLoadingIndicator> createState() => _StillLoadingIndicatorState();
}

class _StillLoadingIndicatorState extends State<StillLoadingIndicator> {
  Timer? _timer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.after, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(color: widget.color),
          if (_slow) ...<Widget>[
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Still loading. Your signal may be weak. You can wait or go back and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.textGrey),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
