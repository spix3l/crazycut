part of 'sandbox_access.dart';

/// One folder the user has to hand back, and why.
class FolderRequest {
  const FolderRequest({required this.folder, required this.needsWrite});

  final String folder;
  final bool needsWrite;

  String get name {
    final parts = folder.split(Platform.pathSeparator).where((p) => p.isNotEmpty);
    return parts.isEmpty ? folder : parts.last;
  }

  String get reason =>
      needsWrite ? 'to save the project here' : 'to load media from here';
}
