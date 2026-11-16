void disableEngineBrowserHistory() {}

String currentBrowserPageFragment() => Uri.base.fragment;

String? currentBrowserHistoryUid() => null;

void pushBrowserPageFragment(String fragment, {String? uid}) {}

void replaceBrowserPageFragment(String fragment, {String? uid}) {}

void Function() listenForBrowserPageChanges(void Function() listener) => () {};

bool isBrowserTabHidden() => false;
