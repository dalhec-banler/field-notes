import 'package:drift/drift.dart' hide Column;

import '../theme/tokens.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../export/evidence_packet.dart';

import '../db/database.dart';
import '../services/desk.dart';
import '../widgets/edit_sheet.dart';

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
                  builder: (_) =>
                      ProgramDetailScreen(db: db, programId: programs[i].id),
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
                  labelText: 'Name (e.g. USDA-NRCS EQIP)',
                ),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              // Validated inside the dialog (audit M12): a name is needed.
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (created != true || nameController.text.trim().isEmpty) return;
    final now = nowUtcIso();
    await db
        .into(db.programs)
        .insert(
          ProgramsCompanion.insert(
            id: newId(),
            propertyId: property.id,
            name: nameController.text.trim(),
            agency: Value(
              agencyController.text.trim().isEmpty
                  ? null
                  : agencyController.text.trim(),
            ),
            contractRef: Value(
              contractController.text.trim().isEmpty
                  ? null
                  : contractController.text.trim(),
            ),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
  }
}

class _ProgramTile extends StatelessWidget {
  const _ProgramTile({
    required this.db,
    required this.program,
    required this.onTap,
  });

  final FieldNotesDb db;
  final Program program;
  final VoidCallback onTap;

  Future<(int, int)> _progress() async {
    final practices =
        await (db.select(db.practices)
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
          subtitle: Text(
            [
              if (program.agency != null) program.agency!,
              if (program.contractRef != null) '#${program.contractRef}',
              if (total > 0) '$done of $total practices complete',
            ].join(' · '),
          ),
          onTap: onTap,
        );
      },
    );
  }
}

/// Practices within a program: planned amounts, completion, activities.
class ProgramDetailScreen extends StatefulWidget {
  const ProgramDetailScreen({
    super.key,
    required this.db,
    required this.programId,
  });

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
    final program = await (widget.db.select(
      widget.db.programs,
    )..where((x) => x.id.equals(widget.programId))).getSingleOrNull();
    if (program == null) return;
    final practices =
        await (widget.db.select(widget.db.practices)
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
      const SnackBar(content: Text('Building the evidence packet…')),
    );
    try {
      final property = await (widget.db.select(
        widget.db.properties,
      )..where((x) => x.id.equals(program.propertyId))).getSingle();
      final bytes = await EvidencePacket(widget.db).build(property, program);
      final docs = await getApplicationDocumentsDirectory();
      final reports = Directory(p.join(docs.path, 'reports'))
        ..createSync(recursive: true);
      final safeName = program.name
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
          .toLowerCase();
      final file = File(
        p.join(
          reports.path,
          'evidence-$safeName-${nowUtcIso().substring(0, 10)}.pdf',
        ),
      );
      file.writeAsBytesSync(bytes);
      messenger.hideCurrentSnackBar();
      final at = await deliverFile(
        file.path,
        text: 'Evidence packet — ${program.name}',
      );
      if (at != null && isDesk) {
        messenger.showSnackBar(SnackBar(content: Text('Saved to $at.')));
      }
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('Could not build the packet: $e')),
      );
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
                    labelText: 'NRCS code (e.g. 315, 338, 645)',
                  ),
                ),
                TextField(
                  controller: nameController,
                  onChanged: (_) => setDialog(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Name (e.g. Brush management)',
                  ),
                ),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Planned amount',
                  ),
                ),
                TextField(
                  controller: unitController,
                  decoration: const InputDecoration(
                    labelText: 'Unit (acres, feet, each)',
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(
                    dueOn == null
                        ? 'Due date (optional)'
                        : 'Due ${dueOn!.toIso8601String().substring(0, 10)}',
                  ),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              // Validated inside the dialog (audit M12): a name is needed.
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (created != true || nameController.text.trim().isEmpty) return;
    final now = nowUtcIso();
    final unit = unitController.text.trim();
    await widget.db
        .into(widget.db.practices)
        .insert(
          PracticesCompanion.insert(
            id: newId(),
            propertyId: program.propertyId,
            programId: Value(program.id),
            practiceCode: Value(
              codeController.text.trim().isEmpty
                  ? null
                  : codeController.text.trim(),
            ),
            name: nameController.text.trim(),
            plannedAmount: Value(double.tryParse(amountController.text.trim())),
            // Blank unit is "none", not an empty string.
            unit: Value(unit.isEmpty ? null : unit),
            dueOn: Value(dueOn?.toIso8601String().substring(0, 10)),
            status: const Value('planned'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
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
                  labelText: 'What was done (herbicide, seeding…)',
                ),
              ),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Amount (${practice.unit ?? 'units'})',
                ),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Log'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final now = nowUtcIso();
    final amount = double.tryParse(amountController.text.trim());
    await widget.db
        .into(widget.db.practiceActivities)
        .insert(
          PracticeActivitiesCompanion.insert(
            id: newId(),
            propertyId: practice.propertyId,
            practiceId: practice.id,
            occurredOn: now.substring(0, 10),
            activityType: Value(
              typeController.text.trim().isEmpty
                  ? null
                  : typeController.text.trim(),
            ),
            amount: Value(amount),
            unit: Value(practice.unit),
            costUsd: Value(double.tryParse(costController.text.trim())),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
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
    await (widget.db.update(
      widget.db.practices,
    )..where((x) => x.id.equals(practice.id))).write(
      PracticesCompanion(
        completedAmount: Value(newCompleted),
        completedOn: complete
            ? Value(now.substring(0, 10))
            : const Value.absent(),
        status: status,
        updatedAt: Value(now),
      ),
    );
    _load();
  }

  Color _statusColor(String? s) => programStatusColor(s);

  static const _practiceStatuses = [
    ('planned', 'Planned'),
    ('in_progress', 'In progress'),
    ('complete', 'Complete'),
    ('certified', 'Certified'),
    ('cancelled', 'Cancelled'),
  ];

  Future<void> _editProgram() async {
    final p = _program!;
    final r = await showEditSheet(
      context,
      title: 'Edit program',
      fields: [
        TextEdit('name', 'Name', initial: p.name, required: true),
        TextEdit('agency', 'Agency', initial: p.agency),
        TextEdit('contract', 'Contract #', initial: p.contractRef),
        TextEdit('contact', 'Contact name', initial: p.contactName),
        TextEdit('email', 'Contact email', initial: p.contactEmail),
        DateEdit('starts', 'Starts on', initial: p.startsOn),
        DateEdit('ends', 'Ends on', initial: p.endsOn),
        TextEdit('notes', 'Notes', initial: p.notes, lines: 3),
      ],
      deleteTitle: 'DELETE THIS PROGRAM?',
      deleteBody:
          'Its practices and activities stay on disk; the program '
          'leaves the list.',
    );
    if (r == null) return;
    final now = nowUtcIso();
    final q = widget.db.update(widget.db.programs)
      ..where((x) => x.id.equals(p.id));
    if (r.deleted) {
      await q.write(
        ProgramsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      if (mounted) Navigator.pop(context);
      return;
    }
    await q.write(
      ProgramsCompanion(
        name: Value(r.text('name') ?? p.name),
        agency: Value(r.text('agency')),
        contractRef: Value(r.text('contract')),
        contactName: Value(r.text('contact')),
        contactEmail: Value(r.text('email')),
        startsOn: Value(r.day('starts')),
        endsOn: Value(r.day('ends')),
        notes: Value(r.text('notes')),
        updatedAt: Value(now),
      ),
    );
    _load();
  }

  Future<void> _editPractice(Practice pr) async {
    final r = await showEditSheet(
      context,
      title: 'Edit practice',
      fields: [
        TextEdit('code', 'NRCS code', initial: pr.practiceCode),
        TextEdit('name', 'Name', initial: pr.name, required: true),
        NumberEdit(
          'planned',
          'Planned amount',
          initial: pr.plannedAmount,
          decimal: true,
        ),
        TextEdit('unit', 'Unit', initial: pr.unit),
        DateEdit('start', 'Planned start', initial: pr.plannedStart),
        DateEdit('due', 'Due on', initial: pr.dueOn),
        ChoiceEdit(
          'status',
          'Status',
          options: _practiceStatuses,
          initial: pr.status,
          allowNone: true,
        ),
        TextEdit('notes', 'Notes', initial: pr.notes, lines: 2),
      ],
      deleteTitle: 'DELETE THIS PRACTICE?',
    );
    if (r == null) return;
    final now = nowUtcIso();
    final q = widget.db.update(widget.db.practices)
      ..where((x) => x.id.equals(pr.id));
    if (r.deleted) {
      await q.write(
        PracticesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
    } else {
      await q.write(
        PracticesCompanion(
          practiceCode: Value(r.text('code')),
          name: Value(r.text('name') ?? pr.name),
          plannedAmount: Value(r.number('planned')),
          unit: Value(r.text('unit')),
          plannedStart: Value(r.day('start')),
          dueOn: Value(r.day('due')),
          status: Value(r.text('status')),
          notes: Value(r.text('notes')),
          updatedAt: Value(now),
        ),
      );
    }
    _load();
  }

  /// What was done under a practice, one row each — the sum the row
  /// shows is made of these, and each is a thing that can be corrected.
  Future<void> _activities(Practice pr) async {
    final rows =
        await (widget.db.select(widget.db.practiceActivities)
              ..where((a) => a.practiceId.equals(pr.id))
              ..where((a) => a.deletedAt.isNull())
              ..orderBy([(a) => OrderingTerm.desc(a.occurredOn)]))
            .get();
    if (!mounted) return;
    String amount(double? v) =>
        v == null ? '—' : (v == v.roundToDouble() ? '${v.round()}' : '$v');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(pr.name, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${rows.length} activit${rows.length == 1 ? 'y' : 'ies'}'
              '${pr.unit != null ? ' · ${pr.unit}' : ''}',
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Text('Nothing logged under this practice yet.')
            else
              for (final a in rows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text(
                    '${a.occurredOn} · ${a.activityType ?? 'activity'}',
                  ),
                  subtitle: Text(
                    [
                      '${amount(a.amount)} ${a.unit ?? ''}'.trim(),
                      if (a.costUsd != null) '\$${amount(a.costUsd)}',
                      if (a.contractor != null) a.contractor!,
                    ].join(' · '),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _editActivity(pr, a);
                  },
                ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _logActivity(pr);
                },
                child: const Text('LOG ACTIVITY'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editActivity(Practice pr, PracticeActivity a) async {
    final r = await showEditSheet(
      context,
      title: 'Edit activity',
      fields: [
        DateEdit('on', 'Done on', initial: a.occurredOn),
        TextEdit('type', 'What was done', initial: a.activityType),
        NumberEdit(
          'amount',
          'Amount (${pr.unit ?? 'units'})',
          initial: a.amount,
          decimal: true,
        ),
        NumberEdit('cost', 'Cost (\$)', initial: a.costUsd, decimal: true),
        TextEdit('contractor', 'Contractor', initial: a.contractor),
        TextEdit('notes', 'Notes', initial: a.notes, lines: 2),
      ],
      deleteTitle: 'DELETE THIS ACTIVITY?',
      deleteBody: 'The practice\'s completed amount is recounted without it.',
    );
    if (r == null) return;
    final now = nowUtcIso();
    final q = widget.db.update(widget.db.practiceActivities)
      ..where((x) => x.id.equals(a.id));
    if (r.deleted) {
      await q.write(
        PracticeActivitiesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
    } else {
      await q.write(
        PracticeActivitiesCompanion(
          occurredOn: Value(r.day('on') ?? a.occurredOn),
          activityType: Value(r.text('type')),
          amount: Value(r.number('amount')),
          costUsd: Value(r.number('cost')),
          contractor: Value(r.text('contractor')),
          notes: Value(r.text('notes')),
          updatedAt: Value(now),
        ),
      );
    }
    // completed_amount is the sum of what's logged — recount, don't drift.
    final live =
        await (widget.db.select(widget.db.practiceActivities)
              ..where((x) => x.practiceId.equals(pr.id))
              ..where((x) => x.deletedAt.isNull()))
            .get();
    final total = live.fold<double>(0, (s, x) => s + (x.amount ?? 0));
    await (widget.db.update(
      widget.db.practices,
    )..where((x) => x.id.equals(pr.id))).write(
      PracticesCompanion(completedAmount: Value(total), updatedAt: Value(now)),
    );
    _load();
  }

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
          IconButton(
            tooltip: 'Edit program',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _editProgram,
          ),
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
                        fontSize: 12,
                        color: _statusColor(pr.status),
                      ),
                    ),
                  ),
                  title: Text(pr.name),
                  subtitle: Text(
                    [
                      if (planned != null)
                        '${completed.toStringAsFixed(completed % 1 == 0 ? 0 : 1)}'
                            '/${planned.toStringAsFixed(planned % 1 == 0 ? 0 : 1)} '
                            '${pr.unit ?? ''}',
                      pr.status ?? 'planned',
                      if (pr.dueOn != null) 'due ${pr.dueOn}',
                    ].join(' · '),
                  ),
                  // Row → its activities (each one editable); + → log one;
                  // press and hold → edit the practice itself.
                  trailing: IconButton(
                    tooltip: 'Log activity',
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => _logActivity(pr),
                  ),
                  onTap: () => _activities(pr),
                  onLongPress: () => _editPractice(pr),
                );
              },
            ),
    );
  }
}
