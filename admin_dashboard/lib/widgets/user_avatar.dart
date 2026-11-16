import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/dso_theme.dart';
import 'avatar_storage.dart';

class DsoUserAvatar extends StatelessWidget {
  const DsoUserAvatar({
    super.key,
    required this.initial,
    required this.size,
    this.uid,
  });

  final String initial;
  final double size;
  final String? uid;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: UserAvatarStorage.revision,
      builder: (BuildContext context, int _, Widget? child) {
        final String? encoded = UserAvatarStorage.read(uid ?? '');
        Uint8List? bytes;
        if (encoded != null && encoded.isNotEmpty) {
          try {
            bytes = base64Decode(encoded);
          } catch (_) {
            bytes = null;
          }
        }
        return Container(
          width: size,
          height: size,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: context.dso.brandSurface,
            shape: BoxShape.circle,
          ),
          child: bytes == null
              ? Center(
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: size * 0.42,
                      fontWeight: FontWeight.w700,
                      color: DsoTokens.green600,
                    ),
                  ),
                )
              : Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(
                    child: Text(
                      initial,
                      style: TextStyle(
                        fontSize: size * 0.42,
                        fontWeight: FontWeight.w700,
                        color: DsoTokens.green600,
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
