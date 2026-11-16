import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../services/locations.dart';
import '../services/search_engine.dart';
import 'detail_panel.dart';
import 'format.dart';
import 'result_tile.dart';
import 'settings_sheet.dart';
import 'theme.dart';

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
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onController() {
    if (c.revision != _seenRevision) {
      _seenRevision = c.revision;
      if (_query.text.trim().isNotEmpty) _search();
    }
  }

  void _onChanged(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _search);
  }

  void _search() {
    final r = c.engine.find(_query.text, kinds: _filter.kinds, under: _under);
    if (!mounted) return;
    setState(() {
      _result = r;
      if (_selected != null && !r.hits.any((h) => h.file.path == _selected)) _selected = null;
    });
  }

  void _clear() {
    _query.clear();
    setState(() {
      _result = SearchResult.empty;
      _selected = null;
    });
    _focus.requestFocus();
  }

  void _setQuery(String q) {
    _query.text = q;
    _query.selection = TextSelection.collapsed(offset: q.length);
    _search();
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
                  if (_result.hits.isNotEmpty) openFile(context, _result.hits.first.file.path);
                },
                onClear: _clear,
              ),
            ),
            if (!showSidebar && hasQuery && _result.allKinds > 0) ...[
              const SizedBox(height: 12),
              _FilterChips(selected: _filter, countFor: _countFor, onSelected: _setFilter),
            ],
            if (hasQuery) _ResultSummary(result: _result, query: _query.text.trim()),
            Expanded(
              child: !hasQuery
                  ? _Welcome(onExample: _setQuery)
                  : _result.hits.isEmpty
                      ? _NoResults(query: _query.text.trim(), pending: stats.pending)
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(24, 2, 24, 24),
                          itemCount: _result.hits.length,
                          itemBuilder: (_, i) {
                            final h = _result.hits[i];
                            return ResultTile(
                              key: ValueKey(h.file.path),
                              hit: h,
                              selected: showDetails && h.file.path == _selected,
                              onSelect: showDetails ? () => setState(() => _selected = h.file.path) : null,
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
    this.selected = false,
    this.muted = false,
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final int? count;
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = controller.stats;
    final reading = controller.backgroundProgress != null || s.pending > 0;
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
              reading ? 'Reading · ${formatCount(controller.backgroundProgress?.remaining ?? s.pending)} left' : 'All read',
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
        Text(s.pending > 0 ? 'Reading · ${formatCount(s.pending)} left' : '${formatCount(s.total)} files',
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
          hintText: 'Search file names, text inside files and images',
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
  const _ResultSummary({required this.result, required this.query});
  final SearchResult result;
  final String query;

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
        Icon(result.exact ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            size: 15, color: result.exact ? const Color(0xFF34C759) : const Color(0xFFF5A524)),
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
        Text('${result.took.inMilliseconds} ms', style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

// ------------------------------------------------------------------ empty states

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onExample});
  final ValueChanged<String> onExample;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    const examples = ['invoice', 'boarding pass', 'wifi password', 'resume', 'bank statement', 'screenshot'];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.manage_search_rounded, size: 32, color: cs.primary),
            ),
            const SizedBox(height: 18),
            Text('Find anything you remember',
                textAlign: TextAlign.center,
                style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4)),
            const SizedBox(height: 8),
            Text(
              'A word from the file name, a line inside a document, or text in a photo or screenshot.',
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.45),
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in examples)
                  ActionChip(
                    label: Text(e),
                    avatar: Icon(Icons.north_west_rounded, size: 14, color: cs.onSurfaceVariant),
                    onPressed: () => onExample(e),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

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
          Text('Nothing found for “$query”',
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(
            pending > 0
                ? 'Still reading ${formatCount(pending)} files – results may appear shortly.'
                : 'Try fewer or different words, another type or location, or add a folder.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}
