import Foundation

/// Security-scoped bookmarks (IMP-15 offline detection, PRJ-9 external
/// project files) so a file picked once through `NSOpenPanel` stays
/// reachable after the app relaunches under the App Sandbox — otherwise
/// `files.user-selected.read-write` access lapses the moment the process
/// exits, and an untouched file reads back as missing. Exposed to Dart via
/// the `bookmarkCreate`/`bookmarkResolve` calls on AppDelegate's system
/// channel.
enum SecurityScopedBookmarks {
  // Resolving a bookmark opens its security scope for the rest of this
  // process; kept alive here so it isn't released the moment the local
  // `URL` goes out of scope. The scope closes for free when the app quits.
  private static var accessing: [URL] = []

  static func create(path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    guard let data = try? url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
    else { return nil }
    return data.base64EncodedString()
  }

  static func resolve(base64: String) -> [String: Any]? {
    guard let data = Data(base64Encoded: base64) else { return nil }
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
    else { return nil }
    guard url.startAccessingSecurityScopedResource() else { return nil }
    accessing.append(url)

    var payload: [String: Any] = ["path": url.path]
    // A stale bookmark still resolved and still grants access; it just
    // won't survive the next relaunch unless it's replaced now.
    if stale, let refreshed = create(path: url.path) {
      payload["bookmark"] = refreshed
    }
    return payload
  }
}
