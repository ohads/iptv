import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtream_player/main.dart';

/// Exercises the failure diagnosis against a real socket. These paths only run
/// when a stream will not play, so without a test they are easy to get wrong
/// and never notice.
void main() {
  late HttpServer server;
  late String base;

  /// Serves one canned response for every request.
  Future<void> serve({
    required int status,
    String? contentType,
    String body = 'payload',
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';

    server.listen((request) async {
      request.response.statusCode = status;
      if (contentType != null) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      request.response.write(body);
      await request.response.close();
    });
  }

  tearDown(() => server.close(force: true));

  test('reports the status code when the panel refuses the stream', () async {
    await serve(status: 403);

    final message = await XtreamService.probeStream('$base/live/u/p/1.m3u8');

    expect(message, contains('403'));
    expect(message.toLowerCase(), contains('connections'));
  });

  test('explains a 404 as off air or a wrong URL format', () async {
    await serve(status: 404);

    final message = await XtreamService.probeStream('$base/live/u/p/1.m3u8');

    expect(message, contains('404'));
    expect(message.toLowerCase(), contains('off air'));
  });

  test('names MPEG-TS as the problem when the panel serves a transport stream',
      () async {
    await serve(status: 200, contentType: 'video/mp2t');

    final message = await XtreamService.probeStream('$base/live/u/p/1.ts');

    expect(message, contains('MPEG-TS'));
    expect(message, contains('media_kit'));
  });

  test('treats an opaque octet-stream as a transport stream too', () async {
    await serve(status: 200, contentType: 'application/octet-stream');

    final message = await XtreamService.probeStream('$base/live/u/p/1.ts');

    expect(message, contains('MPEG-TS'));
  });

  test('blames the decoder, not the container, when HLS is served', () async {
    await serve(status: 200, contentType: 'application/vnd.apple.mpegurl');

    final message = await XtreamService.probeStream('$base/live/u/p/1.m3u8');

    expect(message, contains('could not decode'));
    expect(message, isNot(contains('MPEG-TS')));
  });

  test('rejects a malformed address without touching the network', () async {
    await serve(status: 200);

    final message = await XtreamService.probeStream('not a url');

    expect(message, contains('not a valid URL'));
  });

  test('reports unreachable servers rather than throwing', () async {
    await serve(status: 200);
    final port = server.port;
    await server.close(force: true);
    // Re-bind so tearDown has something to close.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    final message = await XtreamService.probeStream(
      'http://127.0.0.1:$port/live/u/p/1.m3u8',
    );

    expect(message, contains('Could not reach'));
  });
}
