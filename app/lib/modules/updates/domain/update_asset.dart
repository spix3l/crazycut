// Per-platform asset entry inside the signed update manifest.
class UpdateAsset {
  const UpdateAsset({
    required this.file,
    required this.url,
    required this.sha256,
    required this.size,
  });

  final String file;
  final String url;
  final String sha256;
  final int size;
}
