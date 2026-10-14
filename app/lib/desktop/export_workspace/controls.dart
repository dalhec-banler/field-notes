part of '../export_workspace.dart';

/// The bench's controls: species rows, choice chips, layer rows.
mixin _ExportControls on _ExportRender {
  Widget _speciesRowUi((String, String, int, int) g) {
    final on = _speciesSel.contains(g.$1);
    return InkWell(
      onTap: () {
        setState(() {
          if (on) {
            _speciesSel.remove(g.$1);
          } else {
            _speciesSel.add(g.$1);
          }
        });
        _scheduleRender();
      },
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            SizedBox(width: 6),
            Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: on ? Color(g.$4) : null,
                shape: BoxShape.circle,
                border: Border.all(
                  color: on ? Color(g.$4) : Press.borderInk,
                  width: 1.5,
                ),
              ),
              child: on
                  ? Icon(Icons.check, size: 11, color: Press.paper)
                  : null,
            ),
            SizedBox(width: 9),
            Expanded(
              child: Text(
                g.$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: Type.serif, fontSize: 14),
              ),
            ),
            MonoLabel('${g.$3}', size: 9, opacity: 0.6),
          ],
        ),
      ),
    );
  }

  Widget _choiceChip(String label, bool on, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: on ? Press.ink : null,
        border: Border.all(color: Press.borderInk, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: Type.serif,
          fontSize: 13,
          color: on ? Press.paper : Press.ink,
        ),
      ),
    ),
  );

  Widget _layerRow(
    String label,
    bool on,
    void Function(bool) set, {
    int? count,
  }) {
    return InkWell(
      onTap: () {
        setState(() => set(!on));
        _scheduleRender();
      },
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: on ? Press.ink : null,
                border: Border.all(color: Press.borderInk, width: 1.5),
              ),
              child: on
                  ? Icon(Icons.check, size: 14, color: Press.paper)
                  : null,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontFamily: Type.serif, fontSize: 15),
              ),
            ),
            if (count != null) MonoLabel('$count', size: 9, opacity: 0.6),
          ],
        ),
      ),
    );
  }
}
