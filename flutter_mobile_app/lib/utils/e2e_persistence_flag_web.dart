import 'dart:js_interop';

@JS('localStorage')
external _Storage? get _localStorage;

extension type _Storage._(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
}

bool e2ePersistenceRequested() {
  try {
    return _localStorage?.getItem('e2e_persistence'.toJS)?.toDart == '1';
  } catch (_) {
    return false;
  }
}
