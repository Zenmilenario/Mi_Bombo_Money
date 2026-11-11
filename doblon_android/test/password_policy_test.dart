// Fictitious passwords only. The same rule as Supabase Auth and the iPhone (Tests/PasswordSecurityCheck.swift).
import 'package:doblon/password_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new passwords follow the cloud rule', () {
    expect(passwordProblem('Ficticia-2026'), isNull);
    expect(passwordProblem('Fic~tic1aX'), isNull, reason: 'Exactly 10 characters, any of the listed symbols');
    expect(passwordProblem('Fict-26a'), 'A la contraseña le falta al menos 10 caracteres.');
    expect(passwordProblem('ficticia-2026'), 'A la contraseña le falta una mayúscula.');
    expect(passwordProblem('FICTICIA-2026'), 'A la contraseña le falta una minúscula.');
    expect(passwordProblem('Ficticia-dos'), 'A la contraseña le falta un número.');
    expect(passwordProblem('Ficticia2026'), contains('un símbolo'));
    expect(passwordProblem('Ficticia 2026'), contains('un símbolo'), reason: 'A space is not one of the symbols');
    expect(passwordProblem(''),
        r'A la contraseña le falta al menos 10 caracteres, una minúscula, una mayúscula, un número y un símbolo (por ejemplo ! ? # $ %).');
  });
}
