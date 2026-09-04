// Machine readable reason for a failed update check. Background checks map
// every code to silence; manual checks map them to one friendly message.
enum UpdateFetchFailure {
  network,
  notFound,
  tooLarge,
  badSignature,
  invalidManifest,
}
