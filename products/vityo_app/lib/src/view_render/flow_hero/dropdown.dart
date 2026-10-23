/// A dropdown in the panel's own dark-panel vocabulary: the same well face,
/// border and silkscreen type as its text fields. The option list lives in an
/// overlay, so the settings card's clip and scroll cannot cut it off.
///
/// One widget for any number of choices — the caller owns the values and the
/// selected one, the dropdown owns opening, choosing and dismissing.
library;

import 'package:flutter/material.dart';

import 'palette.dart';

/// One selectable row in a [FlowHeroDropdown].
class FlowHeroDropdownOption<T> {
  const FlowHeroDropdownOption({
    required this.value,
    required this.label,
    this.id,
  });

  final T value;
  final String label;

  /// Stable fragment for the row's widget key, so a test or a driven tap can
  /// address it as `<dropdown key>-option-<id>`. Defaults to the value's string
  /// form; pass an ASCII id when the value has none.
  final String? id;
}

/// A value picker styled like the panel's fields. [value] picks the current
/// option; [onChanged] fires only for a different choice.
class FlowHeroDropdown<T> extends StatefulWidget {
  const FlowHeroDropdown({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.hint = '',
  });

  final List<FlowHeroDropdownOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// Shown when no option matches [value].
  final String hint;

  @override
  State<FlowHeroDropdown<T>> createState() => _FlowHeroDropdownState<T>();
}

class _FlowHeroDropdownState<T> extends State<FlowHeroDropdown<T>> {
  static const double _rowHeight = 30;
  static const double _menuPadding = 8;
  static const double _gap = 4;

  OverlayEntry? _entry;

  @override
  void dispose() {
    // The state is gone but still mounted here, so drop the entry directly
    // rather than through the setState-driven close.
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  String get _keyPrefix {
    final Key? key = widget.key;
    return key is ValueKey<String> ? key.value : '$key';
  }

  String get _label {
    for (final FlowHeroDropdownOption<T> option in widget.options) {
      if (option.value == widget.value) return option.label;
    }
    return widget.hint;
  }

  Key _optionKey(FlowHeroDropdownOption<T> option) =>
      ValueKey<String>('$_keyPrefix-option-${option.id ?? option.value}');

  void _toggle() {
    if (_entry != null) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final OverlayState overlay = Overlay.of(context);
    final RenderBox overlayBox =
        overlay.context.findRenderObject()! as RenderBox;
    final Offset origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final Size size = box.size;

    final double menuHeight = widget.options.length * _rowHeight + _menuPadding;
    final bool below =
        origin.dy + size.height + _gap + menuHeight <= overlayBox.size.height;
    final double top = below
        ? origin.dy + size.height + _gap
        : origin.dy - menuHeight - _gap;

    _entry = OverlayEntry(
      builder: (BuildContext context) => Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.shrink(),
            ),
          ),
          Positioned(
            left: origin.dx,
            top: top,
            width: size.width,
            child: _menu(),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  void _select(FlowHeroDropdownOption<T> option) {
    _close();
    if (option.value != widget.value) widget.onChanged(option.value);
  }

  @override
  Widget build(BuildContext context) {
    final bool open = _entry != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: Container(
        height: 28,
        padding: const EdgeInsets.only(left: 8, right: 6),
        decoration: BoxDecoration(
          color: P.well,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: open ? P.ring : P.seamLo),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _label,
                style: P.silkStyle(),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.expand_more, size: 14, color: P.silkDim),
          ],
        ),
      ),
    );
  }

  Widget _menu() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: P.panelHi,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: P.ring),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Colors.black54,
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final FlowHeroDropdownOption<T> option in widget.options)
            GestureDetector(
              key: _optionKey(option),
              behavior: HitTestBehavior.opaque,
              onTap: () => _select(option),
              child: Container(
                height: _rowHeight,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                color: option.value == widget.value ? P.well : null,
                alignment: Alignment.centerLeft,
                child: Text(
                  option.label,
                  style: P.silkStyle().copyWith(
                    color: option.value == widget.value
                        ? P.orangeBright
                        : P.silk,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
