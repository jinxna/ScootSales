final Map<String, String> _session = <String, String>{};
final Map<String, String> _local = <String, String>{};

String? sessionRead(String key) => _session[key];

void sessionWrite(String key, String value) => _session[key] = value;

void sessionRemove(String key) => _session.remove(key);

String? localRead(String key) => _local[key];

void localWrite(String key, String value) => _local[key] = value;

void localRemove(String key) => _local.remove(key);

String urlFragment() => '';

void clearUrlFragment() {}

Future<Object?> takeSavedSignIn(String key) async => null;

Future<void> putSavedSignIn(Object record) async {}

Future<bool> refreshTokenAccepted(Uri endpoint, String refreshToken) async =>
    false;
