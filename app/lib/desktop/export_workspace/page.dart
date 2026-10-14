part of '../export_workspace.dart';

/// The letter page, composed live: what you see is what every format says.
/// Fixed print palette on paper white — the page looks the same from
/// either skin, exactly like the PDF it mirrors (MapReport's layout).
class _Page extends StatelessWidget {
  const _Page({required this.document});
  final MapDocument document;

  static const _paper = Color(0xFFF7F6F2);
  static const _ink = Color(0xFF1B1813);
  static const _soft = Color(0xFF6B655C);
  static const _rule = Color(0xFFB8AE9C);
  static const _oxblood = Color(0xFF8B2E22);

  @override
  Widget build(BuildContext context) {
    final d = document;
    final legend = d.marksLegend;
    final half = (legend.length / 2).ceil();

    Widget kicker(String s) => Row(
      children: [
        Container(width: 15, height: 2, color: _oxblood),
        SizedBox(width: 6),
        Text(
          s.toUpperCase(),
          style: TextStyle(
            fontFamily: Type.mono,
            fontSize: 8.5,
            letterSpacing: 1.6,
            color: _soft,
          ),
        ),
      ],
    );

    Widget legendRow((int, String) e) => Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(width: 10, height: 10, color: Color(e.$1)),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              e.$2,
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 10.5,
                color: _ink,
              ),
            ),
          ),
        ],
      ),
    );

    Widget tableRow(List<Widget> cells) => Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _rule, width: 0.5)),
      ),
      padding: EdgeInsets.symmetric(vertical: 3.5),
      child: Row(children: cells),
    );

    Text cell(String s, {bool right = false, Color color = _ink}) => Text(
      s,
      textAlign: right ? TextAlign.right : TextAlign.left,
      style: TextStyle(fontFamily: Type.serif, fontSize: 10.5, color: color),
    );

    return Container(
      width: 700,
      color: _paper,
      padding: EdgeInsets.all(55),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          kicker('Field Notes · map'),
          SizedBox(height: 5),
          Text(
            d.title.toUpperCase(),
            style: TextStyle(
              fontFamily: Type.slab,
              fontWeight: FontWeight.w900,
              fontSize: 23,
              height: 1,
              color: _ink,
            ),
          ),
          SizedBox(height: 3),
          Text(
            d.subtitle,
            style: TextStyle(fontFamily: Type.mono, fontSize: 10, color: _soft),
          ),
          SizedBox(height: 13),
          Container(
            decoration: BoxDecoration(border: Border.all(color: _ink)),
            child: Image.memory(
              d.plate.png,
              width: 588,
              fit: BoxFit.fitWidth,
              gaplessPlayback: true,
            ),
          ),
          SizedBox(height: 15),
          if (legend.isNotEmpty) ...[
            kicker('Legend'),
            SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [for (final e in legend.take(half)) legendRow(e)],
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [for (final e in legend.skip(half)) legendRow(e)],
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
          ],
          if (d.zoneRowsInk.isNotEmpty) ...[
            kicker('Zones'),
            SizedBox(height: 5),
            for (final (ink, name, acres) in d.zoneRowsInk)
              tableRow([
                Container(width: 10, height: 10, color: Color(ink)),
                SizedBox(width: 8),
                Expanded(child: cell(name)),
                SizedBox(
                  width: 80,
                  child: cell(acres, right: true, color: _soft),
                ),
              ]),
            SizedBox(height: 12),
          ],
          if (d.featureRows.isNotEmpty) ...[
            kicker('Features'),
            SizedBox(height: 5),
            for (final (name, cls) in d.featureRows)
              tableRow([
                Expanded(child: cell(name)),
                SizedBox(
                  width: 110,
                  child: cell(cls, right: true, color: _soft),
                ),
              ]),
            SizedBox(height: 12),
          ],
          if (d.removalPlan) ...[
            kicker('Flagged for removal · ${d.numbered.length}'),
            SizedBox(height: 5),
            if (d.numbered.isEmpty)
              cell(
                'Nothing is flagged for removal on this place.',
                color: _soft,
              ),
            for (var i = 0; i < d.numbered.length; i++)
              tableRow([
                SizedBox(width: 26, child: cell('${i + 1}', color: _oxblood)),
                Expanded(
                  child: cell(
                    d.numbered[i].label ??
                        '${d.numbered[i].type[0].toUpperCase()}${d.numbered[i].type.substring(1)} record',
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: cell(
                    '${d.numbered[i].lat.toStringAsFixed(5)}, ${d.numbered[i].lng.toStringAsFixed(5)}',
                    right: true,
                    color: _soft,
                  ),
                ),
              ]),
            SizedBox(height: 12),
          ] else if (d.recordRows.isNotEmpty) ...[
            kicker('Field records on this map'),
            SizedBox(height: 5),
            for (final (label, count) in d.recordRows)
              tableRow([
                Expanded(child: cell(label)),
                SizedBox(
                  width: 60,
                  child: cell(count, right: true, color: _soft),
                ),
              ]),
            SizedBox(height: 12),
          ],
          if ((d.notes ?? '').trim().isNotEmpty) ...[
            kicker('Notes'),
            SizedBox(height: 6),
            Text(
              d.notes!.trim(),
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 11.5,
                height: 1.5,
                color: _ink,
              ),
            ),
            SizedBox(height: 12),
          ],
          SizedBox(height: 8),
          Text(
            d.sourceLine,
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 8,
              height: 1.4,
              color: _soft,
            ),
          ),
        ],
      ),
    );
  }
}
