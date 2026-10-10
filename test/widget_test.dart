import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xtream_player/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Pumps the app in a viewport tall enough to hold every demo channel.
  /// The channel grid is a lazy sliver, so anything below the fold is simply
  /// not built and `find.text` would miss it.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const XtreamPlayerApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
  }

  testWidgets('Xtream app loads with live TV tab', (WidgetTester tester) async {
    await tester.pumpWidget(const XtreamPlayerApp());

    // Give the app time to check credentials and load demo data.
    // The delay is from _loadDemoData() which waits 600ms. Time has to be
    // advanced through the tester — a bare Future.delayed never fires inside
    // the fake-async zone testWidgets runs in.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();

    // Look for app title
    expect(find.text('Xtream Player'), findsOneWidget);

    // Look for demo channel that should be loaded (demo data fallback)
    expect(find.text('BBC World'), findsWidgets);
  });

  testWidgets('demo content is labelled as such', (WidgetTester tester) async {
    await tester.pumpWidget(const XtreamPlayerApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();

    expect(find.text('Demo content — no server configured.'), findsOneWidget);
  });

  testWidgets('refresh re-runs the load without throwing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const XtreamPlayerApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();

    // Regression: assigning the new future from an arrow-bodied setState made
    // the callback return a Future, which setState rejects at runtime.
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('BBC World'), findsWidgets);
  });

  group('XtreamCredentials', () {
    test('normalize trims, drops trailing slashes and defaults the scheme', () {
      expect(
        XtreamCredentials.normalize('  line.example.com:8080/// '),
        'http://line.example.com:8080',
      );
      expect(
        XtreamCredentials.normalize('https://line.example.com/'),
        'https://line.example.com',
      );
      expect(XtreamCredentials.normalize('   '), '');
    });

    test('loads saved credentials after a restart', () async {
      SharedPreferences.setMockInitialValues({
        'xtream_server_url': 'https://line.example.com:8080/',
        'xtream_username': 'user',
        'xtream_password': 'pass&plus',
      });

      final credentials = await XtreamCredentials.load();

      expect(credentials, isNotNull);
      expect(credentials!.baseUrl, 'https://line.example.com:8080');
      expect(credentials.username, 'user');
      expect(credentials.password, 'pass&plus');
    });

    test('builds live, movie and episode URLs from the account details', () {
      const credentials = XtreamCredentials(
        baseUrl: 'http://line.example.com:8080',
        username: 'user',
        password: 'pass',
      );

      expect(
        credentials.liveUrl('1234'),
        'http://line.example.com:8080/live/user/pass/1234.m3u8',
      );
      expect(
        credentials.movieUrl('99', 'mkv'),
        'http://line.example.com:8080/movie/user/pass/99.mkv',
      );
      expect(
        credentials.episodeUrl('42', 'mp4'),
        'http://line.example.com:8080/series/user/pass/42.mp4',
      );
    });

    test('escapes credentials that contain URL-significant characters', () {
      const credentials = XtreamCredentials(
        baseUrl: 'http://line.example.com',
        username: 'a b',
        password: 'p&w',
      );

      expect(credentials.liveUrl('7'), contains('/live/a%20b/p%26w/7.m3u8'));
      expect(
        credentials.api('get_live_streams').queryParameters['password'],
        'p&w',
      );
    });
  });

  group('category grouping', () {
    XtreamCategory named(String name) => XtreamCategory(id: name, name: name);

    test('splits the region prefix off common panel naming styles', () {
      expect(named('EU | Sports HD').group, 'EU');
      expect(named('EU | Sports HD').shortName, 'Sports HD');

      expect(named('AR- News').group, 'AR');
      expect(named('AR- News').shortName, 'News');

      expect(named('US: Kids').group, 'US');
      expect(named('4K | Movies').group, '4K');
      expect(named('|EU| Documentaries').group, 'EU');
    });

    test('leaves names without a region code alone', () {
      expect(named('Documentaries').group, XtreamCategory.ungrouped);
      expect(named('Documentaries').shortName, 'Documentaries');

      // The separator alone must not be enough — this is a category whose
      // own name contains a dash, not a region-prefixed one.
      expect(named('Sports - HD').group, XtreamCategory.ungrouped);
      expect(named('Sports - HD').shortName, 'Sports - HD');

      // Lower-case leading words are ordinary words, not codes.
      expect(named('news - today').group, XtreamCategory.ungrouped);
    });

    test('orders regions alphabetically with the catch-all last', () {
      final codes = groupCodesOf([
        named('US | Movies'),
        named('Documentaries'),
        named('AR | Kids'),
        named('EU | News'),
        named('EU | Sports'),
      ]);

      expect(codes, ['All', 'AR', 'EU', 'US', XtreamCategory.ungrouped]);
    });

    test('omits the catch-all when every category is prefixed', () {
      final codes = groupCodesOf([named('EU | News'), named('AM | News')]);
      expect(codes, ['All', 'AM', 'EU']);
    });
  });

  group('channels near', () {
    LiveChannel channel(String id, String name, String categoryId) =>
        LiveChannel(
          id: id,
          name: name,
          categoryId: categoryId,
          category: categoryId,
          streamUrl: '',
          logo: '',
        );

    AppData appData(List<XtreamCategory> categories, List<LiveChannel> channels) =>
        AppData(
          credentials: null,
          categories: categories,
          channels: channels,
          movies: const [],
          series: const [],
          warnings: const [],
        );

    List<String> ids((String?, List<LiveChannel>) near) =>
        [for (final c in near.$2) c.id];

    test('matches the Live tab category chip for the channel', () {
      final data = appData(
        [
          XtreamCategory(id: 'il', name: 'AS| ISRAEL'),
          XtreamCategory(id: 'in', name: 'AS| INDIA'),
          XtreamCategory(id: 'news', name: 'Documentaries'),
        ],
        [
          channel('1', 'IL| Kan 11', 'il'),
          channel('2', 'IL| Sport 5', 'il'),
          channel('3', 'IN| Star Plus', 'in'),
          channel('4', 'Nat Geo', 'news'),
        ],
      );

      final israel = channelsNear(data, '1');
      expect(israel.$1, 'AS › ISRAEL');
      expect(ids(israel), ['1', '2']);

      final unprefixed = channelsNear(data, '4');
      expect(unprefixed.$1, 'Documentaries');
      expect(ids(unprefixed), ['4']);
    });
  });

  testWidgets('selecting a region narrows the category chips and the grid',
      (WidgetTester tester) async {
    await pumpApp(tester);

    // Demo data spans EU, AM, AR plus one unprefixed category.
    expect(find.widgetWithText(ChoiceChip, 'All regions'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'EU'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'AR'), findsOneWidget);

    // Unfiltered: channels from every region are on screen.
    expect(find.text('BBC World'), findsOneWidget); // EU
    expect(find.text('CNN News'), findsOneWidget); // AM

    await tester.tap(find.widgetWithText(ChoiceChip, 'EU'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('BBC World'), findsOneWidget);
    expect(find.text('CNN News'), findsNothing);

    // The category row now offers only the two EU categories, by short name.
    expect(find.widgetWithText(ChoiceChip, 'Sports'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Kids'), findsNothing);
  });

  testWidgets('switching region resets a stale category selection',
      (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'EU'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Sports'));
    await tester.pump();
    expect(find.text('ESPN Live'), findsOneWidget);
    expect(find.text('BBC World'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'AR'));
    await tester.pump();

    // AR has no Sports category, so the filter must fall back to All rather
    // than leaving an empty grid behind.
    expect(tester.takeException(), isNull);
    expect(find.text('Cartoon Club'), findsOneWidget);
  });

  testWidgets('the playback error card renders and masks the password',
      (WidgetTester tester) async {
    // Scheme-less addresses are rejected before any socket or timer is
    // involved, so the error card is reached synchronously.
    const playable = Playable(
      id: '1',
      title: 'Test Channel',
      subtitle: 'News',
      streamUrl: '/live/user/sw0rdf1sh/1.m3u8',
      fallbackUrls: ['/live/user/sw0rdf1sh/1.ts'],
      isLive: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(
          playable: playable,
          credentials: XtreamCredentials(
            baseUrl: 'http://127.0.0.1:1',
            username: 'user',
            password: 'sw0rdf1sh',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Regression: the address list used to be an ExpansionTile, whose
    // ListTile tripped a framework assertion inside the player's decorated
    // container and replaced the whole card with an error box.
    expect(tester.takeException(), isNull);

    expect(find.textContaining('Addresses tried'), findsOneWidget);
    expect(find.textContaining('/live/user/'), findsWidgets);

    // The password must never be rendered, even while diagnosing.
    expect(find.textContaining('sw0rdf1sh'), findsNothing);
    expect(find.textContaining('•••'), findsWidgets);
  });

  testWidgets('copying the error puts a redacted report on the clipboard',
      (WidgetTester tester) async {
    ClipboardData? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = ClipboardData(text: '${call.arguments['text']}');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const playable = Playable(
      id: '1',
      title: 'Sky Sports Main Event',
      subtitle: 'Sports',
      streamUrl: '/live/user/sw0rdf1sh/1.m3u8',
      fallbackUrls: ['/live/user/sw0rdf1sh/1.ts'],
      isLive: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(
          playable: playable,
          credentials: XtreamCredentials(
            baseUrl: 'http://127.0.0.1:1',
            username: 'user',
            password: 'sw0rdf1sh',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy details'));
    await tester.pump();

    final text = copied?.text;
    expect(text, isNotNull);
    expect(text, contains('Sky Sports Main Event'));
    expect(text, contains('not a valid URL'));
    expect(text, contains('/live/user/'));

    // The whole point of redacting on screen is undone if copy leaks it.
    expect(text, isNot(contains('sw0rdf1sh')));
    expect(text, contains('•••'));

    expect(find.text('Error details copied'), findsOneWidget);
  });

  testWidgets('pinning a category adds it to the quick access bar',
      (WidgetTester tester) async {
    await pumpApp(tester);

    // Nothing pinned yet, so the bar is absent entirely.
    expect(find.text('Pinned'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'EU'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Sports'));
    await tester.pump();

    await tester.tap(find.byTooltip('Pin EU | Sports'));
    await tester.pump();

    expect(find.text('Pinned'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'EU | Sports'), findsOneWidget);
  });

  testWidgets('a pinned category jumps across regions in one tap',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'flutter.pinned_categories': <String>['eu-sports'],
    });
    await pumpApp(tester);

    // Start somewhere else entirely.
    await tester.tap(find.widgetWithText(ChoiceChip, 'AR'));
    await tester.pump();
    expect(find.text('Cartoon Club'), findsOneWidget);
    expect(find.text('ESPN Live'), findsNothing);

    await tester.tap(find.widgetWithText(InputChip, 'EU | Sports'));
    await tester.pump();

    // The region filter has to move with the pin, or the category row would
    // be showing AR while the grid shows EU.
    expect(tester.takeException(), isNull);
    expect(find.text('ESPN Live'), findsOneWidget);
    expect(find.text('Cartoon Club'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'News'), findsOneWidget);
  });

  testWidgets('pins survive a reload and can be removed',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'flutter.pinned_categories': <String>['ar-kids'],
    });
    await pumpApp(tester);

    expect(find.widgetWithText(InputChip, 'AR | Kids'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.widgetWithText(InputChip, 'AR | Kids'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove AR | Kids from pinned'));
    await tester.pump();

    expect(find.widgetWithText(InputChip, 'AR | Kids'), findsNothing);
    expect(find.text('Pinned'), findsNothing);
  });

  testWidgets('continue watching items can be removed',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'flutter.recently_watched': <String>['bbc', 'cnn'],
    });
    await pumpApp(tester);

    expect(find.text('Continue Watching'), findsOneWidget);
    final removeButtons = find.byTooltip('Remove from Continue Watching');
    expect(removeButtons, findsNWidgets(2));

    await tester.tap(removeButtons.first);
    await tester.pump();
    expect(removeButtons, findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('recently_watched'), ['cnn']);

    await tester.tap(removeButtons.first);
    await tester.pump();
    expect(find.text('Continue Watching'), findsNothing);
  });

  group('EpgProgram', () {
    test('is airing between its start and end', () {
      final start = DateTime(2026, 8, 15, 20);
      final program = EpgProgram(
        start: start,
        end: start.add(const Duration(hours: 1)),
        title: 'News',
        description: '',
      );

      expect(program.isAiringAt(start.add(const Duration(minutes: 30))), isTrue);
      expect(
        program.isAiringAt(start.subtract(const Duration(minutes: 1))),
        isFalse,
      );
      expect(program.isAiringAt(start.add(const Duration(hours: 2))), isFalse);
    });

    test('falls back to a two hour slot when the panel omits an end time', () {
      final start = DateTime(2026, 8, 15, 20);
      final program = EpgProgram(
        start: start,
        end: null,
        title: 'News',
        description: '',
      );

      expect(program.isAiringAt(start.add(const Duration(minutes: 90))), isTrue);
      expect(program.isAiringAt(start.add(const Duration(hours: 3))), isFalse);
    });
  });
}
