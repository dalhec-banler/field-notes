import 'package:flutter/material.dart';

import '../services/app_prefs.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// First-run walkthrough (re-openable from Settings → Getting started).
///
/// Six pages, no marketing. What the app is for, how to make a record, how
/// the map behaves, how the record gets off the phone, and where the two
/// optional keys go. Skippable at any point — a person holding a phone in a
/// pasture does not want a tour.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.prefs, this.onDone});

  final AppPrefs prefs;
  final VoidCallback? onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() {
    widget.prefs.hasSeenOnboarding = true;
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.of(context).pop();
    }
  }

  List<_Page> get _pages => const [
        _Page(
          kicker: 'Local-first field journal',
          title: 'FIELD\nNOTES',
          body:
              'A record of your land that lives on this phone. It works with '
              'the radio off, in a pasture, in the rain. Nothing leaves the '
              'device unless you send it.',
          points: [
            'Every record is a place, a time, a photograph and your words.',
            'The valuable record is the same plant, eight times, over four '
                'years — not eight thousand one-off notes.',
          ],
        ),
        _Page(
          kicker: 'The one thing to know',
          title: 'THE RED\nBUTTON',
          body:
              'The camera button is on every screen. Tap it, shoot, save — '
              'about fifteen seconds. Everything after the photograph is '
              'optional.',
          points: [
            'A record with no species, no notes and no signal is still a '
                'good record.',
            'Saving never waits for GPS, network, or an identification.',
            'No fix? The record is marked "no GPS" — never given a made-up '
                'location.',
          ],
        ),
        _Page(
          kicker: 'Map',
          title: 'WHERE YOU\nARE',
          body:
              'On your land, the map follows you. Away from it, the map stays '
              'on the land and tells you how far off you are.',
          points: [
            'Long-press anywhere to drop a record at that spot instead of at '
                'your feet.',
            'Layers filters what you see — record types, or plants by kind: '
                'trees, shrubs, grasses, forbs.',
            '⌗ Capture area downloads the map for offline use while you have '
                'signal. Do it before you need it.',
          ],
        ),
        _Page(
          kicker: 'Getting it off the phone',
          title: 'BACKUP',
          body:
              'A phone in the creek is a total loss until a backup runs. It '
              'runs itself once a day, and you choose how far the copy '
              'travels — each option trades privacy against convenience '
              'differently.',
          points: [
            'On this phone, encrypted: a passphrase you '
                'choose plus a 12-word recovery kit. Strongest, and nobody '
                'but you can open it, including us. Share the file wherever '
                'you like from there.',
            'Google Drive: signing in with Google is used for one thing, '
                'permission to write to a hidden folder in your own Drive. '
                'Convenient — the copy survives a lost phone without you '
                'remembering anything. Google holds the file and no key.',
            'Your own computer, over your own network: run Field Notes on a '
                'machine at home, switch on Pair with your phone, and the phone '
                'pushes to it across the LAN. Nothing touches the internet '
                'and no account exists.',
          ],
        ),
        _Page(
          kicker: 'Optional',
          title: 'NAMING\nPLANTS',
          body:
              'The app will never name a plant for you. It can offer '
              'suggestions with its reasons, and you decide.',
          points: [
            'Two optional keys, both yours: Pl@ntNet for photo '
                'identification, and an AI provider of your choosing for a '
                'second opinion.',
            'The second opinion is the useful one — it weighs the photo '
                'against your county, your soil, the season, and what you '
                'have already recorded here.',
            'A suggestion is never written to a record until you tap it. '
                'Settings → Species ID has the setup steps.',
          ],
        ),
        _Page(
          kicker: 'That\'s the tour',
          title: 'GO AND\nWALK IT',
          body:
              'Start by adding the land you walk, then import a boundary if '
              'you have one — Settings → Import boundary & zones takes KML, '
              'KMZ, GeoJSON or GPX.',
          points: [
            'This walkthrough is always in Settings → Getting started.',
            'Take my data — full export gives you everything in open '
                'formats, any time, no account.',
          ],
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final last = _page == pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _PageView(page: pages[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Metrics.gutter, 6, Metrics.gutter, 12),
              child: Row(
                children: [
                  // Progress as diamonds, like the tab bar.
                  for (var i = 0; i < pages.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Diamond(
                        size: 9,
                        color: i == _page ? Press.oxblood : Press.inkSoft,
                        filled: i == _page,
                      ),
                    ),
                  const Spacer(),
                  if (!last)
                    SizedBox(
                      height: 56,
                      child: TextButton(
                        onPressed: _finish,
                        child: const Text('SKIP'),
                      ),
                    ),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 56,
                    child: FilledButton(
                      onPressed: last
                          ? _finish
                          : () => _controller.nextPage(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOut,
                              ),
                      child: Text(last ? 'START' : 'NEXT'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page {
  const _Page({
    required this.kicker,
    required this.title,
    required this.body,
    required this.points,
  });
  final String kicker;
  final String title;
  final String body;
  final List<String> points;
}

class _PageView extends StatelessWidget {
  const _PageView({required this.page});
  final _Page page;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(26, 32, 26, 8),
      children: [
        Kicker(page.kicker),
        const SizedBox(height: 10),
        Text(
          page.title,
          style: TextStyle(
            fontFamily: Type.slab,
            fontWeight: FontWeight.w900,
            fontSize: 46,
            height: 0.92,
            color: Press.ink,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          page.body,
          style: TextStyle(
              fontFamily: Type.serif, fontSize: 17, height: 1.5),
        ),
        const SizedBox(height: 22),
        for (final p in page.points)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 7),
                  child: Diamond(size: 8, color: Press.sage, filled: true),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    p,
                    style: TextStyle(
                        fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
