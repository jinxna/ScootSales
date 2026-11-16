// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

void disableEngineBrowserHistory() {
  ui_web.urlStrategy = null;
}

String currentBrowserPageFragment() => Uri.base.fragment;

String? currentBrowserHistoryUid() {
  final Object? state = html.window.history.state;
  if (state is Map && state['uid'] is String) return state['uid'] as String;
  return null;
}

Map<String, String>? _stateFor(String? uid) =>
    uid == null ? null : <String, String>{'uid': uid};

void pushBrowserPageFragment(String fragment, {String? uid}) {
  html.window.history.pushState(_stateFor(uid), '', _urlFor(fragment));
}

void replaceBrowserPageFragment(String fragment, {String? uid}) {
  html.window.history.replaceState(_stateFor(uid), '', _urlFor(fragment));
}

String _urlFor(String fragment) => fragment.isEmpty
    ? '${html.window.location.pathname}${html.window.location.search}'
    : fragment;

void Function() listenForBrowserPageChanges(void Function() listener) {
  final subscription = html.window.onPopState.listen((_) => listener());
  return subscription.cancel;
}

bool isBrowserTabHidden() => html.document.hidden ?? false;
