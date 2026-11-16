import 'dart:async';

import 'package:flutter/material.dart';

class SlowLoading extends StatefulWidget {
  const SlowLoading({super.key, this.slowAfter = const Duration(seconds: 12)});

  final Duration slowAfter;

  @override
  State<SlowLoading> createState() => _SlowLoadingState();
}

class _SlowLoadingState extends State<SlowLoading> {
  Timer? _timer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.slowAfter, () {
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
          const CircularProgressIndicator(),
          if (_slow) ...<Widget>[
            const SizedBox(height: 14),
            Semantics(
              liveRegion: true,
              child: Text(
                'Still loading. This is taking longer than usual. Check your '
                'connection, or reload the page if it does not finish.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
