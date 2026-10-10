import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'browser_fullscreen_stub.dart'
    if (dart.library.js_interop) 'browser_fullscreen_web.dart';

const _serverUrlKey = 'xtream_server_url';
const _usernameKey = 'xtream_username';
const _passwordKey = 'xtream_password';
const _recentlyWatchedKey = 'recently_watched';
const _favoritesKey = 'favorite_channels';
const _pinnedCategoriesKey = 'pinned_categories';
const _volumeKey = 'player_volume';
const _mutedKey = 'player_muted';

// Fallbacks used until credentials are saved in the app. Supplied at build
// time from the git-ignored credentials.json via --dart-define-from-file.
const _defaultServerUrl = String.fromEnvironment('XTREAM_SERVER_URL');
const _defaultUsername = String.fromEnvironment('XTREAM_USERNAME');
const _defaultPassword = String.fromEnvironment('XTREAM_PASSWORD');

void main() {
  runApp(const XtreamPlayerApp());
}

String _shortError(Object error) => error.toString().split('\n').first;

/// `Uri.tryParse` accepts almost anything — "not a url" parses cleanly as a
/// relative reference rather than returning null — so a null check alone is
/// not enough to know an address is fetchable.
bool _isFetchableUri(Uri? uri) =>
    uri != null && uri.hasScheme && uri.host.isNotEmpty;

class XtreamPlayerApp extends StatelessWidget {
  const XtreamPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Xtream Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111827),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFef4444),
          brightness: Brightness.dark,
        ),
        cardColor: const Color(0xFF111827),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<AppData> _future = XtreamService().loadData();
  String _searchQuery = '';
  List<String> _recentlyWatched = [];
  Set<String> _favorites = {};
  Set<String> _pinnedCategories = {};

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await _prefsOrNull();
    if (prefs == null || !mounted) return;
    setState(() {
      _recentlyWatched = prefs.getStringList(_recentlyWatchedKey) ?? [];
      _favorites = (prefs.getStringList(_favoritesKey) ?? []).toSet();
      _pinnedCategories =
          (prefs.getStringList(_pinnedCategoriesKey) ?? []).toSet();
    });
  }

  Future<void> _togglePinnedCategory(String categoryId) async {
    final updated = {..._pinnedCategories};
    // remove returns false when the id was not there, so this toggles.
    if (!updated.remove(categoryId)) updated.add(categoryId);

    final prefs = await _prefsOrNull();
    await prefs?.setStringList(_pinnedCategoriesKey, updated.toList());
    if (!mounted) return;
    setState(() => _pinnedCategories = updated);
  }

  void _reload() {
    // Block body on purpose: an arrow body would return the new Future, and
    // setState rejects a callback whose result is a Future.
    setState(() {
      _future = XtreamService().loadData();
    });
  }

  Future<void> _addToRecentlyWatched(String channelId) async {
    final updated = [..._recentlyWatched]..removeWhere((id) => id == channelId);
    updated.insert(0, channelId);
    final trimmed = updated.length > 10 ? updated.sublist(0, 10) : updated;

    final prefs = await _prefsOrNull();
    await prefs?.setStringList(_recentlyWatchedKey, trimmed);
    if (!mounted) return;
    setState(() => _recentlyWatched = trimmed);
  }

  Future<void> _removeFromRecentlyWatched(String channelId) async {
    final updated = [..._recentlyWatched]..remove(channelId);

    final prefs = await _prefsOrNull();
    await prefs?.setStringList(_recentlyWatchedKey, updated);
    if (!mounted) return;
    setState(() => _recentlyWatched = updated);
  }

  Future<void> _openPlayer(BuildContext context, AppData data, Playable playable) async {
    final navigator = Navigator.of(context);
    if (playable.isLive) {
      await _addToRecentlyWatched(playable.id);
    }
    final (title, channels) = playable.isLive
        ? channelsNear(data, playable.id)
        : (null, const <LiveChannel>[]);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (context) => PlayerScreen(
          playable: playable,
          credentials: data.credentials,
          channels: channels,
          channelsTitle: title,
          onChannelChanged: (channel) => _addToRecentlyWatched(channel.id),
        ),
      ),
    );
    // The player owns the favourite toggle, so pick up whatever it changed.
    await _loadPrefs();
  }

  Future<void> _openSeries(BuildContext context, AppData data, SeriesItem series) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SeriesDetailScreen(
          series: series,
          credentials: data.credentials,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Xtream Player'),
          elevation: 2,
          actions: [
            IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
            ),
            IconButton(
              onPressed: () => _showSettings(context),
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
            ),
          ],
        ),
        body: FutureBuilder<AppData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _ErrorView(
                error: snapshot.error!,
                onRetry: _reload,
                onOpenSettings: () => _showSettings(context),
              );
            }

            final data = snapshot.data!;
            final favoriteChannels =
                data.channels.where((ch) => _favorites.contains(ch.id)).toList();

            return Column(
              children: [
                if (data.isDemo)
                  _NoticeBar(
                    icon: Icons.science_outlined,
                    message: 'Demo content — no server configured.',
                    actionLabel: 'Connect',
                    onAction: () => _showSettings(context),
                  ),
                for (final warning in data.warnings)
                  _NoticeBar(
                    icon: Icons.warning_amber_rounded,
                    message: warning,
                    tone: _NoticeTone.warning,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: InputDecoration(
                      hintText: 'Search channels, movies and series...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(() => _searchQuery = ''),
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF1a1f36),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: 'Live TV'),
                    Tab(text: 'Movies'),
                    Tab(text: 'Series'),
                    Tab(text: 'Favorites'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _LiveTab(
                        data: data,
                        searchQuery: _searchQuery,
                        recentlyWatched: _recentlyWatched,
                        pinnedCategories: _pinnedCategories,
                        onTogglePin: _togglePinnedCategory,
                        onRemoveRecent: _removeFromRecentlyWatched,
                        onOpen: (channel) =>
                            _openPlayer(context, data, channel.toPlayable()),
                      ),
                      _MoviesTab(
                        items: data.movies,
                        searchQuery: _searchQuery,
                        onOpen: (movie) =>
                            _openPlayer(context, data, movie.toPlayable()),
                      ),
                      _SeriesTab(
                        items: data.series,
                        searchQuery: _searchQuery,
                        onOpen: (series) => _openSeries(context, data, series),
                      ),
                      _FavoritesTab(
                        channels: favoriteChannels,
                        onOpen: (channel) =>
                            _openPlayer(context, data, channel.toPlayable()),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => const XtreamSettingsSheet(),
    );

    if (saved == true) {
      _reload();
    }
  }
}

enum _NoticeTone { info, warning }

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({
    required this.icon,
    required this.message,
    this.tone = _NoticeTone.info,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final _NoticeTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final color = tone == _NoticeTone.warning ? Colors.amber : Colors.lightBlueAccent;

    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(actionLabel!, style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.error,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final xtreamError = error is XtreamException ? error as XtreamException : null;
    final message = xtreamError?.message ?? _shortError(error);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: Colors.red.shade300),
              const SizedBox(height: 16),
              const Text(
                'Could not load your playlist',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (xtreamError?.canRetry ?? true)
                    OutlinedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  FilledButton.icon(
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Settings'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade600),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.trailing, this.action});

  final String title;
  final String? trailing;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, action == null ? 16 : 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ?action,
        ],
      ),
    );
  }
}

class _LiveTab extends StatefulWidget {
  const _LiveTab({
    required this.data,
    required this.searchQuery,
    required this.recentlyWatched,
    required this.pinnedCategories,
    required this.onTogglePin,
    required this.onRemoveRecent,
    required this.onOpen,
  });

  final AppData data;
  final String searchQuery;
  final List<String> recentlyWatched;

  /// Ids of categories the user pinned for one-tap access.
  final Set<String> pinnedCategories;
  final void Function(String categoryId) onTogglePin;
  final void Function(String channelId) onRemoveRecent;
  final void Function(LiveChannel channel) onOpen;

  @override
  State<_LiveTab> createState() => _LiveTabState();
}

const String _allFilter = 'All';

/// The channels the Live tab would show with [channelId]'s category chip
/// selected, labelled the way that chip reads, e.g. "AS › ISRAEL".
(String?, List<LiveChannel>) channelsNear(AppData data, String channelId) {
  final current = data.channels.where((c) => c.id == channelId).firstOrNull;
  if (current == null) return (null, const []);

  final category = data.categories
      .where((c) => c.id == current.categoryId)
      .firstOrNull;
  final title = category == null
      ? current.category
      : category.group == XtreamCategory.ungrouped
      ? category.shortName
      : '${category.group} › ${category.shortName}';

  return (
    title,
    [
      for (final c in data.channels)
        if (c.categoryId == current.categoryId) c,
    ],
  );
}

/// The distinct region codes across [categories], ordered for display: an
/// "All" entry first, then codes alphabetically, with the catch-all bucket
/// last so an unprefixed tail does not sit in the middle of the row.
List<String> groupCodesOf(Iterable<XtreamCategory> categories) {
  final codes = <String>{for (final category in categories) category.group};
  final hasUngrouped = codes.remove(XtreamCategory.ungrouped);
  final sorted = codes.toList()..sort();

  return [
    _allFilter,
    ...sorted,
    if (hasUngrouped) XtreamCategory.ungrouped,
  ];
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.labels,
    required this.values,
    required this.selected,
    required this.onSelected,
  }) : assert(labels.length == values.length);

  final List<String> labels;
  final List<String> values;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final controller = ScrollController();

    return SizedBox(
      height: 42,
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        trackVisibility: true,
        child: ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: values.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) => ChoiceChip(
            label: Text(labels[index]),
            selected: selected == values[index],
            onSelected: (_) => onSelected(values[index]),
          ),
        ),
      ),
    );
  }
}

class _LiveTabState extends State<_LiveTab> {
  String _selectedGroup = _allFilter;
  String _selectedCategoryId = _allFilter;

  /// Selects a pinned category, moving the region filter with it so the
  /// category row stays consistent with what is now showing.
  void _jumpTo(XtreamCategory category) {
    setState(() {
      _selectedGroup = category.group;
      _selectedCategoryId = category.id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupCodesOf(widget.data.categories);
    // A reload can retire whatever was selected.
    final group = groups.contains(_selectedGroup) ? _selectedGroup : _allFilter;

    final categoriesInGroup = group == _allFilter
        ? widget.data.categories
        : widget.data.categories.where((c) => c.group == group).toList();

    final categoryId =
        categoriesInGroup.any((c) => c.id == _selectedCategoryId)
        ? _selectedCategoryId
        : _allFilter;

    final idsInGroup = {for (final c in categoriesInGroup) c.id};

    final query = widget.searchQuery.trim().toLowerCase();
    final filtered = widget.data.channels.where((channel) {
      if (categoryId != _allFilter) {
        if (channel.categoryId != categoryId) return false;
      } else if (group != _allFilter && !idsInGroup.contains(channel.categoryId)) {
        return false;
      }
      if (query.isNotEmpty && !channel.name.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();

    final byId = {for (final channel in widget.data.channels) channel.id: channel};
    final recentChannels = [
      for (final id in widget.recentlyWatched)
        if (byId[id] != null) byId[id]!,
    ];

    // Rendered in category order rather than pin order so the bar does not
    // reshuffle itself as pins come and go.
    final pinned = [
      for (final category in widget.data.categories)
        if (widget.pinnedCategories.contains(category.id)) category,
    ];

    final selectedCategory = categoryId == _allFilter
        ? null
        : categoriesInGroup.firstWhere((c) => c.id == categoryId);

    return CustomScrollView(
      slivers: [
        if (pinned.isNotEmpty && query.isEmpty) ...[
          const SliverToBoxAdapter(child: _SectionHeader('Pinned')),
          SliverToBoxAdapter(
            child: Builder(
              builder: (context) {
                final controller = ScrollController();
                return SizedBox(
                  height: 42,
                  child: Scrollbar(
                    controller: controller,
                    thumbVisibility: true,
                    trackVisibility: true,
                    child: ListView.separated(
                      controller: controller,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: pinned.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final category = pinned[index];
                        return InputChip(
                          avatar: const Icon(
                            Icons.star,
                            size: 16,
                            color: Colors.amber,
                          ),
                          // Full name, not shortName: pins span regions, so
                          // "ISRAEL" alone would be ambiguous.
                          label: Text(category.name),
                          selected: categoryId == category.id,
                          onPressed: () => _jumpTo(category),
                          onDeleted: () => widget.onTogglePin(category.id),
                          deleteIcon: const Icon(Icons.close, size: 16),
                          deleteButtonTooltipMessage:
                              'Remove ${category.name} from pinned',
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        if (recentChannels.isNotEmpty && query.isEmpty) ...[
          const SliverToBoxAdapter(child: _SectionHeader('Continue Watching')),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: recentChannels.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => _RecentlyWatchedCard(
                  channel: recentChannels[index],
                  onTap: () => widget.onOpen(recentChannels[index]),
                  onRemove: () =>
                      widget.onRemoveRecent(recentChannels[index].id),
                ),
              ),
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: _SectionHeader(
            'All Channels',
            trailing: '${filtered.length} of ${widget.data.channels.length}',
            action: selectedCategory == null
                ? null
                : IconButton(
                    tooltip: widget.pinnedCategories.contains(
                          selectedCategory.id,
                        )
                        ? 'Unpin ${selectedCategory.name}'
                        : 'Pin ${selectedCategory.name}',
                    icon: Icon(
                      widget.pinnedCategories.contains(selectedCategory.id)
                          ? Icons.star
                          : Icons.star_border,
                      color:
                          widget.pinnedCategories.contains(selectedCategory.id)
                          ? Colors.amber
                          : null,
                    ),
                    onPressed: () => widget.onTogglePin(selectedCategory.id),
                  ),
          ),
        ),
        if (groups.length > 2)
          SliverToBoxAdapter(
            child: _ChipRow(
              labels: [
                for (final code in groups)
                  code == _allFilter ? 'All regions' : code,
              ],
              values: groups,
              selected: group,
              onSelected: (value) => setState(() {
                _selectedGroup = value;
                // The old category almost certainly is not in the new group.
                _selectedCategoryId = _allFilter;
              }),
            ),
          ),
        SliverToBoxAdapter(
          child: _ChipRow(
            labels: [
              _allFilter,
              for (final c in categoriesInGroup)
                group == _allFilter ? c.name : c.shortName,
            ],
            values: [_allFilter, for (final c in categoriesInGroup) c.id],
            selected: categoryId,
            onSelected: (value) => setState(() => _selectedCategoryId = value),
          ),
        ),
        if (filtered.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyState(
              icon: Icons.search_off,
              message: 'No channels found',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.76,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _ChannelCard(
                  channel: filtered[index],
                  onOpen: () => widget.onOpen(filtered[index]),
                ),
                childCount: filtered.length,
              ),
            ),
          ),
      ],
    );
  }
}

class _RecentlyWatchedCard extends StatelessWidget {
  const _RecentlyWatchedCard({
    required this.channel,
    required this.onTap,
    required this.onRemove,
  });

  final LiveChannel channel;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 100,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Artwork(url: channel.logo, fallbackIcon: Icons.live_tv),
              Positioned(
                top: 4,
                right: 4,
                child: _Badge(label: 'LIVE'),
              ),
              Positioned(
                top: 2,
                left: 2,
                child: IconButton(
                  tooltip: 'Remove from Continue Watching',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close, size: 14),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(24, 24),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              Positioned(
                left: 4,
                right: 4,
                bottom: 4,
                child: Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url, required this.fallbackIcon}) : fit = BoxFit.cover;

  final String url;
  final IconData fallbackIcon;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(
        color: Colors.grey.shade800,
        child: Icon(fallbackIcon, color: Colors.grey.shade600),
      );
    }

    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      placeholder: (context, _) => Container(
        color: Colors.grey.shade800,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      errorWidget: (context, _, _) => Container(
        color: Colors.grey.shade800,
        child: Icon(fallbackIcon, color: Colors.grey.shade600),
      ),
    );
  }
}

class _ChannelCard extends StatefulWidget {
  const _ChannelCard({required this.channel, required this.onOpen});

  final LiveChannel channel;
  final VoidCallback onOpen;

  @override
  State<_ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<_ChannelCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _animationController.forward(),
      onTapUp: (_) {
        _animationController.reverse();
        widget.onOpen();
      },
      onTapCancel: () => _animationController.reverse(),
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SizedBox(
                      width: double.infinity,
                      child: _Artwork(
                        url: widget.channel.logo,
                        fallbackIcon: Icons.live_tv,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.channel.category,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey.shade400,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Positioned(top: 8, right: 8, child: _Badge(label: 'LIVE')),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoviesTab extends StatelessWidget {
  const _MoviesTab({
    required this.items,
    required this.searchQuery,
    required this.onOpen,
  });

  final List<MediaItem> items;
  final String searchQuery;
  final void Function(MediaItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    final query = searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? items
        : items.where((i) => i.title.toLowerCase().contains(query)).toList();

    if (items.isEmpty) {
      return const _EmptyState(
        icon: Icons.movie_outlined,
        message: 'No movies available on this account',
      );
    }

    if (filtered.isEmpty) {
      return const _EmptyState(icon: Icons.search_off, message: 'No movies found');
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = filtered[index];
        return _PosterTile(
          title: item.title,
          subtitle: item.subtitle,
          poster: item.poster,
          fallbackIcon: Icons.movie_outlined,
          trailing: const Icon(Icons.play_circle_fill_rounded, color: Colors.red),
          onTap: () => onOpen(item),
        );
      },
    );
  }
}

class _SeriesTab extends StatelessWidget {
  const _SeriesTab({
    required this.items,
    required this.searchQuery,
    required this.onOpen,
  });

  final List<SeriesItem> items;
  final String searchQuery;
  final void Function(SeriesItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    final query = searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? items
        : items.where((i) => i.title.toLowerCase().contains(query)).toList();

    if (items.isEmpty) {
      return const _EmptyState(
        icon: Icons.tv_outlined,
        message: 'No series available on this account',
      );
    }

    if (filtered.isEmpty) {
      return const _EmptyState(icon: Icons.search_off, message: 'No series found');
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = filtered[index];
        return _PosterTile(
          title: item.title,
          subtitle: item.subtitle,
          poster: item.poster,
          fallbackIcon: Icons.tv_outlined,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onOpen(item),
        );
      },
    );
  }
}

class _PosterTile extends StatelessWidget {
  const _PosterTile({
    required this.title,
    required this.subtitle,
    required this.poster,
    required this.fallbackIcon,
    required this.trailing,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String poster;
  final IconData fallbackIcon;
  final Widget trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 70,
            height: 100,
            child: _Artwork(url: poster, fallbackIcon: fallbackIcon),
          ),
        ),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}

class _FavoritesTab extends StatelessWidget {
  const _FavoritesTab({required this.channels, required this.onOpen});

  final List<LiveChannel> channels;
  final void Function(LiveChannel channel) onOpen;

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      return const _EmptyState(
        icon: Icons.favorite_border,
        message: 'No favourites yet.\nTap the heart while watching a channel to pin it here.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        return ListTile(
          leading: ClipOval(
            child: SizedBox(
              width: 40,
              height: 40,
              child: _Artwork(url: channel.logo, fallbackIcon: Icons.live_tv),
            ),
          ),
          title: Text(channel.name),
          subtitle: Text(channel.category),
          trailing: const Icon(Icons.star, color: Colors.amber),
          onTap: () => onOpen(channel),
        );
      },
    );
  }
}

class XtreamSettingsSheet extends StatefulWidget {
  const XtreamSettingsSheet({super.key});

  @override
  State<XtreamSettingsSheet> createState() => _XtreamSettingsSheetState();
}

class _XtreamSettingsSheetState extends State<XtreamSettingsSheet> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _saving = false;
  bool _testing = false;
  String? _testStatus;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await _prefsOrNull();
    if (prefs == null || !mounted) return;
    setState(() {
      _serverController.text =
          prefs.getString(_serverUrlKey) ?? _defaultServerUrl;
      _usernameController.text =
          prefs.getString(_usernameKey) ?? _defaultUsername;
      _passwordController.text =
          prefs.getString(_passwordKey) ?? _defaultPassword;
    });
  }

  XtreamCredentials _currentCredentials() {
    return XtreamCredentials(
      baseUrl: XtreamCredentials.normalize(_serverController.text),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testStatus = 'Testing...';
    });

    final credentials = _currentCredentials();
    String status;
    if (credentials.baseUrl.isEmpty ||
        credentials.username.isEmpty ||
        credentials.password.isEmpty) {
      status = '✗ Fill in the server URL, username and password first.';
    } else {
      try {
        status = '✓ ${await XtreamService().probe(credentials)}';
      } on XtreamException catch (e) {
        status = '✗ ${e.message}';
      } catch (e) {
        status = '✗ ${_shortError(e)}';
      }
    }

    if (!mounted) return;
    setState(() {
      _testStatus = status;
      _testing = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    final credentials = _currentCredentials();
    final prefs = await _prefsOrNull();
    await prefs?.setString(_serverUrlKey, credentials.baseUrl);
    await prefs?.setString(_usernameKey, credentials.username);
    await prefs?.setString(_passwordKey, credentials.password);

    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    final prefs = await _prefsOrNull();
    await prefs?.remove(_serverUrlKey);
    await prefs?.remove(_usernameKey);
    await prefs?.remove(_passwordKey);

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _testing;
    final success = _testStatus?.startsWith('✓') ?? false;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        24,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Xtream Credentials',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Leave blank to browse the built-in demo content.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _serverController,
              enabled: !busy,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Server URL',
                hintText: 'e.g., http://line.example.com:8080',
                prefixIcon: const Icon(Icons.language),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              enabled: !busy,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Username',
                prefixIcon: const Icon(Icons.person),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              enabled: !busy,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            if (_testStatus != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (success ? Colors.green : Colors.red).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: success ? Colors.green : Colors.red),
                ),
                child: Text(
                  _testStatus!,
                  style: TextStyle(
                    color: success ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _testConnection,
                    icon: const Icon(Icons.wifi_tethering),
                    label: Text(_testing ? 'Testing...' : 'Test Connection'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _save,
                    icon: const Icon(Icons.save),
                    label: Text(_saving ? 'Saving...' : 'Save & Reload'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: busy ? null : _clear,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Clear and use demo content'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({
    super.key,
    required this.series,
    required this.credentials,
  });

  final SeriesItem series;
  final XtreamCredentials? credentials;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  late Future<List<EpisodeGroup>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<EpisodeGroup>> _load() =>
      XtreamService().loadEpisodes(widget.credentials, widget.series.id);

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.series.title)),
      body: FutureBuilder<List<EpisodeGroup>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return _ErrorView(
              error: snapshot.error!,
              onRetry: _reload,
              onOpenSettings: () => Navigator.of(context).pop(),
            );
          }

          final groups = snapshot.data ?? const <EpisodeGroup>[];
          if (groups.isEmpty) {
            return const _EmptyState(
              icon: Icons.tv_off,
              message: 'This series has no episodes listed',
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 90,
                      height: 130,
                      child: _Artwork(
                        url: widget.series.poster,
                        fallbackIcon: Icons.tv_outlined,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.series.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.series.subtitle,
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              for (final group in groups)
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  clipBehavior: Clip.antiAlias,
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ExpansionTile(
                    initiallyExpanded: group == groups.first,
                    title: Text('Season ${group.season}'),
                    subtitle: Text('${group.episodes.length} episodes'),
                    children: [
                      for (final episode in group.episodes)
                        ListTile(
                          leading: const Icon(
                            Icons.play_circle_outline,
                            color: Colors.red,
                          ),
                          title: Text(episode.title),
                          subtitle: episode.episodeNumber.isEmpty
                              ? null
                              : Text('Episode ${episode.episodeNumber}'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) => PlayerScreen(
                                playable: episode.toPlayable(widget.series.title),
                                credentials: widget.credentials,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.playable,
    required this.credentials,
    this.channels = const [],
    this.channelsTitle,
    this.onChannelChanged,
    this.initTimeout = const Duration(seconds: 12),
  });

  final Playable playable;
  final XtreamCredentials? credentials;

  /// Channels to offer alongside the player, e.g. the rest of the country.
  final List<LiveChannel> channels;
  final String? channelsTitle;

  /// Called when the user switches to another of [channels].
  final ValueChanged<LiveChannel>? onChannelChanged;

  /// How long to wait on one source before moving to the next. Exposed so
  /// tests can exercise the give-up path without waiting out the real value.
  final Duration initTimeout;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;

  /// Starts as the widget's, then follows whatever the channel list picks.
  late Playable _playable = widget.playable;
  Future<List<EpgProgram>>? _guideFuture;

  /// Lets the player move between the inline and fullscreen layouts without
  /// being rebuilt. On web the video is a real `<video>` element, and the
  /// browser pauses it the moment it is detached from the page.
  final _playerKey = GlobalKey();

  late final void Function() _stopFullscreenListener;

  bool _isInitialized = false;
  bool _isFullscreen = false;
  bool _showControls = true;
  Timer? _hideControlsTimer;
  static const _hideControlsAfter = Duration(seconds: 3);
  bool _isFavorite = false;
  bool _wasPlaying = false;
  bool _wasBuffering = false;

  /// Kept separately from the controller so it survives channel switches and
  /// retries, which each build a fresh controller at full volume.
  double _volume = 1.0;
  bool _isMuted = false;
  String? _error;
  String _status = 'Connecting…';
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _stopFullscreenListener = listenBrowserFullscreen((isFullscreen) {
      // Esc exits browser fullscreen without going through our button.
      if (!isFullscreen && _isFullscreen && mounted) _toggleFullscreen();
    });
    _initialisePlayer();
    _loadFavorite();
    _loadVolume();
    _loadGuide();
  }

  Future<void> _loadVolume() async {
    final prefs = await _prefsOrNull();
    if (prefs == null || !mounted) return;
    setState(() {
      _volume = (prefs.getDouble(_volumeKey) ?? 1.0).clamp(0.0, 1.0);
      _isMuted = prefs.getBool(_mutedKey) ?? false;
    });
    _applyVolume();
  }

  void _applyVolume() {
    _controller?.setVolume(_isMuted ? 0.0 : _volume);
  }

  void _setVolume(double volume) {
    setState(() {
      _volume = volume;
      // Moving the slider overrides mute; dragging it to zero is muting.
      _isMuted = volume == 0;
    });
    _applyVolume();
    // Keep the bar up while the slider is being dragged.
    _revealControls();
  }

  /// Saved on release rather than per slider tick to avoid a write per frame.
  Future<void> _saveVolume() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    await prefs.setDouble(_volumeKey, _volume);
    await prefs.setBool(_mutedKey, _isMuted);
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      // Unmuting at zero would look like the button did nothing.
      if (!_isMuted && _volume == 0) _volume = 0.5;
    });
    _applyVolume();
    _revealControls();
    _saveVolume();
  }

  void _loadGuide() {
    _guideFuture = _playable.isLive && _playable.epgStreamId != null
        ? XtreamService().loadGuide(widget.credentials, _playable.epgStreamId!)
        : null;
  }

  void _switchTo(LiveChannel channel) {
    if (channel.id == _playable.id) return;
    setState(() {
      _playable = channel.toPlayable();
      _isFavorite = false;
      _showControls = true;
      _loadGuide();
    });
    _loadFavorite();
    widget.onChannelChanged?.call(channel);
    _retry();
  }

  Future<void> _initialisePlayer() async {
    final candidates = _playable.candidateUrls;
    if (candidates.isEmpty) {
      setState(() => _error = 'This item does not have a playable stream URL.');
      return;
    }

    // Guards against a stale attempt finishing after Retry started a new one.
    final token = ++_attempt;

    // Panels disagree on the container they serve live channels in, and the
    // API never says which, so the only reliable answer is to try each.
    for (var i = 0; i < candidates.length; i++) {
      if (!mounted || token != _attempt) return;

      final uri = Uri.tryParse(candidates[i]);
      if (!_isFetchableUri(uri)) continue;

      setState(() {
        _status = candidates.length > 1
            ? 'Connecting… (source ${i + 1} of ${candidates.length})'
            : 'Connecting…';
      });

      final controller = VideoPlayerController.networkUrl(
        uri!,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      try {
        // `initialize()` never times out on its own — AVFoundation will sit
        // on an unresponsive stream indefinitely, which surfaces as a spinner
        // that never resolves. Bound it so a dead stream becomes an error.
        await controller.initialize().timeout(widget.initTimeout);
        if (!mounted || token != _attempt) {
          await _disposeQuietly(controller);
          return;
        }
        _controller = controller;
        controller.addListener(_onPlaybackUpdate);
        await controller.setVolume(_isMuted ? 0.0 : _volume);
        setState(() => _isInitialized = true);
        await controller.play().timeout(const Duration(seconds: 8));
        return;
      } on TimeoutException {
        await _disposeQuietly(controller);
      } catch (_) {
        await _disposeQuietly(controller);
      }
    }

    if (!mounted || token != _attempt) return;
    setState(() => _status = 'Checking what the server says…');

    // Everything failed. Ask the server directly so the message says what is
    // actually wrong rather than just "could not open".
    final diagnosis = await XtreamService.probeStream(candidates.first);
    if (!mounted || token != _attempt) return;
    setState(() => _error = diagnosis);
  }

  /// Hides the account password if it appears in a URL shown on screen.
  String _redact(String text) {
    final password = widget.credentials?.password;
    if (password == null || password.isEmpty) return text;
    return text
        .replaceAll(Uri.encodeComponent(password), '•••')
        .replaceAll(password, '•••');
  }

  void _onPlaybackUpdate() {
    final value = _controller?.value;
    if (value == null || !mounted) return;

    if (value.hasError) {
      if (_error == null) {
        setState(() => _error = value.errorDescription ?? 'Playback failed.');
      }
      return;
    }

    if (value.isPlaying != _wasPlaying || value.isBuffering != _wasBuffering) {
      final startedPlaying = value.isPlaying && !_wasPlaying;
      setState(() {
        _wasPlaying = value.isPlaying;
        _wasBuffering = value.isBuffering;
      });
      // Driven from here rather than the play button so Space, the
      // fullscreen resume and a live reconnect all behave the same.
      if (startedPlaying) {
        _revealControls();
      } else if (!value.isPlaying) {
        _hideControlsTimer?.cancel();
        setState(() => _showControls = true);
      }
    }
  }

  /// Shows the controls and restarts the countdown to hide them again.
  void _revealControls() {
    if (!_showControls) setState(() => _showControls = true);
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(_hideControlsAfter, () {
      // Paused or still loading: the controls are what the viewer needs.
      if (!mounted || !(_controller?.value.isPlaying ?? false)) return;
      setState(() => _showControls = false);
    });
  }

  void _onPlayerTap() {
    if (_showControls && (_controller?.value.isPlaying ?? false)) {
      _hideControlsTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _revealControls();
    }
  }

  /// A controller that failed to initialise can fail to dispose too. Letting
  /// that escape would abort whatever cleanup path called it — which is how
  /// the loading spinner ended up hanging instead of showing an error.
  static Future<void> _disposeQuietly(VideoPlayerController controller) async {
    try {
      await controller.dispose();
    } catch (_) {
      // Nothing useful to do; the controller is being discarded regardless.
    }
  }

  Future<void> _retry() async {
    final old = _controller;
    _controller = null;
    old?.removeListener(_onPlaybackUpdate);
    if (old != null) await _disposeQuietly(old);

    if (!mounted) return;
    setState(() {
      _error = null;
      _isInitialized = false;
      // So the new controller's first play counts as a start and kicks off
      // the auto-hide countdown.
      _wasPlaying = false;
      _status = 'Connecting…';
    });
    await _initialisePlayer();
  }

  Future<void> _loadFavorite() async {
    if (!_playable.isLive) return;
    final prefs = await _prefsOrNull();
    if (prefs == null || !mounted) return;
    final favorites = prefs.getStringList(_favoritesKey) ?? [];
    setState(() => _isFavorite = favorites.contains(_playable.id));
  }

  Future<void> _toggleFavorite() async {
    final next = !_isFavorite;
    setState(() => _isFavorite = next);

    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final favorites = (prefs.getStringList(_favoritesKey) ?? []).toSet();
    if (next) {
      favorites.add(_playable.id);
    } else {
      favorites.remove(_playable.id);
    }
    await prefs.setStringList(_favoritesKey, favorites.toList());
  }

  Future<void> _applyFullscreenMode(bool enable) async {
    // First, before any await: the browser only honours fullscreen requests
    // made synchronously inside the click handler.
    final browser = setBrowserFullscreen(enable);

    final orientations = enable
        ? <DeviceOrientation>[
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : <DeviceOrientation>[
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ];

    await SystemChrome.setPreferredOrientations(orientations);
    await SystemChrome.setEnabledSystemUIMode(
      enable ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    await browser;
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _stopFullscreenListener();
    unawaited(_applyFullscreenMode(false));
    _controller?.removeListener(_onPlaybackUpdate);
    _controller?.dispose();
    super.dispose();
  }

  void _toggleFullscreen() {
    final next = !_isFullscreen;
    final wasPlaying = _controller?.value.isPlaying ?? false;
    setState(() => _isFullscreen = next);
    unawaited(_applyFullscreenMode(next));

    // Belt and braces: if the platform still paused the video during the
    // layout switch, the controller would keep reporting it as playing and
    // the picture would sit frozen.
    if (wasPlaying) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller?.play();
      });
    }
  }

  Widget _buildPlayer() {
    // The key sits on the outermost widget so moving between layouts keeps
    // the whole subtree, video element included, intact.
    return MouseRegion(
      key: _playerKey,
      onHover: (_) => _revealControls(),
      // Hide the pointer along with the controls so nothing sits over the
      // picture.
      cursor: _showControls ? MouseCursor.defer : SystemMouseCursors.none,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _buildVideoSurface(),
          // Pinned to the video's bounds so the title sits at the top edge and
          // the progress bar and buttons at the bottom, rather than the overlay
          // shrinking to its content and floating mid-picture.
          Positioned.fill(child: _buildPlayerControls()),
        ],
      ),
    );
  }

  Widget _buildVideoSurface() {
    if (_error != null) {
      return _PlaybackError(
        title: _playable.title,
        message: _error!,
        attemptedUrls: [
          for (final url in _playable.candidateUrls) _redact(url),
        ],
        onRetry: _retry,
      );
    }

    if (!_isInitialized || _controller == null) {
      return SizedBox(
        height: 220,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(_status),
              const SizedBox(height: 4),
              Text(
                'Gives up after ${widget.initTimeout.inSeconds}s per source',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }

    return AspectRatio(
      aspectRatio: _controller!.value.aspectRatio,
      child: VideoPlayer(_controller!),
    );
  }

  Widget _buildPlayerControls() {
    final controller = _controller;
    if (controller == null || !_isInitialized) return const SizedBox.shrink();

    // IgnorePointer rather than Visibility: removing the overlay outright
    // would cut the fade-out short.
    return IgnorePointer(
      ignoring: !_showControls,
      child: AnimatedOpacity(
        opacity: _showControls ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.3),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.3),
              ],
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    if (_isFullscreen)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _toggleFullscreen,
                        color: Colors.white,
                      )
                    else
                      const SizedBox(width: 48),
                    Expanded(
                      child: Text(
                        _playable.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      ),
                      onPressed: _toggleFullscreen,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    // A live stream has no fixed length, so the bar would
                    // only show the local buffer, which tells the viewer
                    // nothing. Movies keep it as a seek bar.
                    if (!_playable.isLive) ...[
                      VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        colors: VideoProgressColors(
                          playedColor: Colors.red,
                          backgroundColor: Colors.grey.shade700,
                          bufferedColor: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      children: [
                        // Volume on the left, play/pause centred: the two
                        // Expanded sides keep the play button in the middle
                        // however wide the slider is.
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _buildVolumeControl(),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            controller.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                            size: 32,
                          ),
                          onPressed: _togglePlayPause,
                        ),
                        const Expanded(child: SizedBox()),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _togglePlayPause() {
    final controller = _controller;
    if (controller == null) return;

    if (controller.value.isPlaying) {
      controller.pause();
    } else if (_playable.isLive) {
      // Xtream servers drop an idle live connection within seconds, so the
      // paused player has nothing left to resume from and just freezes.
      // Reconnecting rejoins the channel at the live edge, which is what a
      // viewer expects from live TV anyway.
      _retry();
    } else {
      controller.play();
    }
  }

  Widget _buildVolumeControl() {
    final effective = _isMuted ? 0.0 : _volume;
    final icon = effective == 0
        ? Icons.volume_off
        : effective < 0.5
            ? Icons.volume_down
            : Icons.volume_up;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(icon),
          color: Colors.white,
          tooltip: _isMuted ? 'Unmute' : 'Mute',
          onPressed: _toggleMute,
        ),
        // Flexible so the slider gives way on a narrow phone screen instead
        // of overflowing into the play button.
        Flexible(
          child: SizedBox(
            width: 120,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white38,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: effective,
                onChanged: _setVolume,
                onChangeEnd: (_) => _saveVolume(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wraps both layouts so the shortcut keeps working across fullscreen
    // toggles. Key events bubble up from whatever has focus, so this sees
    // them even after a click has moved focus onto one of the buttons.
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.space) {
          _togglePlayPause();
          // Handled, so a focused button doesn't also activate on Space and
          // the browser doesn't scroll the page.
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _buildScreen(context),
    );
  }

  Widget _buildScreen(BuildContext context) {
    if (_isFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _onPlayerTap,
          child: Center(child: _buildPlayer()),
        ),
      );
    }

    final details = SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: ConstrainedBox(
                    // Full width on a phone, but on a wide browser window a
                    // full-width 16:9 player would push everything off-screen.
                    constraints: BoxConstraints(
                      maxWidth:
                          MediaQuery.sizeOf(context).height * 0.6 * 16 / 9,
                    ),
                    child: GestureDetector(
                      onTap: _onPlayerTap,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: Colors.black,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _buildPlayer(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _playable.title,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              if (_playable.isLive) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Row(
                                    children: [
                                      Icon(Icons.circle, color: Colors.red, size: 8),
                                      SizedBox(width: 4),
                                      Text(
                                        'LIVE',
                                        style: TextStyle(
                                          color: Colors.red,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: Text(
                                  _playable.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Colors.grey.shade400),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (_playable.isLive)
                      IconButton(
                        tooltip: _isFavorite
                            ? 'Remove from favourites'
                            : 'Add to favourites',
                        icon: Icon(
                          _isFavorite ? Icons.favorite : Icons.favorite_border,
                          color: Colors.red,
                        ),
                        onPressed: _toggleFavorite,
                      ),
                  ],
                ),
                if (_guideFuture != null) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Program Guide',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  _ProgramGuide(future: _guideFuture!),
                ],
              ],
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(_playable.title)),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Only beside the player: on a narrow screen the list would push
            // the guide out of sight.
            final hasRoom = constraints.maxWidth >= 1000;
            if (!hasRoom || widget.channels.length < 2) return details;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: details),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 320,
                  child: _ChannelSidebar(
                    title: widget.channelsTitle,
                    channels: widget.channels,
                    currentId: _playable.id,
                    onSelected: _switchTo,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ChannelSidebar extends StatelessWidget {
  const _ChannelSidebar({
    required this.title,
    required this.channels,
    required this.currentId,
    required this.onSelected,
  });

  final String? title;
  final List<LiveChannel> channels;
  final String currentId;
  final ValueChanged<LiveChannel> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title ?? 'Channels',
          trailing: '${channels.length}',
        ),
        Expanded(
          child: ListView.builder(
            itemCount: channels.length,
            itemBuilder: (context, index) {
              final channel = channels[index];
              return ListTile(
                selected: channel.id == currentId,
                selectedTileColor: Colors.white.withValues(alpha: 0.08),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 56,
                    height: 36,
                    child: _Artwork(
                      url: channel.logo,
                      fallbackIcon: Icons.live_tv,
                    ),
                  ),
                ),
                title: Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  channel.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => onSelected(channel),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({
    required this.title,
    required this.message,
    required this.onRetry,
    this.attemptedUrls = const [],
  });

  final String title;
  final String message;
  final List<String> attemptedUrls;
  final VoidCallback onRetry;

  /// The whole report as one block, ready to paste into a support thread.
  /// Built from the same redacted addresses shown on screen, so copying can
  /// never leak the password that the display took care to mask.
  String get _report => [
    'Xtream Player — playback error',
    'Channel: $title',
    '',
    message,
    if (attemptedUrls.isNotEmpty) ...[
      '',
      attemptedUrls.length == 1 ? 'Address tried:' : 'Addresses tried:',
      ...attemptedUrls,
    ],
  ].join('\n');

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _report));
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Error details copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 220),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade300, size: 36),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade300, fontSize: 13),
              ),
              // Shown flat rather than behind an ExpansionTile: that is a
              // ListTile, and a ListTile inside the player's black rounded
              // container trips a framework assertion about hidden ink.
              if (attemptedUrls.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  attemptedUrls.length == 1
                      ? 'Address tried'
                      : 'Addresses tried',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                ),
                const SizedBox(height: 4),
                for (final url in attemptedUrls)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: SelectableText(
                      url,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              // Wrap rather than Row: the card sits inside the video surface,
              // which can be narrow.
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _copy(context),
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy details'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgramGuide extends StatelessWidget {
  const _ProgramGuide({required this.future});

  final Future<List<EpgProgram>> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EpgProgram>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        if (snapshot.hasError) {
          return Text(
            'Guide unavailable: ${snapshot.error is XtreamException ? (snapshot.error as XtreamException).message : _shortError(snapshot.error!)}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          );
        }

        final programs = snapshot.data ?? const <EpgProgram>[];
        if (programs.isEmpty) {
          return Text(
            'No guide data for this channel.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          );
        }

        final now = DateTime.now();
        return Column(
          children: [
            for (final program in programs) _ProgramRow(program: program, now: now),
          ],
        );
      },
    );
  }
}

class _ProgramRow extends StatelessWidget {
  const _ProgramRow({required this.program, required this.now});

  final EpgProgram program;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final isLive = program.isAiringAt(now);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: isLive
              ? Colors.red.withValues(alpha: 0.1)
              : const Color(0xFF111827),
          borderRadius: BorderRadius.circular(12),
          border: isLive
              ? Border.all(color: Colors.red.withValues(alpha: 0.3))
              : null,
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isLive)
              const Padding(
                padding: EdgeInsets.only(right: 8, top: 4),
                child: SizedBox(
                  width: 8,
                  height: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        program.timeRangeLabel,
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isLive) const _Badge(label: 'NOW'),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    program.title.isEmpty ? 'Untitled programme' : program.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  if (program.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      program.description,
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<SharedPreferences?> _prefsOrNull() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (e) {
    debugPrint('SharedPreferences unavailable: $e');
    return null;
  }
}

/// A failure the user can act on, with a message written for them rather than
/// for a log file.
class XtreamException implements Exception {
  XtreamException(this.message, {this.canRetry = true});

  final String message;

  /// False when retrying the same request cannot possibly help (bad password,
  /// disabled account) so the UI can hide the retry button.
  final bool canRetry;

  @override
  String toString() => message;
}

class XtreamCredentials {
  const XtreamCredentials({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  final String baseUrl;
  final String username;
  final String password;

  static String normalize(String raw) {
    var url = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    return url;
  }

  static Future<XtreamCredentials?> load() async {
    final prefs = await _prefsOrNull();

    final baseUrl =
        normalize(prefs?.getString(_serverUrlKey) ?? _defaultServerUrl);
    final username = prefs?.getString(_usernameKey) ?? _defaultUsername;
    final password = prefs?.getString(_passwordKey) ?? _defaultPassword;
    if (baseUrl.isEmpty || username.isEmpty || password.isEmpty) return null;

    return XtreamCredentials(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
  }

  /// Builds a `player_api.php` call. Using [Uri.replace] rather than string
  /// interpolation means credentials with `&`, `+` or spaces survive the trip.
  Uri api([String? action, Map<String, String> params = const {}]) {
    return Uri.parse('$baseUrl/player_api.php').replace(
      queryParameters: <String, String>{
        'username': username,
        'password': password,
        'action': ?action,
        ...params,
      },
    );
  }

  String get _userPath =>
      '${Uri.encodeComponent(username)}/${Uri.encodeComponent(password)}';

  /// HLS form. Preferred because Apple's AVFoundation — what `video_player`
  /// uses on macOS and iOS — can play HLS but not a raw MPEG-TS stream.
  String liveUrl(String streamId) =>
      '$baseUrl/live/$_userPath/${Uri.encodeComponent(streamId)}.m3u8';

  /// MPEG-TS form. Some panels only serve this one.
  String liveUrlTs(String streamId) =>
      '$baseUrl/live/$_userPath/${Uri.encodeComponent(streamId)}.ts';

  String movieUrl(String streamId, String extension) =>
      '$baseUrl/movie/$_userPath/${Uri.encodeComponent(streamId)}.$extension';

  String episodeUrl(String episodeId, String extension) =>
      '$baseUrl/series/$_userPath/${Uri.encodeComponent(episodeId)}.$extension';
}

class XtreamService {
  static const Duration _timeout = Duration(seconds: 15);

  Future<AppData> loadData() async {
    final credentials = await XtreamCredentials.load();
    if (credentials == null) return _loadDemoData();
    return _loadRealData(credentials);
  }

  /// Verifies credentials and reports what the panel offers, for the
  /// settings sheet's "Test Connection" button.
  Future<String> probe(XtreamCredentials credentials) async {
    await _authenticate(credentials);
    final categories =
        _parseCategories(await _getJson(credentials.api('get_live_categories')));
    final noun = categories.length == 1 ? 'category' : 'categories';
    return 'Connected — ${categories.length} live $noun';
  }

  /// Asks the server about a stream that would not play, so the UI can say
  /// what went wrong. Reads the response headers and then drops the
  /// connection — a live stream never ends, so the body must not be buffered.
  static Future<String> probeStream(String url) async {
    final uri = Uri.tryParse(url);
    if (!_isFetchableUri(uri)) return 'The stream address is not a valid URL.';

    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', uri!))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 401 || response.statusCode == 403) {
        return 'The server refused this stream (HTTP ${response.statusCode}) — '
            'the account may not include this channel, or the maximum number '
            'of connections is already in use.';
      }
      if (response.statusCode == 404) {
        return 'The server has no stream at this address (HTTP 404). '
            'The channel may be off air, or this panel may use a different '
            'stream URL format.';
      }
      if (response.statusCode != 200) {
        return 'The server returned HTTP ${response.statusCode} for this stream.';
      }

      // This probe runs on the Dart HTTP client, which App Transport Security
      // does not police — so reaching here only proves the server is willing,
      // not that the platform player was allowed to make the same request.
      final contentType = response.headers['content-type'] ?? 'an unknown type';
      final isTransportStream =
          contentType.contains('mp2t') || contentType.contains('octet-stream');

      if (isTransportStream) {
        return 'The server delivered an MPEG-TS stream ($contentType). '
            'Apple platforms can only play HLS through video_player, so this '
            'channel needs a libmpv-based player such as media_kit.';
      }
      return 'The server delivered the stream ($contentType) but the player '
          'could not decode it.';
    } on TimeoutException {
      return 'The server did not respond within 10 seconds.';
    } catch (e) {
      return 'Could not reach the stream. ${_shortError(e)}';
    } finally {
      client.close();
    }
  }

  Future<dynamic> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await http.get(uri).timeout(_timeout);
    } on TimeoutException {
      throw XtreamException(
        'The server did not respond within ${_timeout.inSeconds} seconds.',
      );
    } catch (e) {
      throw XtreamException('Could not reach ${uri.host}. ${_shortError(e)}');
    }

    if (response.statusCode != 200) {
      final action = uri.queryParameters['action'] ?? 'login';
      throw XtreamException(
        'Server returned HTTP ${response.statusCode} for "$action".',
      );
    }

    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw XtreamException(
        'The server replied with something other than JSON. '
        'Check the URL and port point at an Xtream Codes panel.',
      );
    }
  }

  Future<void> _authenticate(XtreamCredentials credentials) async {
    final json = await _getJson(credentials.api());
    if (json is! Map || json['user_info'] is! Map) {
      throw XtreamException(
        'Unexpected response — this does not look like an Xtream Codes panel.',
      );
    }

    final info = json['user_info'] as Map;
    if ('${info['auth']}' != '1') {
      throw XtreamException('Invalid username or password.', canRetry: false);
    }

    final status = '${info['status'] ?? ''}';
    if (status.isNotEmpty && status.toLowerCase() != 'active') {
      throw XtreamException(
        'This account is $status.',
        canRetry: false,
      );
    }
  }

  Future<AppData> _loadRealData(XtreamCredentials credentials) async {
    await _authenticate(credentials);

    final categories =
        _parseCategories(await _getJson(credentials.api('get_live_categories')));
    final categoriesById = {for (final c in categories) c.id: c};

    // One request returns every live stream when category_id is omitted, so
    // there is no need to walk the category list (and no reason to cap it).
    final channels = <LiveChannel>[];
    final rawStreams = await _getJson(credentials.api('get_live_streams'));
    if (rawStreams is List) {
      for (final entry in rawStreams) {
        if (entry is! Map) continue;
        final streamId = '${entry['stream_id'] ?? ''}';
        if (streamId.isEmpty) continue;

        // `get_live_streams` never returns a playable `url`; the address has to
        // be composed from the account details. Some panels do fill in
        // `direct_source`, which is preferred when present.
        final directSource = '${entry['direct_source'] ?? ''}'.trim();
        final categoryId = '${entry['category_id'] ?? ''}';
        final category = categoriesById[categoryId];

        channels.add(
          LiveChannel(
            id: streamId,
            name: '${entry['name'] ?? 'Unknown'}',
            categoryId: categoryId,
            category: category?.shortName ?? 'Uncategorised',
            streamUrl: directSource.isNotEmpty
                ? directSource
                : credentials.liveUrl(streamId),
            fallbackUrls: [
              if (directSource.isNotEmpty) credentials.liveUrl(streamId),
              credentials.liveUrlTs(streamId),
            ],
            logo: '${entry['stream_icon'] ?? ''}',
          ),
        );
      }
    }

    if (channels.isEmpty) {
      throw XtreamException(
        'Signed in successfully, but this account has no live channels.',
      );
    }

    // VOD and series are optional on many panels — a failure there should not
    // take the whole playlist down, but it should still be visible.
    final warnings = <String>[];

    var movies = const <MediaItem>[];
    try {
      movies = await _loadMovies(credentials);
    } on XtreamException catch (e) {
      warnings.add('Movies unavailable — ${e.message}');
    }

    var series = const <SeriesItem>[];
    try {
      series = await _loadSeries(credentials);
    } on XtreamException catch (e) {
      warnings.add('Series unavailable — ${e.message}');
    }

    return AppData(
      credentials: credentials,
      categories: categories,
      channels: channels,
      movies: movies,
      series: series,
      warnings: warnings,
    );
  }

  Future<List<MediaItem>> _loadMovies(XtreamCredentials credentials) async {
    final categories =
        _parseCategories(await _getJson(credentials.api('get_vod_categories')));
    final categoryNames = {for (final c in categories) c.id: c.name};

    final raw = await _getJson(credentials.api('get_vod_streams'));
    if (raw is! List) return const [];

    final movies = <MediaItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final streamId = '${entry['stream_id'] ?? ''}';
      if (streamId.isEmpty) continue;

      final extension = '${entry['container_extension'] ?? ''}'.trim();
      final category = categoryNames['${entry['category_id']}'] ?? 'Movie';
      final year = '${entry['year'] ?? ''}'.trim();

      movies.add(
        MediaItem(
          id: streamId,
          title: '${entry['name'] ?? 'Unknown'}',
          subtitle: year.isEmpty ? category : '$year • $category',
          poster: '${entry['stream_icon'] ?? ''}',
          streamUrl: credentials.movieUrl(
            streamId,
            extension.isEmpty ? 'mp4' : extension,
          ),
        ),
      );
    }
    return movies;
  }

  Future<List<SeriesItem>> _loadSeries(XtreamCredentials credentials) async {
    final categories = _parseCategories(
      await _getJson(credentials.api('get_series_categories')),
    );
    final categoryNames = {for (final c in categories) c.id: c.name};

    final raw = await _getJson(credentials.api('get_series'));
    if (raw is! List) return const [];

    final series = <SeriesItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final seriesId = '${entry['series_id'] ?? ''}';
      if (seriesId.isEmpty) continue;

      final category = categoryNames['${entry['category_id']}'] ?? 'Series';
      final year = '${entry['year'] ?? entry['releaseDate'] ?? ''}'.trim();

      series.add(
        SeriesItem(
          id: seriesId,
          title: '${entry['name'] ?? 'Unknown'}',
          subtitle: year.isEmpty ? category : '$year • $category',
          poster: '${entry['cover'] ?? ''}',
        ),
      );
    }
    return series;
  }

  /// Episodes for a series, or demo episodes when running without a server.
  Future<List<EpisodeGroup>> loadEpisodes(
    XtreamCredentials? credentials,
    String seriesId,
  ) async {
    if (credentials == null) return _demoEpisodes();

    final json = await _getJson(
      credentials.api('get_series_info', {'series_id': seriesId}),
    );
    final episodes = json is Map ? json['episodes'] : null;
    if (episodes is! Map) return const [];

    final seasonKeys = episodes.keys.map((k) => '$k').toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));

    final groups = <EpisodeGroup>[];
    for (final season in seasonKeys) {
      final list = episodes[season];
      if (list is! List) continue;

      final items = <Episode>[];
      for (final entry in list) {
        if (entry is! Map) continue;
        final episodeId = '${entry['id'] ?? ''}';
        if (episodeId.isEmpty) continue;

        final extension = '${entry['container_extension'] ?? ''}'.trim();
        final number = '${entry['episode_num'] ?? ''}';
        final title = '${entry['title'] ?? ''}'.trim();

        items.add(
          Episode(
            id: episodeId,
            title: title.isEmpty ? 'Episode $number' : title,
            episodeNumber: number,
            streamUrl: credentials.episodeUrl(
              episodeId,
              extension.isEmpty ? 'mp4' : extension,
            ),
          ),
        );
      }

      if (items.isNotEmpty) {
        groups.add(EpisodeGroup(season: season, episodes: items));
      }
    }
    return groups;
  }

  /// Programme guide for a channel, or a demo guide without a server.
  Future<List<EpgProgram>> loadGuide(
    XtreamCredentials? credentials,
    String streamId,
  ) async {
    if (credentials == null) return _demoGuide();

    final json = await _getJson(
      credentials.api('get_short_epg', {'stream_id': streamId, 'limit': '12'}),
    );
    final listings = json is Map ? json['epg_listings'] : null;
    if (listings is! List) return const [];

    final programs = <EpgProgram>[];
    for (final entry in listings) {
      if (entry is! Map) continue;
      final start = _epgTime(entry['start_timestamp'], entry['start']);
      if (start == null) continue;

      programs.add(
        EpgProgram(
          start: start,
          end: _epgTime(entry['stop_timestamp'], entry['end']),
          title: _decodeEpgText('${entry['title'] ?? ''}'),
          description: _decodeEpgText('${entry['description'] ?? ''}'),
        ),
      );
    }

    programs.sort((a, b) => a.start.compareTo(b.start));
    return programs;
  }

  static DateTime? _epgTime(dynamic timestamp, dynamic fallback) {
    final seconds = int.tryParse('${timestamp ?? ''}');
    if (seconds != null && seconds > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      ).toLocal();
    }
    return DateTime.tryParse('${fallback ?? ''}');
  }

  /// Xtream base64-encodes EPG titles and descriptions, but not every panel
  /// does — fall back to the raw string when the decode produces nonsense.
  static String _decodeEpgText(String value) {
    if (value.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(value));
    } catch (_) {
      return value;
    }
  }

  static List<XtreamCategory> _parseCategories(dynamic json) {
    if (json is! List) return const [];
    final categories = <XtreamCategory>[];
    for (final entry in json) {
      if (entry is! Map) continue;
      final id = '${entry['category_id'] ?? ''}';
      if (id.isEmpty) continue;
      categories.add(
        XtreamCategory(id: id, name: '${entry['category_name'] ?? 'Unknown'}'),
      );
    }
    return categories;
  }

  static const _demoStream =
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

  Future<AppData> _loadDemoData() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // Prefixed the way real panels name their categories, so the region
    // grouping has something to work with in demo mode.
    final categories = [
      XtreamCategory(id: 'eu-news', name: 'EU | News'),
      XtreamCategory(id: 'eu-sports', name: 'EU | Sports'),
      XtreamCategory(id: 'am-news', name: 'AM | News'),
      XtreamCategory(id: 'am-movies', name: 'AM | Movies'),
      XtreamCategory(id: 'am-music', name: 'AM | Music'),
      XtreamCategory(id: 'ar-kids', name: 'AR | Kids'),
      XtreamCategory(id: 'misc', name: 'Documentaries'),
    ];

    final channels = [
      LiveChannel(
        id: 'bbc',
        name: 'BBC World',
        categoryId: 'eu-news',
        category: 'News',
        streamUrl: _demoStream,
        logo:
            'https://images.unsplash.com/photo-1516321318423-f06f85e504b3?auto=format&fit=crop&w=800&q=80',
      ),
      LiveChannel(
        id: 'espn',
        name: 'ESPN Live',
        categoryId: 'eu-sports',
        category: 'Sports',
        streamUrl: _demoStream,
        logo:
            'https://images.unsplash.com/photo-1547347298-4074fc3086f0?auto=format&fit=crop&w=800&q=80',
      ),
      LiveChannel(
        id: 'natgeo',
        name: 'National Geo',
        categoryId: 'misc',
        category: 'Documentaries',
        streamUrl: _demoStream,
        logo:
            'https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=800&q=80',
      ),
      LiveChannel(
        id: 'cartoon',
        name: 'Cartoon Club',
        categoryId: 'ar-kids',
        category: 'Kids',
        streamUrl: _demoStream,
        logo:
            'https://images.unsplash.com/photo-1517849845537-4d257902454a?auto=format&fit=crop&w=800&q=80',
      ),
      LiveChannel(
        id: 'mtv',
        name: 'MTV Hits',
        categoryId: 'am-music',
        category: 'Music',
        streamUrl: _demoStream,
        logo:
            'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?auto=format&fit=crop&w=800&q=80',
      ),
      LiveChannel(
        id: 'cnn',
        name: 'CNN News',
        categoryId: 'am-news',
        category: 'News',
        streamUrl: _demoStream,
        logo:
            'https://images.unsplash.com/photo-1529107386315-e1a2ed48a620?auto=format&fit=crop&w=800&q=80',
      ),
      LiveChannel(
        id: 'hbo',
        name: 'HBO Premiere',
        categoryId: 'am-movies',
        category: 'Movies',
        streamUrl: _demoStream,
        logo:
            'https://images.unsplash.com/photo-1517604931442-7e0c8ed2963c?auto=format&fit=crop&w=800&q=80',
      ),
    ];

    final movies = [
      MediaItem(
        id: 'dune2',
        title: 'Dune: Part Two',
        subtitle: '2024 • Sci-Fi',
        poster:
            'https://images.unsplash.com/photo-1517604931442-7e0c8ed2963c?auto=format&fit=crop&w=800&q=80',
        streamUrl: _demoStream,
      ),
      MediaItem(
        id: 'creator',
        title: 'The Creator',
        subtitle: '2023 • Action',
        poster:
            'https://images.unsplash.com/photo-1489599849927-2ee91cede3ba?auto=format&fit=crop&w=800&q=80',
        streamUrl: _demoStream,
      ),
      MediaItem(
        id: 'arrival',
        title: 'Arrival',
        subtitle: '2016 • Drama',
        poster:
            'https://images.unsplash.com/photo-1513106580091-1d82408b8cd6?auto=format&fit=crop&w=800&q=80',
        streamUrl: _demoStream,
      ),
    ];

    final series = [
      SeriesItem(
        id: 'last-kingdom',
        title: 'The Last Kingdom',
        subtitle: '2023 • Adventure',
        poster:
            'https://images.unsplash.com/photo-1516280440614-37939bbacd81?auto=format&fit=crop&w=800&q=80',
      ),
      SeriesItem(
        id: 'dark-matter',
        title: 'Dark Matter',
        subtitle: '2024 • Thriller',
        poster:
            'https://images.unsplash.com/photo-1504384308090-c894fdcc538d?auto=format&fit=crop&w=800&q=80',
      ),
      SeriesItem(
        id: 'stranger-things',
        title: 'Stranger Things',
        subtitle: '2025 • Drama',
        poster:
            'https://images.unsplash.com/photo-1542204165-65bf26472b9b?auto=format&fit=crop&w=800&q=80',
      ),
    ];

    return AppData(
      credentials: null,
      categories: categories,
      channels: channels,
      movies: movies,
      series: series,
      warnings: const [],
    );
  }

  Future<List<EpisodeGroup>> _demoEpisodes() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return [
      EpisodeGroup(
        season: '1',
        episodes: [
          for (var i = 1; i <= 4; i++)
            Episode(
              id: 'demo-s1e$i',
              title: 'Episode $i',
              episodeNumber: '$i',
              streamUrl: _demoStream,
            ),
        ],
      ),
      EpisodeGroup(
        season: '2',
        episodes: [
          for (var i = 1; i <= 3; i++)
            Episode(
              id: 'demo-s2e$i',
              title: 'Episode $i',
              episodeNumber: '$i',
              streamUrl: _demoStream,
            ),
        ],
      ),
    ];
  }

  Future<List<EpgProgram>> _demoGuide() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final now = DateTime.now();
    const titles = [
      ('Morning News', 'Latest news and world updates'),
      ('Sports Center', 'Live sports coverage and highlights'),
      ('World Report', 'In-depth international reporting'),
      ('Live Match', 'Championship game coverage'),
      ('Movie Night', 'Classic cinema presentation'),
    ];

    return [
      for (var i = 0; i < titles.length; i++)
        EpgProgram(
          start: now.add(Duration(hours: i * 2)),
          end: now.add(Duration(hours: i * 2 + 2)),
          title: titles[i].$1,
          description: titles[i].$2,
        ),
    ];
  }
}

class AppData {
  AppData({
    required this.credentials,
    required this.categories,
    required this.channels,
    required this.movies,
    required this.series,
    required this.warnings,
  });

  /// Null while showing demo content.
  final XtreamCredentials? credentials;
  final List<XtreamCategory> categories;
  final List<LiveChannel> channels;
  final List<MediaItem> movies;
  final List<SeriesItem> series;
  final List<String> warnings;

  bool get isDemo => credentials == null;
}

class XtreamCategory {
  /// Panels conventionally prefix category names with a region or language
  /// code — "EU | Sports HD", "AR - News", "US: Kids", "4K | Movies". That
  /// prefix is shared across many categories, so it makes a natural top level
  /// to group by.
  factory XtreamCategory({required String id, required String name}) {
    final match = _groupPattern.firstMatch(name);
    return XtreamCategory._(
      id: id,
      name: name,
      group: match?.group(1) ?? ungrouped,
      shortName: match?.group(2)?.trim() ?? name.trim(),
    );
  }

  const XtreamCategory._({
    required this.id,
    required this.name,
    required this.group,
    required this.shortName,
  });

  /// Bucket for categories that carry no recognisable prefix.
  static const String ungrouped = 'Other';

  /// Deliberately strict: the code must be 2–4 uppercase alphanumerics
  /// followed by a separator, so "Sports - HD" is left alone while
  /// "EU | Sports" splits.
  static final RegExp _groupPattern = RegExp(
    r'^[\s|]*([A-Z0-9]{2,4})\s*[|:\-–—]\s*(.+)$',
  );

  final String id;

  /// The full name as the panel sent it, e.g. "EU | Sports HD".
  final String name;

  /// The leading region/language code, or [ungrouped].
  final String group;

  /// The name with the group prefix stripped, e.g. "Sports HD".
  final String shortName;
}

/// Anything the player can open, whatever tab it came from.
class Playable {
  const Playable({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.streamUrl,
    required this.isLive,
    this.fallbackUrls = const [],
    this.epgStreamId,
  });

  final String id;
  final String title;
  final String subtitle;
  final String streamUrl;
  final bool isLive;

  /// Alternate addresses to try if [streamUrl] fails. Panels differ on which
  /// container they serve live channels in, and the API does not say which.
  final List<String> fallbackUrls;

  /// Set for live channels so the player can pull a guide.
  final String? epgStreamId;

  List<String> get candidateUrls => [
    if (streamUrl.isNotEmpty) streamUrl,
    ...fallbackUrls.where((url) => url.isNotEmpty && url != streamUrl),
  ];
}

class LiveChannel {
  LiveChannel({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.category,
    required this.streamUrl,
    required this.logo,
    this.fallbackUrls = const [],
  });

  final String id;
  final String name;

  /// Filtering keys off the id rather than the display name, so two panels
  /// that reuse a category name stay distinct.
  final String categoryId;
  final String category;
  final String streamUrl;
  final String logo;

  /// Alternate container for the same channel, tried if [streamUrl] fails.
  final List<String> fallbackUrls;

  Playable toPlayable() => Playable(
        id: id,
        title: name,
        subtitle: category,
        streamUrl: streamUrl,
        fallbackUrls: fallbackUrls,
        isLive: true,
        epgStreamId: id,
      );
}

class MediaItem {
  MediaItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.poster,
    required this.streamUrl,
  });

  final String id;
  final String title;
  final String subtitle;
  final String poster;
  final String streamUrl;

  Playable toPlayable() => Playable(
        id: id,
        title: title,
        subtitle: subtitle,
        streamUrl: streamUrl,
        isLive: false,
      );
}

class SeriesItem {
  SeriesItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.poster,
  });

  final String id;
  final String title;
  final String subtitle;
  final String poster;
}

class EpisodeGroup {
  EpisodeGroup({required this.season, required this.episodes});

  final String season;
  final List<Episode> episodes;
}

class Episode {
  Episode({
    required this.id,
    required this.title,
    required this.episodeNumber,
    required this.streamUrl,
  });

  final String id;
  final String title;
  final String episodeNumber;
  final String streamUrl;

  Playable toPlayable(String seriesTitle) => Playable(
        id: id,
        title: title,
        subtitle: seriesTitle,
        streamUrl: streamUrl,
        isLive: false,
      );
}

class EpgProgram {
  EpgProgram({
    required this.start,
    required this.end,
    required this.title,
    required this.description,
  });

  final DateTime start;
  final DateTime? end;
  final String title;
  final String description;

  bool isAiringAt(DateTime now) {
    if (now.isBefore(start)) return false;
    final finish = end;
    if (finish != null) return now.isBefore(finish);
    // Without an end time, assume a two-hour slot.
    return now.isBefore(start.add(const Duration(hours: 2)));
  }

  String get timeRangeLabel {
    final formatter = DateFormat('HH:mm');
    final finish = end;
    if (finish == null) return formatter.format(start);
    return '${formatter.format(start)} – ${formatter.format(finish)}';
  }
}
