part of 'commands.dart';

/// Records what an operation touched, then turns it into a [DocumentEdit].
///
/// Callers mutate the document directly but declare each entity they are about
/// to change; the transaction snapshots the "before" side on first touch and
/// the "after" side at commit. One transaction stays open for the length of a
/// drag, which is where gesture coalescing (TIM-20) comes from.
class EditTransaction {
  EditTransaction(this.doc, this.label);

  final ProjectDoc doc;
  String label;

  final Map<String, Map<String, dynamic>?> _clips = {};
  final Map<String, Map<String, dynamic>?> _tracks = {};
  final Map<String, Map<String, dynamic>?> _markers = {};
  final Map<String, Map<String, dynamic>?> _transitions = {};
  final Map<String, Map<String, dynamic>?> _captionTracks = {};
  final Map<String, Map<String, dynamic>?> _trackers = {};
  String? _nameBefore;
  Map<String, dynamic>? _settingsBefore;

  void clip(String id) =>
      _clips.putIfAbsent(id, () => _deepCopyJson(doc.clipById(id)?.toJson()));

  /// `Clip.toJson` hands out the live [Clip.effects] list; a shallow copy
  /// would alias it and make every effect edit look like a no-op. Copies the
  /// nested maps/lists so snapshots are frozen at touch time. Map keys keep
  /// their runtime type (fromJson casts to `Map<String, dynamic>`).
  static Map<String, dynamic>? _deepCopyJson(Map<String, dynamic>? json) {
    if (json == null) return null;

    dynamic copyValue(dynamic value) {
      if (value is Map<String, dynamic>) {
        return {for (final e in value.entries) e.key: copyValue(e.value)};
      }
      if (value is Map) {
        return {for (final e in value.entries) e.key: copyValue(e.value)};
      }
      if (value is List) return [for (final e in value) copyValue(e)];
      return value;
    }

    return copyValue(json) as Map<String, dynamic>;
  }

  void clips(Iterable<String> ids) => ids.forEach(clip);

  void track(String id) =>
      _tracks.putIfAbsent(id, () => doc.trackById(id)?.toJson());

  void tracks(Iterable<String> ids) => ids.forEach(track);

  void marker(String id) => _markers.putIfAbsent(id, () => _markerJson(id));

  Map<String, dynamic>? _markerJson(String id) {
    for (final m in doc.markers) {
      if (m.id == id) return m.toJson();
    }
    return null;
  }

  void transition(String id) =>
      _transitions.putIfAbsent(id, () => doc.transitionById(id)?.toJson());

  /// Snapshots a whole caption track. Text, timing and style mutations can
  /// therefore be committed as one command without retaining live objects.
  void captionTrack(String id) => _captionTracks.putIfAbsent(
    id,
    () => _deepCopyJson(doc.captionTrackById(id)?.toJson()),
  );

  /// Snapshots a whole tracker, path included (**TRK-15**).
  void tracker(String id) => _trackers.putIfAbsent(
    id,
    () => _deepCopyJson(doc.trackerById(id)?.toJson()),
  );

  /// The "before" JSON snapshotted for [id], or null when untouched/absent.
  /// Sanitize passes read these to see the pre-op geometry of a clip without
  /// holding live references.
  Map<String, dynamic>? clipSnapshot(String id) => _clips[id];

  Map<String, dynamic>? transitionSnapshot(String id) => _transitions[id];

  bool touchedClip(String id) => _clips.containsKey(id);

  void name() => _nameBefore ??= doc.name;

  void settings() => _settingsBefore ??= doc.settings.toJson();

  /// Every clip on the given tracks, for ripple-style operations.
  void wholeTracks(Iterable<String> trackIds) {
    for (final id in trackIds) {
      clips(doc.clipsOn(id).map((c) => c.id));
    }
  }

  DocumentEdit? build() {
    final edit = DocumentEdit(
      label: label,
      clips: {
        for (final entry in _clips.entries)
          entry.key: EntityDelta(
            entry.value,
            doc.clipById(entry.key)?.toJson(),
          ),
      },
      tracks: {
        for (final entry in _tracks.entries)
          entry.key: EntityDelta(
            entry.value,
            doc.trackById(entry.key)?.toJson(),
          ),
      },
      markers: {
        for (final entry in _markers.entries)
          entry.key: EntityDelta(entry.value, _markerJson(entry.key)),
      },
      transitions: {
        for (final entry in _transitions.entries)
          entry.key: EntityDelta(
            entry.value,
            doc.transitionById(entry.key)?.toJson(),
          ),
      },
      captionTracks: {
        for (final entry in _captionTracks.entries)
          entry.key: EntityDelta(
            entry.value,
            _deepCopyJson(doc.captionTrackById(entry.key)?.toJson()),
          ),
      },
      trackers: {
        for (final entry in _trackers.entries)
          entry.key: EntityDelta(
            entry.value,
            _deepCopyJson(doc.trackerById(entry.key)?.toJson()),
          ),
      },
      nameBefore: _nameBefore,
      nameAfter: _nameBefore == null ? null : doc.name,
      settingsBefore: _settingsBefore,
      settingsAfter: _settingsBefore == null ? null : doc.settings.toJson(),
    );
    return edit.isNoop ? null : edit;
  }
}
