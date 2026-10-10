import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool get isBrowserFullscreen => web.document.fullscreenElement != null;

/// Must be called straight from a user gesture (a tap or click handler):
/// browsers reject fullscreen requests that arrive after an `await`.
Future<void> setBrowserFullscreen(bool enable) async {
  try {
    if (enable && !isBrowserFullscreen) {
      await web.document.documentElement?.requestFullscreen().toDart;
    } else if (!enable && isBrowserFullscreen) {
      await web.document.exitFullscreen().toDart;
    }
  } catch (_) {
    // Refused (e.g. not triggered by a gesture). The app still fills the tab.
  }
}

/// Reports when the user leaves fullscreen on their own, e.g. with Esc.
/// Returns a function that stops listening.
void Function() listenBrowserFullscreen(void Function(bool) onChange) {
  final listener = ((web.Event _) => onChange(isBrowserFullscreen)).toJS;
  web.document.addEventListener('fullscreenchange', listener);
  return () => web.document.removeEventListener('fullscreenchange', listener);
}
