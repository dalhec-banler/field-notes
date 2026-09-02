import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The app's one yes/no dialog: title, a serif body, decline on the left.
/// Returns true only on the affirmative — callers never compare to null.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  String cancelLabel = 'CANCEL',
  String confirmLabel = 'OK',
}) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(
        body,
        style: TextStyle(fontFamily: Type.serif, fontSize: 15.5, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return sure == true;
}
