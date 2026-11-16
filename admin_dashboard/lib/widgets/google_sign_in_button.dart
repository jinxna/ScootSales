import 'package:flutter/material.dart';

class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  static const Color _ink = Color(0xFF1F1F1F);
  static const Color _outline = Color(0xFF747775);

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 48,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: _ink,
        disabledBackgroundColor: Colors.white,
        side: const BorderSide(color: _outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Opacity(
            opacity: onPressed == null ? 0.38 : 1,
            child: Image.asset(
              'assets/images/google_g.png',
              width: 18,
              height: 18,
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(width: 10),
          const Text('Continue with Google'),
        ],
      ),
    ),
  );
}
