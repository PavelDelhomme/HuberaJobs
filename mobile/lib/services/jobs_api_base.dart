/// URL d’API Jobs vue par le téléphone. Le release ne reste pas sur la boucle locale.
bool jobsApiIsLoopback(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '10.0.2.2' ||
      host.endsWith('.localhost');
}

const jobsProdApiBase = 'https://jobs.hubera.cloud';

String resolveJobsApiBase({
  required bool release,
  required String fromEnv,
  String? saved,
  required String loopbackFallback,
}) {
  final env = fromEnv.trim();
  if (env.isNotEmpty && !(release && jobsApiIsLoopback(env))) return env;
  final kept = saved?.trim() ?? '';
  if (release) {
    if (kept.isNotEmpty && !jobsApiIsLoopback(kept)) return kept;
    return jobsProdApiBase;
  }
  if (kept.isNotEmpty) return kept;
  return loopbackFallback;
}
