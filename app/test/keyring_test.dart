import 'dart:typed_data';

import 'package:field_notes/backup/keyring.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Small KDF params: tests exercise correctness, not hardness.
  Future<BackupKeyring> create(String pass) =>
      BackupKeyring.create(pass, memoryKiB: 256, iterations: 1);

  test('creation yields a 12-word recovery phrase and sealed fields',
      () async {
    final keyring = await create('correct horse');
    expect(keyring.recoveryPhrase!.split(' ').length, 12);
    expect(keyring.envelopeFields['scheme'], 'keyring-v1');
    expect(keyring.envelopeFields['wrap_pass'], isNotNull);
    expect(keyring.envelopeFields['wrap_rec'], isNotNull);
  });

  test('passphrase unlock produces the same data key', () async {
    final keyring = await create('correct horse');
    final data = Uint8List.fromList(List.generate(100, (i) => i));
    final sealed = await keyring.cipher.seal(data);

    final unlocked = await BackupKeyring.unlockWithPassphrase(
        Map<String, dynamic>.from(keyring.envelopeFields), 'correct horse');
    expect(await unlocked.cipher.open(sealed), data);
  });

  test('recovery phrase ALONE unlocks the backup (spec §11.6)', () async {
    final keyring = await create('correct horse');
    final data = Uint8List.fromList(List.generate(100, (i) => 255 - i));
    final sealed = await keyring.cipher.seal(data);

    final unlocked = await BackupKeyring.unlockWithRecoveryPhrase(
        Map<String, dynamic>.from(keyring.envelopeFields),
        keyring.recoveryPhrase!);
    expect(await unlocked.cipher.open(sealed), data);
  });

  test('wrong passphrase and wrong phrase both fail', () async {
    final keyring = await create('correct horse');
    final fields = Map<String, dynamic>.from(keyring.envelopeFields);
    expect(() => BackupKeyring.unlockWithPassphrase(fields, 'battery staple'),
        throwsA(anything));
    expect(
        () => BackupKeyring.unlockWithRecoveryPhrase(
            fields, 'abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon abandon about'),
        throwsA(anything));
  });

  test('recovery phrase is case/whitespace tolerant', () async {
    final keyring = await create('correct horse');
    final data = Uint8List.fromList([1, 2, 3]);
    final sealed = await keyring.cipher.seal(data);
    final sloppy = '  ${keyring.recoveryPhrase!.toUpperCase()}  ';
    final unlocked = await BackupKeyring.unlockWithRecoveryPhrase(
        Map<String, dynamic>.from(keyring.envelopeFields), sloppy);
    expect(await unlocked.cipher.open(sealed), data);
  });
}
