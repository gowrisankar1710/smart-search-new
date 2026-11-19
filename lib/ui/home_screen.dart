import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../services/locations.dart';
import '../services/recent_searches.dart';
import '../services/search_engine.dart';
import 'detail_panel.dart';
import 'capabilities_grid.dart';
import 'category_status.dart';
import 'format.dart';
import 'result_tile.dart';
import 'settings_sheet.dart';
import 'theme.dart';
import 'video_player_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  ResultFilter _filter = ResultFilter.all;
  String? _under; // limit to one location
  String? _selected; // path of the result shown in the right panel
  SearchResult _result = SearchResult.empty;
  int _seenRevision = 0;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _seenRevision = c.revision;
    c.addListener(_onController);
    // Start the "time until search" clock once the screen is on display.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) c.enterSearchScreen();
    });
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    _debounce?.cancel();
    _refresh?.cancel();
    _remember?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onController() {
    if (c.revision != _seenRevision) {
      _seenRevision = c.revision;
      if (_query.text.trim().isNotEmpty) _scheduleRefresh();
    }
  }

  /// Files read or changed while a search is open show up in it – but quietly, at most
  /// every [_refreshGap]: while files are being read the index changes many times a
  /// second, and re-running the search each time made the list flicker and typing lag.
  static const _refreshGap = Duration(seconds: 2);
  Timer? _refresh;

  void _scheduleRefresh() {
    _refresh ??= Timer(_refreshGap, () {
      _refresh = null;
      if (!mounted || _query.text.trim().isEmpty) return;
      // Typing or a search still running: that search sees the new files anyway.
      if ((_debounce?.isActive ?? false) || _searching) return _scheduleRefresh();
      _search(quiet: true);
    });
  }

  void _onChanged(String _) {
    setState(() {});
    _refresh?.cancel();
    _refresh = null;
    _debounce?.cancel();
    _remember?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _search);
  }

  /// A search counts as made once the user presses Enter, picks a result, or stops
  /// typing on a query that found something – not on every keystroke.
  Timer? _remember;
  void _rememberQuery() {
    _remember?.cancel();
    final q = _query.text.trim();
    if (q.isNotEmpty) c.recent.add(q);
  }

  void _useRecent(String q) {
    _query.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    setState(() {});
    _search();
    c.recent.add(q);
    _focus.requestFocus();
  }

  int _gen = 0; // bumps on every new query; older runs see it and stop
  bool _searching = false;

  /// [quiet]: a refresh for files read meanwhile, not something the user typed – the
  /// list on screen stays as it is (no spinner, no half-finished list) and is replaced
  /// only if the finished search found something different.
  Future<void> _search({bool quiet = false}) async {
    final gen = ++_gen;
    void show(SearchResult r) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _result = r;
        if (_selected != null && !r.hits.any((h) => h.file.path == _selected)) _selected = null;
      });
    }

    if (!quiet) {
      setState(() => _searching = true);
      if (_query.text.trim().isNotEmpty) c.searchBegan();
    }
    final r = await c.engine.findAsync(
      _query.text,
      kinds: _filter.kinds,
      under: _under,
      cancelled: () => !mounted || gen != _gen,
      onPartial: quiet ? null : show,
    );
    if (r == null || !mounted || gen != _gen) return;
    if (quiet) {
      if (!_sameHits(_result, r)) show(r);
      return;
    }
    show(r);
    setState(() => _searching = false);
    if (_query.text.trim().isNotEmpty) c.searchFinished(r.took);
    if (r.hits.isNotEmpty) {
      _remember?.cancel();
      _remember = Timer(const Duration(seconds: 2), () {
        if (mounted && gen == _gen) _rememberQuery();
      });
    }
  }

  static bool _sameHits(SearchResult a, SearchResult b) {
    if (a.total != b.total || a.hits.length != b.hits.length) return false;
    for (var i = 0; i < a.hits.length; i++) {
      if (!identical(a.hits[i].file, b.hits[i].file)) return false;
    }
    return true;
  }

  void _clear() {
    _remember?.cancel();
    _refresh?.cancel();
    _refresh = null;
    _query.clear();
    _gen++;
    setState(() {
      _searching = false;
      _result = SearchResult.empty;
      _selected = null;
    });
    _focus.requestFocus();
  }

  void _setFilter(ResultFilter f) {
    setState(() => _filter = f);
    _search();
  }

  void _setLocation(String? path) {
    setState(() => _under = path);
    _search();
  }

  int _countFor(ResultFilter f) {
    final kinds = f.kinds;
    if (kinds == null) return _result.allKinds;
    return kinds.fold(0, (sum, k) => sum + (_result.kindCounts[k] ?? 0));
  }

  SearchHit? get _selectedHit {
    for (final h in _result.hits) {
      if (h.file.path == _selected) return h;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clear},
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => LayoutBuilder(builder: (context, box) {
            final showSidebar = box.maxWidth >= 760;
            final showDetails = box.maxWidth >= 1100;
            final hasQuery = _query.text.trim().isNotEmpty;
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (showSidebar)
                SizedBox(
                  width: 240,
                  child: _Sidebar(
                    controller: c,
                    filter: _filter,
                    under: _under,
                    countFor: hasQuery ? _countFor : null,
                    onFilter: _setFilter,
                    onLocation: _setLocation,
                  ),
                ),
              Expanded(child: _center(context, hasQuery, showSidebar, showDetails)),
              if (showDetails)
                SizedBox(width: 340, child: DetailPanel(hit: _selectedHit, controller: c)),
            ]);
          }),
        ),
      ),
    );
  }

  Widget _center(BuildContext context, bool hasQuery, bool showSidebar, bool showDetails) {
    final stats = c.stats;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!showSidebar) _CompactHeader(controller: c),
            Padding(
              padding: EdgeInsets.fromLTRB(24, showSidebar ? 28 : 4, 24, 0),
              child: _SearchField(
                controller: _query,
                focus: _focus,
                onChanged: _onChanged,
                onSubmitted: () {
                  _rememberQuery();
                  if (_result.hits.isNotEmpty) openHit(context, _result.hits.first);
                },
                onClear: _clear,
              ),
            ),
            _TimingStrip(controller: c),
            // Idle, the "What you can search" cards show progress; while searching, one line.
            if (hasQuery) ReadingProgressCard(controller: c),
            CategoryLine(controller: c),
            if (!showSidebar && hasQuery && _result.allKinds > 0) ...[
              const SizedBox(height: 12),
              _FilterChips(selected: _filter, countFor: _countFor, onSelected: _setFilter),
            ],
            if (hasQuery) _ResultSummary(result: _result, query: _query.text.trim(), searching: _searching),
            Expanded(
              child: !hasQuery
                  ? SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _RecentSearches(recent: c.recent, onUse: _useRecent),
                        CapabilitiesGrid(controller: c),
                      ]),
                    )
                  : _result.hits.isEmpty
                      ? (_searching
                          ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                          : _NoResults(query: _query.text.trim(), pending: c.showReading ? stats.pending : 0))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(24, 2, 24, 24),
                          itemCount: _result.hits.length,
                          itemBuilder: (_, i) {
                            final h = _result.hits[i];
                            return ResultTile(
                              key: ValueKey(h.file.path),
                              hit: h,
                              selected: showDetails && h.file.path == _selected,
                              onSelect: showDetails
                                  ? () {
                                      _rememberQuery();
                                      setState(() => _selected = h.file.path);
                                    }
                                  : null,
                            );
                          },
                        ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ sidebar

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.filter,
    required this.under,
    required this.countFor,
    required this.onFilter,
    required this.onLocation,
  });
  final AppController controller;
  final ResultFilter filter;
  final String? under;
  final int Function(ResultFilter)? countFor;
  final ValueChanged<ResultFilter> onFilter;
  final ValueChanged<String?> onLocation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final c = controller;
    // New files per category (green "N new" badge), from what the folder watcher saw.
    final adds = c.recentAdds;
    List<RecentAdd> newIn(ResultFilter f) =>
        [for (final a in adds) if (f.kinds == null || f.kinds!.contains(a.kind)) a];
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(right: BorderSide(color: cs.outlineVariant)),
      ),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
            child: Row(children: [
              const _Logo(),
              const SizedBox(width: 10),
              Text('Smart Search', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
              const _SideLabel('Browse'),
              for (final f in ResultFilter.values)
                _SideItem(
                  icon: f.icon,
                  label: f.label,
                  count: countFor?.call(f),
                  fresh: newIn(f),
                  isRead: c.isRead,
                  selected: f == filter,
                  onTap: () => onFilter(f),
                ),
              const SizedBox(height: 14),
              const _SideLabel('Locations'),
              _SideItem(
                icon: Icons.public_rounded,
                label: 'Everywhere',
                selected: under == null,
                onTap: () => onLocation(null),
              ),
              for (final ScanRoot r in c.roots)
                _SideItem(
                  icon: r.userAdded ? Icons.folder_special_outlined : Icons.folder_outlined,
                  label: r.label,
                  tooltip: friendlyPath(r.path),
                  selected: under == r.path,
                  onTap: () => onLocation(r.path),
                ),
              _SideItem(
                icon: Icons.add_rounded,
                label: 'Add folder',
                muted: true,
                onTap: () async {
                  final root = await c.pickAndAddFolder();
                  if (root != null && context.mounted) await openAnalysis(context, c, only: [root]);
                },
              ),
            ]),
          ),
          _StatusCard(controller: c),
        ]),
      ),
    );
  }
}

class _SideLabel extends StatelessWidget {
  const _SideLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
      child: Text(text.toUpperCase(),
          style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.count,
    this.fresh = const [],
    this.isRead,
    this.selected = false,
    this.muted = false,
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final int? count;

  /// Files of this category added in the last few minutes.
  final List<RecentAdd> fresh;
  final bool Function(String path)? isRead;
  final bool selected;
  final bool muted;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final fg = selected ? cs.primary : (muted ? cs.onSurfaceVariant : cs.onSurface);
    final dim = count == 0;
    final item = Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          hoverColor: Colors.white.withValues(alpha: 0.7),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: selected
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 1))],
                  )
                : null,
            child: Row(children: [
              Icon(icon, size: 18, color: dim ? fg.withValues(alpha: 0.4) : fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: dim ? fg.withValues(alpha: 0.45) : fg,
                    )),
              ),
              if (fresh.isNotEmpty) ...[
                _NewBadge(fresh: fresh, isRead: isRead),
                const SizedBox(width: 6),
              ],
              if (count != null && count! > 0)
                Text(formatCount(count!),
                    style: tt.labelSmall?.copyWith(
                      color: selected ? cs.primary : cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )),
            ]),
          ),
        ),
      ),
    );
    return tooltip == null ? item : Tooltip(message: tooltip!, child: item);
  }
}

/// Green "3 new" pill on a sidebar category. While a new file is still being read it
/// shows a small spinner; the tooltip names each file and whether it's searchable yet.
class _NewBadge extends StatelessWidget {
  const _NewBadge({required this.fresh, required this.isRead});
  final List<RecentAdd> fresh;
  final bool Function(String path)? isRead;

  static const _green = Color(0xFF22B573);

  @override
  Widget build(BuildContext context) {
    final reading = isRead != null && fresh.any((a) => !isRead!(a.path));
    final shown = fresh.take(8).toList();
    final more = fresh.length - shown.length;
    return Tooltip(
      message: [
        for (final a in shown) '${a.name}${isRead == null ? '' : (isRead!(a.path) ? ' · searchable' : ' · reading…')}',
        if (more > 0) '+$more more',
      ].join('\n'),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 2, 7, 2),
        decoration: BoxDecoration(
          color: _green.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (reading)
            const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.4, color: _green))
          else
            Container(width: 6, height: 6, decoration: const BoxDecoration(color: _green, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text('${fresh.length} new',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _green, height: 1.2)),
        ]),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = controller.stats;
    final reading = controller.showReading;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(children: [
        if (reading)
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: cs.primary))
        else
          Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(color: Color(0xFF34C759), shape: BoxShape.circle),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${formatCount(s.total)} files', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
            Text(
              reading ? _readingLine(controller, s.pending) : 'All read',
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ]),
        ),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(Icons.settings_outlined, size: 20, color: cs.onSurfaceVariant),
          onPressed: () => showSettingsSheet(context, controller),
        ),
      ]),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4F5BFF), Color(0xFF9B5CFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Icon(Icons.search_rounded, color: Colors.white, size: 18),
    );
  }
}

/// Narrow windows / phones: no sidebar, so a slim header with status + settings.
class _CompactHeader extends StatelessWidget {
  const _CompactHeader({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = controller.stats;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
      child: Row(children: [
        const _Logo(),
        const SizedBox(width: 10),
        Text('Smart Search', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(controller.showReading ? _readingLine(controller, s.pending) : '${formatCount(s.total)} files',
            style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(Icons.settings_outlined, color: cs.onSurfaceVariant),
          onPressed: () => showSettingsSheet(context, controller),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ search field

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focus,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: cs.outlineVariant),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: const Color(0xFF4F5BFF).withValues(alpha: 0.06), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: TextField(
        controller: controller,
        focusNode: focus,
        autofocus: !(Platform.isAndroid || Platform.isIOS),
        textInputAction: TextInputAction.search,
        onChanged: onChanged,
        onSubmitted: (_) => onSubmitted(),
        style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w500),
        cursorWidth: 1.6,
        decoration: InputDecoration(
          hintText: 'Search names, text inside files, or what a photo shows',
          hintStyle: tt.titleMedium?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.65)),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 16, right: 10),
            child: Icon(Icons.search_rounded, color: cs.primary),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  tooltip: 'Clear (Esc)',
                  icon: Icon(Icons.close_rounded, size: 20, color: cs.onSurfaceVariant),
                  onPressed: onClear,
                )
              : null,
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 18),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(borderSide: BorderSide(color: cs.primary, width: 1.5)),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ timing

/// "Indexed in 42.1 s · On Search 0:07 – waiting for your search" (live), then
/// "Search began 3.2 s after opening · took 12 ms".
class _TimingStrip extends StatefulWidget {
  const _TimingStrip({required this.controller});
  final AppController controller;

  @override
  State<_TimingStrip> createState() => _TimingStripState();
}

class _TimingStripState extends State<_TimingStrip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      // Repaint only while the clock runs or background reading changes the numbers.
      final c = widget.controller;
      if (mounted && (c.waitingForSearch || c.backgroundProgress != null)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final c = widget.controller;
    final t = c.timing;
    final style = tt.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]);
    final strong = TextStyle(color: cs.onSurface, fontWeight: FontWeight.w700);

    Widget item(IconData icon, List<InlineSpan> spans, {String? tooltip}) {
      final w = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: cs.primary),
        const SizedBox(width: 4),
        Text.rich(TextSpan(style: style, children: spans)),
      ]);
      return tooltip == null ? w : Tooltip(message: tooltip, child: w);
    }

    final items = <Widget>[
      if (t.indexTime != null)
        item(Icons.timer_outlined, [
          const TextSpan(text: 'Indexed in '),
          TextSpan(text: formatSeconds(t.indexTime!), style: strong),
        ], tooltip: t.indexAt == null ? null : 'Last indexing pass: ${formatDate(t.indexAt!)}'),
      if (c.waitingForSearch)
        item(Icons.hourglass_top_rounded, [
          const TextSpan(text: 'On Search '),
          TextSpan(text: formatSeconds(c.searchScreenElapsed), style: strong),
          const TextSpan(text: ' · waiting for your search'),
        ])
      else if (t.waitBeforeSearch != null) ...[
        item(Icons.hourglass_bottom_rounded, [
          const TextSpan(text: 'Search began '),
          TextSpan(text: formatSeconds(t.waitBeforeSearch!), style: strong),
          const TextSpan(text: ' after opening'),
        ], tooltip: 'Time from entering the Search screen until the search started'),
        if (t.searchTook != null)
          item(Icons.bolt_rounded, [
            const TextSpan(text: 'took '),
            TextSpan(text: formatMillis(t.searchTook!), style: strong),
          ]),
      ],
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
      child: Wrap(spacing: 14, runSpacing: 4, children: items),
    );
  }
}

// ------------------------------------------------------------------ narrow-layout filters

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.countFor, required this.onSelected});
  final ResultFilter selected;
  final int Function(ResultFilter) countFor;
  final ValueChanged<ResultFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final f in ResultFilter.values)
        if (f == ResultFilter.all || f == selected || countFor(f) > 0) f,
    ];
    return SizedBox(
      height: 34,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        scrollDirection: Axis.horizontal,
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final f = visible[i];
          return ChoiceChip(
            selected: f == selected,
            onSelected: (_) => onSelected(f),
            label: Text('${f.label}  ${formatCount(countFor(f))}'),
          );
        },
      ),
    );
  }
}

class _ResultSummary extends StatelessWidget {
  const _ResultSummary({required this.result, required this.query, required this.searching});
  final SearchResult result;
  final String query;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    if (result.total == 0 && result.allKinds == 0) return const SizedBox(height: 12);
    final n = formatCount(result.total);
    final files = result.total == 1 ? 'file' : 'files';
    final style = tt.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final strong = TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600);

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 18, 26, 10),
      child: Row(children: [
        if (searching)
          SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.6, color: cs.primary))
        else
          const Icon(Icons.check_circle_rounded, size: 15, color: Color(0xFF34C759)),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: style,
              children: result.exact
                  ? [
                      TextSpan(text: '$n $files', style: strong),
                      const TextSpan(text: ' contain '),
                      TextSpan(text: '“$query”', style: strong),
                    ]
                  : [
                      const TextSpan(text: 'No exact match for '),
                      TextSpan(text: '“$query”', style: strong),
                      TextSpan(text: ' · showing $n closest $files'),
                    ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(searching ? 'Searching…' : '${result.took.inMilliseconds} ms',
            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

// ------------------------------------------------------------------ empty states

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query, required this.pending});
  final String query;
  final int pending;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_off_rounded, size: 40, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 14),
          Text('No file contains “$query”',
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(
            pending > 0
                ? 'Still reading ${formatCount(pending)} files – results may appear shortly.'
                : 'Only exact text is matched – check the spelling, try fewer words, or add a folder.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ recent searches

/// The last searches, newest first: tap one to search it again, × to forget it.
/// Hidden until there is one.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.recent, required this.onUse});
  final RecentSearches recent;
  final ValueChanged<String> onUse;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: recent,
      builder: (context, _) {
        final items = recent.items;
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text('RECENT SEARCHES',
                    style: TextStyle(
                        fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
              ),
              const Spacer(),
              TextButton(
                onPressed: recent.clear,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Clear'),
              ),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final q in items)
                InputChip(
                  avatar: Icon(Icons.history_rounded, size: 16, color: cs.onSurfaceVariant),
                  label: Text(q, overflow: TextOverflow.ellipsis),
                  tooltip: 'Search “$q” again',
                  onPressed: () => onUse(q),
                  onDeleted: () => recent.remove(q),
                  deleteButtonTooltipMessage: 'Remove from recent searches',
                  deleteIcon: const Icon(Icons.close_rounded, size: 16),
                  backgroundColor: Colors.white,
                  side: BorderSide(color: cs.outlineVariant),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
            ]),
          ]),
        );
      },
    );
  }
}

/// "Reading · 1,240 left", then "Reading · 1,240 files · about 4 min left" once the time
/// can be estimated.
String _readingLine(AppController c, int pending) {
  final p = c.backgroundProgress;
  final n = formatCount(p?.remaining ?? pending);
  final left = p?.video != null ? null : p?.timeLeft;
  return left == null ? 'Reading · $n left' : 'Reading · $n files · ${formatTimeLeft(left)}';
}
