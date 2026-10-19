import 'package:flutter_test/flutter_test.dart';
import 'package:jobbingtrack_mobile/services/hubera_id_sso.dart';

void main() {
  test('Jobs prend le jeton Hubera ID du compte déjà choisi', () {
    expect(
      jobsCanUseIdAccess(
        expectedEmail: 'A@example.com',
        idEmail: 'a@example.com',
        idAccess: 'access',
      ),
      isTrue,
    );
  });

  test('Jobs ignore le jeton d’un autre compte', () {
    expect(
      jobsCanUseIdAccess(
        expectedEmail: 'a@example.com',
        idEmail: 'b@example.com',
        idAccess: 'access',
      ),
      isFalse,
    );
  });
}
