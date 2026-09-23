import 'package:flutter/material.dart';

import '../db/database.dart';
import '../geo/state_resolver.dart';
import '../services/property_locator.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import 'region_library.dart';
import 'state_places.dart';

/// The plants of wherever this place is.
///
/// Shown at the top of the library until the place's state has a list:
/// says which state the app thinks this is (or asks), and offers the
/// state's most-recorded plants from iNaturalist. The request sends the
/// state and nothing else, and it happens only on the tap (D-034).
class StateListCard extends StatefulWidget {
  const StateListCard({
    super.key,
    required this.db,
    required this.property,
    required this.onChanged,
  });

  final FieldNotesDb db;
  final Property property;
  final VoidCallback onChanged;

  @override
  State<StateListCard> createState() => _StateListCardState();
}

class _StateListCardState extends State<StateListCard> {
  bool _busy = false;
  bool _hasList = true; // assume until checked, so the card never flashes
  UsState? _state;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(StateListCard old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id ||
        old.property.state != widget.property.state) {
      _check();
    }
  }

  Future<void> _check() async {
    final usps = widget.property.state;
    final resolver = await StateResolver.load();
    final state = usps == null ? null : resolver.byUsps(usps);
    final has = usps == null
        ? false
        : await RegionLibrary(widget.db).hasListFor(usps);
    if (mounted) {
      setState(() {
        _state = state;
        _hasList = has;
      });
    }
  }

  Future<void> _pickState() async {
    final resolver = await StateResolver.load();
    if (!mounted) return;
    final picked = await showDialog<UsState>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('WHICH STATE IS THIS PLACE IN?'),
        children: [
          for (final s in resolver.all)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Text(s.name),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await PropertyLocator(widget.db).setState(widget.property.id, picked.usps);
    await RegionLibrary(widget.db).seedBundledPalette(picked.usps);
    widget.onChanged();
    setState(() => _state = picked);
    await _check();
  }

  Future<void> _fetch() async {
    final state = _state;
    if (state == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('PLANTS OF ${state.name.toUpperCase()}'),
        content: Text(
          'Asks iNaturalist for the ${state.name} plants people record '
          'most: about 300 native and 60 introduced species, with native '
          'or introduced flags. The request carries the word '
          '"${state.name}" and nothing about you or this place. The top '
          'forty natives are starred for the quick pick.',
          style: TextStyle(fontFamily: Type.serif, fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('NOT NOW'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('GET THE LIST'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final lib = RegionLibrary(widget.db);
      final species = await lib.fetchStateSpecies(state.usps);
      final n = await lib.importStateSpecies(state.usps, species);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$n plants added for ${state.name}')),
      );
      widget.onChanged();
      await _check();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not get the list: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasList) return const SizedBox.shrink();
    final state = _state;
    final canFetch = state != null && inatStatePlaceIds.containsKey(state.usps);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Metrics.gutter, 4, Metrics.gutter, 10),
      child: InkCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Kicker(
              state == null
                  ? 'Where is this place?'
                  : 'Plants of ${state.name}',
            ),
            const SizedBox(height: 6),
            Text(
              state == null
                  ? 'The library fills in for your state once the app knows '
                        'it — from your first record here, a boundary, or a '
                        'pick from the list.'
                  : 'No plant list for ${state.name} is on the phone yet. '
                        'Add plants one at a time, or fetch the ones people '
                        'record most in the state.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 14.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (state == null)
                  OutlinedButton(
                    onPressed: _pickState,
                    child: const Text('PICK A STATE'),
                  )
                else if (canFetch)
                  FilledButton(
                    onPressed: _busy ? null : _fetch,
                    child: Text(_busy ? 'FETCHING…' : 'GET THE LIST'),
                  ),
                const SizedBox(width: 8),
                if (state != null)
                  TextButton(
                    onPressed: _pickState,
                    child: const Text('WRONG STATE?'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
