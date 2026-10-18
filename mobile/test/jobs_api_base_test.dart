import 'package:flutter_test/flutter_test.dart';
import 'package:jobbingtrack_mobile/services/jobs_api_base.dart';

void main() {
  test('le release ignore 127.0.0.1 et pointe la prod', () {
    expect(jobsApiIsLoopback('http://127.0.0.1:5002'), isTrue);
    expect(
      resolveJobsApiBase(
        release: true,
        fromEnv: '',
        saved: 'http://127.0.0.1:5002',
        loopbackFallback: 'http://127.0.0.1:5002',
      ),
      'https://jobs.hubera.cloud',
    );
  });

  test('un dart-define reste prioritaire', () {
    expect(
      resolveJobsApiBase(
        release: true,
        fromEnv: 'https://api.jobbingtrack.com',
        saved: 'http://127.0.0.1:5002',
        loopbackFallback: 'http://127.0.0.1:5002',
      ),
      'https://api.jobbingtrack.com',
    );
  });

  test('un dart-define loopback est ignoré en release', () {
    expect(
      resolveJobsApiBase(
        release: true,
        fromEnv: 'http://127.0.0.1:5002',
        saved: 'http://127.0.0.1:5002',
        loopbackFallback: 'http://127.0.0.1:5002',
      ),
      'https://jobs.hubera.cloud',
    );
  });
}
