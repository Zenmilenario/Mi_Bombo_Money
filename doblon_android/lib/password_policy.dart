// The cloud's password rule (Supabase Auth, set on 11 November 2026): at least 10 characters with lower case,
// upper case, digits and symbols. The same rule as the iPhone (`CloudPasswordPolicy`), checked before sending so
// the person sees what is missing instead of a refusal from the server.

const passwordMinimumLength = 10;

/// The symbols Supabase counts as such.
const passwordSymbols = r'''!@#$%^&*()_+-=[]{};'\:"|<>?,./`~''';

const passwordRuleText = r'Al menos 10 caracteres, con mayúsculas, minúsculas, números y algún símbolo (por ejemplo ! ? # $ %).';

/// What a new password lacks to be accepted by the cloud, or null when it is valid.
String? passwordProblem(String password) {
  final missing = <String>[
    if (password.length < passwordMinimumLength) 'al menos 10 caracteres',
    if (!password.contains(RegExp('[a-z]'))) 'una minúscula',
    if (!password.contains(RegExp('[A-Z]'))) 'una mayúscula',
    if (!password.contains(RegExp('[0-9]'))) 'un número',
    if (!password.split('').any(passwordSymbols.contains)) r'un símbolo (por ejemplo ! ? # $ %)',
  ];
  if (missing.isEmpty) return null;
  final list = missing.length == 1 ? missing.first : '${missing.sublist(0, missing.length - 1).join(', ')} y ${missing.last}';
  return 'A la contraseña le falta $list.';
}
