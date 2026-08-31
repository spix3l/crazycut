import 'package:crazycut_app/core/platform/sandbox_access.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/modules/ai/application/transcription_service.dart';
import 'package:crazycut_app/modules/editor/infrastructure/caption_rasterizer.dart';
import 'package:crazycut_app/modules/editor/infrastructure/svg_rasterizer.dart';
import 'package:crazycut_app/modules/editor/infrastructure/text_rasterizer.dart';
import 'package:crazycut_app/modules/editor/infrastructure/tracking_service.dart';
import 'package:crazycut_app/modules/editor/infrastructure/template_library.dart';
import 'package:crazycut_app/modules/media/application/media_url_service.dart';
import 'package:crazycut_app/modules/media/application/media_relink.dart';
import 'package:crazycut_app/modules/media/infrastructure/media_cache.dart';
import 'package:crazycut_app/modules/media/infrastructure/remote_source_cache.dart';
import 'package:crazycut_app/modules/settings/application/ui_preferences.dart';

/// Explicit collaborators used by one editor session.
///
/// The production factory is the only editor-layer location that knows about
/// process-wide implementations. Controllers receive this object rather than
/// reaching into unrelated modules through global accessors.
class EditorDependencies {
  const EditorDependencies({
    required this.engine,
    required this.sandbox,
    required this.mediaCache,
    required this.remoteSourceCache,
    required this.svgRasterizer,
    required this.textRasterizer,
    required this.captionRasterizer,
    required this.tracking,
    required this.transcription,
    required this.preferences,
    required this.mediaUrls,
    required this.mediaRelinker,
    required this.templateLibrary,
  });

  factory EditorDependencies.production() => EditorDependencies(
    engine: CrazyCutEngine.instance,
    sandbox: SandboxAccess.instance,
    mediaCache: MediaCache.instance,
    remoteSourceCache: RemoteSourceCache.instance,
    svgRasterizer: SvgRasterizer.instance,
    textRasterizer: TextRasterizer.instance,
    captionRasterizer: CaptionRasterizer.instance,
    tracking: TrackingService.instance,
    transcription: TranscriptionService.instance,
    preferences: UiPreferences.instance,
    mediaUrls: MediaUrlService(),
    mediaRelinker: MediaRelinker.instance,
    templateLibrary: TemplateLibrary.instance,
  );

  final CrazyCutEngine engine;
  final SandboxAccess sandbox;
  final MediaCache mediaCache;
  final RemoteSourceCache remoteSourceCache;
  final SvgRasterizer svgRasterizer;
  final TextRasterizer textRasterizer;
  final CaptionRasterizer captionRasterizer;
  final TrackingService tracking;
  final TranscriptionService transcription;
  final UiPreferences preferences;
  final MediaUrlService mediaUrls;
  final MediaRelinker mediaRelinker;
  final TemplateLibrary templateLibrary;
}
