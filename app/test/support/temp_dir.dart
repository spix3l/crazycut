import 'dart:io';

/// Deletes a test temp directory, tolerating the Windows file-lock race: the
/// engine worker can still hold imported media open for a moment after
/// [EditorController.close] returns, and unlike POSIX Windows refuses to
/// delete files another process has open. Retries briefly, then gives up and
/// leaves whatever remains for the OS temp cleaner — a locked file is not
/// worth failing a passing test.
void deleteTempDir(Directory dir) {
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      sleep(const Duration(milliseconds: 200));
    }
  }
}
