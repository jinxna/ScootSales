import 'dart:async';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

String? sessionRead(String key) {
  try {
    return html.window.sessionStorage[key];
  } catch (_) {
    return null;
  }
}

void sessionWrite(String key, String value) {
  try {
    html.window.sessionStorage[key] = value;
  } catch (_) {}
}

void sessionRemove(String key) {
  try {
    html.window.sessionStorage.remove(key);
  } catch (_) {}
}

String? localRead(String key) {
  try {
    return html.window.localStorage[key];
  } catch (_) {
    return null;
  }
}

void localWrite(String key, String value) {
  try {
    html.window.localStorage[key] = value;
  } catch (_) {}
}

void localRemove(String key) {
  try {
    html.window.localStorage.remove(key);
  } catch (_) {}
}

String urlFragment() => html.window.location.hash;

void clearUrlFragment() {
  html.window.history.replaceState(null, '', html.window.location.pathname);
}

const String _savedSignInDatabase = 'firebaseLocalStorageDb';
const String _savedSignInStore = 'firebaseLocalStorage';

Future<JSAny?> _finished(JSObject request, String success) {
  final Completer<JSAny?> done = Completer<JSAny?>();
  request[success] = ((JSAny? _) {
    if (!done.isCompleted) done.complete(request['result']);
  }).toJS;
  request['onerror'] = ((JSAny? _) {
    if (!done.isCompleted) done.completeError(StateError('IndexedDB failed.'));
  }).toJS;
  return done.future;
}

Future<JSObject?> _openSavedSignIns() async {
  try {
    final JSObject factory = globalContext['indexedDB']! as JSObject;
    final JSObject opening = factory.callMethod<JSObject>(
      'open'.toJS,
      _savedSignInDatabase.toJS,
      1.toJS,
    );
    opening['onupgradeneeded'] = ((JSAny? _) {
      final JSObject database = opening['result']! as JSObject;
      final JSObject names = database['objectStoreNames']! as JSObject;
      if (!names
          .callMethod<JSBoolean>('contains'.toJS, _savedSignInStore.toJS)
          .toDart) {
        database.callMethod<JSAny?>(
          'createObjectStore'.toJS,
          _savedSignInStore.toJS,
          <String, Object?>{'keyPath': 'fbase_key'}.jsify(),
        );
      }
    }).toJS;
    return await _finished(opening, 'onsuccess') as JSObject?;
  } catch (_) {
    return null;
  }
}

Future<Object?> _inStore(Future<Object?> Function(JSObject store) work) async {
  final JSObject? database = await _openSavedSignIns();
  if (database == null) return null;
  try {
    final JSObject transaction = database.callMethod<JSObject>(
      'transaction'.toJS,
      _savedSignInStore.toJS,
      'readwrite'.toJS,
    );
    final Future<JSAny?> committed = _finished(transaction, 'oncomplete');
    final Object? result = await work(
      transaction.callMethod<JSObject>(
        'objectStore'.toJS,
        _savedSignInStore.toJS,
      ),
    );
    await committed;
    return result;
  } catch (_) {
    return null;
  } finally {
    database.callMethod<JSAny?>('close'.toJS);
  }
}

Future<Object?> takeSavedSignIn(String key) => _inStore((JSObject store) async {
  final Future<JSAny?> record = _finished(
    store.callMethod<JSObject>('get'.toJS, key.toJS),
    'onsuccess',
  );
  final Future<JSAny?> removal = _finished(
    store.callMethod<JSObject>('delete'.toJS, key.toJS),
    'onsuccess',
  );
  final Object? saved = (await record).dartify();
  await removal;
  return saved;
});

Future<void> putSavedSignIn(Object record) => _inStore(
  (JSObject store) => _finished(
    store.callMethod<JSObject>('put'.toJS, record.jsify()),
    'onsuccess',
  ),
);

Future<bool> refreshTokenAccepted(Uri endpoint, String refreshToken) async {
  try {
    final html.HttpRequest response = await html.HttpRequest.request(
      endpoint.toString(),
      method: 'POST',
      requestHeaders: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      sendData:
          'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(refreshToken)}',
    );
    return response.status == 200;
  } catch (_) {
    return false;
  }
}
