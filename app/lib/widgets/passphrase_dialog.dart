import 'package:flutter/material.dart';

/// The backup passphrase, asked once — the keyring caches the data key.
Future<String?> askPassphraseDialog(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('BACKUP PASSPHRASE'),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        onSubmitted: (v) => Navigator.pop(ctx, v),
        decoration: const InputDecoration(labelText: 'Passphrase'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('CONTINUE'),
        ),
      ],
    ),
  );
}
