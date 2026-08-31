import 'package:drift/drift.dart' hide Column;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../export/evidence_packet.dart';

import '../db/database.dart';

/// Cost-share program tracking (spec §4.14, §7.10): EQIP / TPWD PUB
/// programs, their practices, and dated activities with costs.
class ProgramsScreen extends StatelessWidget {
  const ProgramsScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  Widget build(BuildContext context) {
    final query = (db.select(db.programs)
      ..where((x) => x.propertyId.equals(property.id))
      ..where((x) => x.deletedAt.isNull())
      ..orderBy([(x) => OrderingTerm.asc(x.name)]));
    return Scaffold(
      appBar: AppBar(title: const Text('Programs')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New program'),
        onPressed: () => _newProgram(context),
      ),
      body: StreamBuilder<List<Program>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final programs = snapshot.data ?? const [];
          if (programs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No programs yet.\n\nTrack EQIP, TPWD PUB, or any cost-share '
                  'contract: practices, deadlines, and what you\'ve completed.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: programs.length,
            itemBuilder: (context, i) => _ProgramTile(
              db: db,
              program: programs[i],
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProgramDetailScreen(
                      db: db, programId: programs[i].id),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _newProgram(BuildContext context) async {
    final nameController = TextEditingController();
    final agencyController = TextEditingController();
    final contractController = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('New program'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                onChanged: (_) => setDialog(() {}),
                decoration: const InputDecoration(
                    labelText: 'Name (e.g. USDA-NRCS EQIP)'),
              ),
              TextField(
                controller: agencyController,
                decoration: const InputDecoration(labelText: 'Agency'),
              ),
              TextField(
                controller: contractController,
                decoration: const InputDecoration(labelText: 'Contract #'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                // Validated inside the dialog (audit M12): a name is needed.
                onPressed: nameController.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Create')),
          ],
        ),
      ),
    );
    if (created != true || nameController.text.trim().isEmpty) return;
    final now = nowUtcIso();
    await db.into(db.programs).insert(ProgramsCompanion.insert(
          id: newId(),
          propertyId: property.id,
          name: nameController.text.trim(),
          agency: Value(agencyController.text.trim().isEmpty
              ? null
              : agencyController.text.trim()),
          contractRef: Value(contractController.text.trim().isEmpty
              ? null
              : contractController.text.trim()),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
  }
}

class _ProgramTile extends StatelessWidget {
  const _ProgramTile(
      {required this.db, required this.program, required this.onTap});

  final FieldNotesDb db;
  final Program program;
  final VoidCallback onTap;

  Future<(int, int)> _progress() async {
    final practices = await (db.select(db.practices)
          ..where((x) => x.programId.equals(program.id))
          ..where((x) => x.deletedAt.isNull()))
        .get();
    final done = practices
        .where((x) => x.status == 'complete' || x.status == 'certified')
        .length;
    return (done, practices.length);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(int, int)>(
      future: _progress(),
      builder: (context, snapshot) {
        final (done, total) = snapshot.data ?? (0, 0);
        return ListTile(
          minTileHeight: 64,
          leading: const CircleAvatar(child: Icon(Icons.assignment_outlined)),
          title: Text(program.name),
          subtitle: Text([
            if (program.agency != null) program.agency!,
            if (program.contractRef != null) '#${program.contractRef}',
            if (total > 0) '$done of $total practices complete',
          ].join(' · ')),
          onTap: onTap,
        );
      },
    );
  }
}

/// Practices within a program: planned amounts, completion, activities.
class ProgramDetailScreen extends StatefulWidget {
  const ProgramDetailScreen(
      {super.key, required this.db, required this.programId});

  final FieldNotesDb db;
  final String programId;

  @override
  State<ProgramDetailScreen> createState() => _ProgramDetailScreenState();
}

class _ProgramDetailScreenState extends State<ProgramDetailScreen> {
  Program? _program;
  List<Practice> _practices = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final program = await (widget.db.select(widget.db.programs)
          ..where((x) => x.id.equals(widget.programId)))
        .getSingleOrNull();
    if (program == null) return;
    final practices = await (widget.db.select(widget.db.practices)
          ..where((x) => x.programId.equals(program.id))
          ..where((x) => x.deletedAt.isNull())
          ..orderBy([(x) => OrderingTerm.asc(x.dueOn)]))
        .get();
    if (mounted) {
      setState(() {
        _program = program;
        _practices = practices;
      });
    }
  }

  /// Build the evidence packet and hand it to the share sheet. Leaving the
  /// device is exactly the point of this document, and it happens only on
  /// this explicit tap.
  Future<void> _sharePacket() async {
    final program = _program;
    if (program == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
        const SnackBar(content: Text('Building the evidence packet…')));
    try {
      final property = await (widget.db.select(widget.db.properties)
            ..where((x) => x.id.equals(program.propertyId)))
          .getSingle();
      final bytes = await EvidencePacket(widget.db).build(property, program);
      final docs = await getApplicationDocumentsDirectory();
      final reports = Directory(p.join(docs.path, 'reports'))
        ..createSync(recursive: true);
      final safeName = program.name
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
          .toLowerCase();
      final file = File(p.join(reports.path,
          'evidence-$safeName-${nowUtcIso().substring(0, 10)}.pdf'));
      file.writeAsBytesSync(bytes);
      messenger.hideCurrentSnackBar();
      await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path)],
          text: 'Evidence packet — ${program.name}'));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
          SnackBar(content: Text('Could not build the packet: $e')));
    }
  }

  Future<void> _addPractice() async {
    final program = _program!;
    final codeController = TextEditingController();
    final nameController = TextEditingController();
    final amountController = TextEditingController();
    final unitController = TextEditingController(text: 'acres');
    DateTime? dueOn;
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('New practice'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: codeController,
                  decoration: const InputDecoration(
                      labelText: 'NRCS code (e.g. 315, 338, 645)'),
                ),
                TextField(
                  controller: nameController,
                  onChanged: (_) => setDialog(() {}),
                  decoration: const InputDecoration(
                      labelText: 'Name (e.g. Brush management)'),
                ),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Planned amount'),
                ),
                TextField(
                  controller: unitController,
                  decoration: const InputDecoration(
                      labelText: 'Unit (acres, feet, each)'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(dueOn == null
                      ? 'Due date (optional)'
                      : 'Due ${dueOn!.toIso8601String().substring(0, 10)}'),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2040),
                    );
                    if (picked != null) setDialog(() => dueOn = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                // Validated inside the dialog (audit M12): a name is needed.
                onPressed: nameController.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Add')),
          ],
        ),
      ),
    );
    if (created != true || nameController.text.trim().isEmpty) return;
    final now = nowUtcIso();
    final unit = unitController.text.trim();
    await widget.db.into(widget.db.practices).insert(PracticesCompanion.insert(
          id: newId(),
          propertyId: program.propertyId,
          programId: Value(program.id),
          practiceCode: Value(codeController.text.trim().isEmpty
              ? null
              : codeController.text.trim()),
          name: nameController.text.trim(),
          plannedAmount:
              Value(double.tryParse(amountController.text.trim())),
          // Blank unit is "none", not an empty string.
          unit: Value(unit.isEmpty ? null : unit),
          dueOn: Value(dueOn?.toIso8601String().substring(0, 10)),
          status: const Value('planned'),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
    _load();
  }

  Future<void> _logActivity(Practice practice) async {
    final typeController = TextEditingController();
    final amountController = TextEditingController();
    final costController = TextEditingController();
    var complete = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('Activity — ${practice.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: typeController,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'What was done (herbicide, seeding…)'),
              ),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: 'Amount (${practice.unit ?? 'units'})'),
              ),
              TextField(
                controller: costController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Cost (\$)'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Practice is now complete'),
                value: complete,
                onChanged: (v) => setDialog(() => complete = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Log')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final now = nowUtcIso();
    final amount = double.tryParse(amountController.text.trim());
    await widget.db
        .into(widget.db.practiceActivities)
        .insert(PracticeActivitiesCompanion.insert(
          id: newId(),
          propertyId: practice.propertyId,
          practiceId: practice.id,
          occurredOn: now.substring(0, 10),
          activityType: Value(typeController.text.trim().isEmpty
              ? null
              : typeController.text.trim()),
          amount: Value(amount),
          unit: Value(practice.unit),
          costUsd: Value(double.tryParse(costController.text.trim())),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
    final newCompleted = (practice.completedAmount ?? 0) + (amount ?? 0);
    // A finished practice stays finished: logging a follow-up activity on a
    // complete/certified practice must not drag it back to in-progress.
    final alreadyDone =
        practice.status == 'complete' || practice.status == 'certified';
    final Value<String?> status = complete
        ? const Value('complete')
        : alreadyDone
            ? const Value.absent()
            : const Value('in_progress');
    await (widget.db.update(widget.db.practices)
          ..where((x) => x.id.equals(practice.id)))
        .write(PracticesCompanion(
      completedAmount: Value(newCompleted),
      completedOn: complete ? Value(now.substring(0, 10)) : const Value.absent(),
      status: status,
      updatedAt: Value(now),
    ));
    _load();
  }

  Color _statusColor(String? s) => switch (s) {
        'complete' || 'certified' => Colors.green.shade700,
        'in_progress' => Colors.orange.shade800,
        'cancelled' => Colors.grey,
        _ => Colors.blueGrey,
      };

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(program.name),
        actions: [
          // The moneymaker (audit 2026-08-31): the program's field record,
          // formatted for the agency desk, out through the share sheet.
          IconButton(
            tooltip: 'Evidence packet',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _sharePacket,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_task),
        label: const Text('Add practice'),
        onPressed: _addPractice,
      ),
      body: _practices.isEmpty
          ? const Center(child: Text('No practices yet.'))
          : ListView.builder(
              itemCount: _practices.length,
              itemBuilder: (context, i) {
                final pr = _practices[i];
                final planned = pr.plannedAmount;
                final completed = pr.completedAmount ?? 0;
                return ListTile(
                  minTileHeight: 64,
                  leading: CircleAvatar(
                    backgroundColor: _statusColor(pr.status).withAlpha(40),
                    child: Text(
                      pr.practiceCode ?? '—',
                      style: TextStyle(
                          fontSize: 12, color: _statusColor(pr.status)),
                    ),
                  ),
                  title: Text(pr.name),
                  subtitle: Text([
                    if (planned != null)
                      '${completed.toStringAsFixed(completed % 1 == 0 ? 0 : 1)}'
                          '/${planned.toStringAsFixed(planned % 1 == 0 ? 0 : 1)} '
                          '${pr.unit ?? ''}',
                    pr.status ?? 'planned',
                    if (pr.dueOn != null) 'due ${pr.dueOn}',
                  ].join(' · ')),
                  trailing: const Icon(Icons.add_circle_outline),
                  onTap: () => _logActivity(pr),
                );
              },
            ),
    );
  }
}
