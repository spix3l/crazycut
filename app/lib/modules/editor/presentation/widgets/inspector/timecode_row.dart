part of 'inspector_rows.dart';

/// Frame-exact timecode entry (TIM-8). Accepts `hh:mm:ss:ff`, `mm:ss`, a plain
/// frame count or seconds with a decimal point.
class TimecodeRow extends StatefulWidget {
  const TimecodeRow({
    super.key,
    required this.label,
    required this.value,
    required this.fps,
    required this.onSubmitted,
    this.enabled = true,
    this.helper,
  });

  final String label;
  final Rt value;
  final double fps;
  final ValueChanged<Rt> onSubmitted;
  final bool enabled;
  final String? helper;

  @override
  State<TimecodeRow> createState() => _TimecodeRowState();
}

class _TimecodeRowState extends State<TimecodeRow> {
  late final TextEditingController _controller = TextEditingController(
    text: Rt.toTimecode(widget.value, widget.fps),
  );
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _sync();
    });
  }

  @override
  void didUpdateWidget(TimecodeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && oldWidget.value != widget.value) _sync();
  }

  void _sync() => _controller.text = Rt.toTimecode(widget.value, widget.fps);

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final parsed = parseTimecode(raw, widget.fps);
    if (parsed == null) {
      _sync();
      return;
    }
    widget.onSubmitted(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          SizedBox(width: 78, child: Text(widget.label, style: CcType.small)),
          Expanded(
            child: CcTextField(
              height: 28,
              radius: CcRadius.sm,
              controller: widget.enabled ? _controller : null,
              focusNode: _focus,
              value:
                  widget.enabled
                      ? null
                      : Rt.toTimecode(widget.value, widget.fps),
              onSubmitted: _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// Parses `hh:mm:ss:ff`, `mm:ss`, `123` (frames) or `1.5` (seconds).
Rt? parseTimecode(String raw, double fps) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final rate = fps <= 0 ? 30.0 : fps;
  if (text.contains(':')) {
    final parts = text.split(':').map((p) => int.tryParse(p.trim())).toList();
    if (parts.any((p) => p == null)) return null;
    final values = parts.cast<int>();
    int hours = 0, minutes = 0, seconds = 0, frames = 0;
    switch (values.length) {
      case 4:
        hours = values[0];
        minutes = values[1];
        seconds = values[2];
        frames = values[3];
      case 3:
        minutes = values[0];
        seconds = values[1];
        frames = values[2];
      case 2:
        minutes = values[0];
        seconds = values[1];
      default:
        return null;
    }
    final total = hours * 3600 + minutes * 60 + seconds + frames / rate;
    return Rt.fromSeconds(total);
  }
  if (text.contains('.')) {
    final seconds = double.tryParse(text);
    return seconds == null ? null : Rt.fromSeconds(seconds);
  }
  final frames = int.tryParse(text);
  return frames == null ? null : Rt.fromSeconds(frames / rate);
}
