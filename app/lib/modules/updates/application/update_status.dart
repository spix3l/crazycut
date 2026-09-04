// Lifecycle of one update check plus download.
enum UpdateStatus {
  idle,
  checking,
  available,
  downloading,
  ready,
  upToDate,
  error,
}
