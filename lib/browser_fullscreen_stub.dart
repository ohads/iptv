// Off the web there is no browser window to take fullscreen; SystemChrome
// handles mobile, so these are no-ops.

bool get isBrowserFullscreen => false;

Future<void> setBrowserFullscreen(bool enable) async {}

void Function() listenBrowserFullscreen(void Function(bool) onChange) => () {};
