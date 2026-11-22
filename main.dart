import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:sqflite/sqflite.dart';

/// سطر كلمات واحد مع وقته
class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

/// كلمات أغنية: متزامنة (LRC) أو نص عادي
class Lyrics {
  final List<LyricLine> lines;
  final List<String> plain;
  const Lyrics(this.lines, this.plain);

  bool get synced => lines.isNotEmpty;
  int get length => synced ? lines.length : plain.length;

  static final _ts = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  factory Lyrics.parse(String raw) {
    final out = <LyricLine>[];
    for (final line in raw.split('\n')) {
      final ms = _ts.allMatches(line).toList();
      if (ms.isEmpty) continue;
      final text = line.replaceAll(_ts, '').trim();
      for (final m in ms) {
        final frac = (m[3] ?? '0').padRight(3, '0').substring(0, 3);
        out.add(LyricLine(
          Duration(
            minutes: int.parse(m[1]!),
            seconds: int.parse(m[2]!),
            milliseconds: int.parse(frac),
          ),
          text,
        ));
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    final plain = raw.split('\n').map((e) => e.trimRight()).toList();
    return Lyrics(out, plain);
  }
}

/// تخزين الكلمات داخل الهاتف
class Db {
  static Database? _db;

  static Future<Database> get _d async => _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'lyrics.db'),
        version: 1,
        onCreate: (d, v) => d.execute(
            'CREATE TABLE lyrics(song_id INTEGER PRIMARY KEY, body TEXT NOT NULL)'),
      );

  static Future<String?> get(int id) async {
    final r = await (await _d).query('lyrics', where: 'song_id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first['body'] as String;
  }

  static Future<void> save(int id, String body) async {
    await (await _d).insert('lyrics', {'song_id': id, 'body': body},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(int id) async {
    await (await _d).delete('lyrics', where: 'song_id=?', whereArgs: [id]);
  }

  static Future<Set<int>> ids() async {
    final r = await (await _d).query('lyrics', columns: ['song_id']);
    return r.map((e) => e['song_id'] as int).toSet();
  }
}

/// سحب الكلمات من LRCLIB (مجاني وبدون مفتاح)
class LrcLib {
  static const _headers = {'User-Agent': 'LyricsPlayer/1.0'};

  static Future<List<Map<String, dynamic>>> _search(Map<String, String> q) async {
    final r = await http
        .get(Uri.https('lrclib.net', '/api/search', q), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return [];
    final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
    return list.cast<Map<String, dynamic>>();
  }

  static Future<String?> fetch(String title, String artist, int durationSec) async {
    var res = await _search({
      'track_name': title,
      if (artist.isNotEmpty) 'artist_name': artist,
    });
    if (res.isEmpty) {
      res = await _search({'q': '$title $artist'.trim()});
    }
    if (res.isEmpty) return null;

    String? s(Map<String, dynamic> m, String k) {
      final v = m[k];
      return (v is String && v.trim().isNotEmpty) ? v : null;
    }

    num diff(Map<String, dynamic> m) =>
        ((m['duration'] as num?) ?? 0) - durationSec > 0
            ? ((m['duration'] as num?) ?? 0) - durationSec
            : durationSec - ((m['duration'] as num?) ?? 0);

    final synced = res.where((m) => s(m, 'syncedLyrics') != null).toList()
      ..sort((a, b) => diff(a).compareTo(diff(b)));
    if (synced.isNotEmpty) return s(synced.first, 'syncedLyrics');

    for (final m in res) {
      final plain = s(m, 'plainLyrics');
      if (plain != null) return plain;
    }
    return null;
  }
}

String cleanArtist(String? a) => (a == null || a == '<unknown>') ? '' : a;

/// المشغّل الرئيسي (واحد لكل التطبيق)
class Ctrl {
  static final player = AudioPlayer();
  static List<SongModel> queue = [];
  static final current = ValueNotifier<SongModel?>(null);
  static bool _inited = false;

  static void init() {
    if (_inited) return;
    _inited = true;
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) next();
    });
  }

  static Future<void> play(List<SongModel> q, int i) async {
    queue = q;
    final s = q[i];
    current.value = s;
    final uri = s.uri != null ? Uri.parse(s.uri!) : Uri.file(s.data);
    await player.setAudioSource(AudioSource.uri(uri));
    player.play();
  }

  static Future<void> _step(int d) async {
    final c = current.value;
    if (c == null || queue.isEmpty) return;
    final i = queue.indexWhere((e) => e.id == c.id);
    await play(queue, (i + d + queue.length) % queue.length);
  }

  static Future<void> next() => _step(1);
  static Future<void> prev() => _step(-1);
}

const ink = Color(0xFF1B1424);
const surface = Color(0xFF261C33);
const saffron = Color(0xFFF2B84B);
const paper = Color(0xFFF3ECE2);
const muted = Color(0xFF9B8FAE);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Ctrl.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مشغل الكلمات',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: ink,
        colorScheme: const ColorScheme.dark(
          primary: saffron,
          surface: surface,
          onSurface: paper,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: ink,
          foregroundColor: paper,
          elevation: 0,
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: saffron,
          thumbColor: saffron,
          inactiveTrackColor: Color(0xFF3A2D4A),
        ),
      ),
      builder: (c, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _q = OnAudioQuery();
  List<SongModel> songs = [];
  Set<int> withLyrics = {};
  bool loading = true, denied = false;
  String filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      denied = false;
    });
    var st = await Permission.audio.request();
    if (!st.isGranted) st = await Permission.storage.request();
    if (!st.isGranted) {
      setState(() {
        loading = false;
        denied = true;
      });
      return;
    }
    final all = await _q.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );
    songs = all.where((s) => (s.duration ?? 0) > 30000).toList();
    withLyrics = await Db.ids();
    if (mounted) setState(() => loading = false);
  }

  Future<void> _refreshIds() async {
    final ids = await Db.ids();
    if (mounted) setState(() => withLyrics = ids);
  }

  void _open() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerPage()))
        .then((_) => _refreshIds());
  }

  @override
  Widget build(BuildContext context) {
    final f = filter.trim().toLowerCase();
    final shown = f.isEmpty
        ? songs
        : songs
            .where((s) =>
                s.title.toLowerCase().contains(f) ||
                cleanArtist(s.artist).toLowerCase().contains(f))
            .toList();

    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (denied) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('التطبيق يحتاج إذن الوصول إلى الأغاني على الهاتف.',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('إعطاء الإذن')),
            TextButton(
                onPressed: openAppSettings, child: const Text('فتح إعدادات التطبيق')),
          ]),
        ),
      );
    } else if (songs.isEmpty) {
      body = const Center(child: Text('ما لقيت أغاني على الهاتف'));
    } else {
      body = ListView.builder(
        itemCount: shown.length,
        itemBuilder: (c, i) {
          final s = shown[i];
          final artist = cleanArtist(s.artist);
          return ListTile(
            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: artist.isEmpty
                ? null
                : Text(artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted)),
            leading: const Icon(Icons.music_note, color: muted),
            trailing: withLyrics.contains(s.id)
                ? const Icon(Icons.lyrics, color: saffron, size: 20)
                : null,
            onTap: () {
              Ctrl.play(shown, i);
              _open();
            },
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('الأغاني')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => filter = v),
            decoration: InputDecoration(
              hintText: 'ابحث باسم الأغنية أو الفنان',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(child: body),
      ]),
      bottomNavigationBar: ValueListenableBuilder<SongModel?>(
        valueListenable: Ctrl.current,
        builder: (c, s, _) {
          if (s == null) return const SizedBox.shrink();
          return Material(
            color: surface,
            child: SafeArea(
              child: ListTile(
                onTap: _open,
                title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: StreamBuilder<bool>(
                  stream: Ctrl.player.playingStream,
                  builder: (c, ps) => IconButton(
                    icon: Icon(ps.data == true ? Icons.pause : Icons.play_arrow,
                        color: saffron),
                    onPressed: () =>
                        ps.data == true ? Ctrl.player.pause() : Ctrl.player.play(),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

bool _isArabic(String s) => RegExp(r'[\u0600-\u06FF]').hasMatch(s);

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// يسأل عن الاسم والفنان ثم يسحب الكلمات. يرجع النص أو null.
Future<String?> fetchOnline(BuildContext context, SongModel s) async {
  final t = TextEditingController(text: s.title);
  final a = TextEditingController(text: cleanArtist(s.artist));
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('سحب الكلمات من الإنترنت'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            controller: t,
            decoration: const InputDecoration(labelText: 'اسم الأغنية')),
        const SizedBox(height: 8),
        TextField(
            controller: a,
            decoration: const InputDecoration(labelText: 'الفنان (اختياري)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('بحث')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  final msg = ScaffoldMessenger.of(context);
  msg.showSnackBar(const SnackBar(
      content: Text('جاري البحث...'), duration: Duration(seconds: 20)));
  try {
    final r = await LrcLib.fetch(t.text.trim(), a.text.trim(), (s.duration ?? 0) ~/ 1000);
    msg.hideCurrentSnackBar();
    if (r == null) {
      msg.showSnackBar(const SnackBar(
          content: Text('ما لكيت كلمات. جرّب تعدّل اسم الأغنية أو الفنان.')));
    }
    return r;
  } catch (_) {
    msg.hideCurrentSnackBar();
    msg.showSnackBar(const SnackBar(content: Text('تعذّر الاتصال بالإنترنت.')));
    return null;
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SongModel?>(
      valueListenable: Ctrl.current,
      builder: (context, s, _) {
        if (s == null) return const Scaffold();
        final artist = cleanArtist(s.artist);
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17)),
              if (artist.isNotEmpty)
                Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: muted)),
            ]),
          ),
          body: Column(children: [
            Expanded(child: LyricsView(key: ValueKey(s.id), song: s)),
            const Controls(),
          ]),
        );
      },
    );
  }
}

class LyricsView extends StatefulWidget {
  final SongModel song;
  const LyricsView({super.key, required this.song});
  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  Lyrics? lyrics;
  bool loading = true;
  int active = -1;
  int offsetMs = 0;
  final sc = ItemScrollController();
  StreamSubscription<Duration>? sub;

  @override
  void initState() {
    super.initState();
    _load();
    sub = Ctrl.player.positionStream.listen(_onPos);
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final raw = await Db.get(widget.song.id);
    if (!mounted) return;
    setState(() {
      lyrics = raw == null ? null : Lyrics.parse(raw);
      loading = false;
      active = -1;
    });
  }

  void _onPos(Duration pos) {
    final l = lyrics;
    if (l == null || !l.synced) return;
    final t = pos + Duration(milliseconds: offsetMs);
    var idx = -1;
    for (var i = 0; i < l.lines.length; i++) {
      if (l.lines[i].time <= t) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx != active) {
      setState(() => active = idx);
      if (idx >= 0 && sc.isAttached) {
        sc.scrollTo(
            index: idx,
            alignment: 0.4,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut);
      }
    }
  }

  Future<void> _edit() async {
    final raw = await Db.get(widget.song.id) ?? '';
    if (!mounted) return;
    final saved = await Navigator.push<bool>(context,
        MaterialPageRoute(builder: (_) => EditPage(song: widget.song, initial: raw)));
    if (saved == true) _load();
  }

  Future<void> _fetch() async {
    final r = await fetchOnline(context, widget.song);
    if (r != null) {
      await Db.save(widget.song.id, r);
      _load();
    }
  }

  void _seekTo(LyricLine l) {
    var d = l.time - Duration(milliseconds: offsetMs);
    if (d < Duration.zero) d = Duration.zero;
    Ctrl.player.seek(d);
  }

  Widget _line(int i) {
    final l = lyrics!;
    final raw = l.synced ? l.lines[i].text : l.plain[i];
    final text = raw.isEmpty ? (l.synced ? '♪' : ' ') : raw;
    final on = l.synced && i == active;
    return InkWell(
      onTap: l.synced ? () => _seekTo(l.lines[i]) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 24),
        child: Directionality(
          textDirection: _isArabic(text) ? TextDirection.rtl : TextDirection.ltr,
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            style: TextStyle(
              fontSize: on ? 27 : 20,
              height: 1.45,
              fontWeight: on ? FontWeight.w700 : FontWeight.w400,
              color: on ? saffron : (l.synced ? muted : paper),
            ),
            textAlign: TextAlign.center,
            child: Text(text, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (loading) {
      content = const Center(child: CircularProgressIndicator());
    } else if (lyrics == null) {
      content = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('ماكو كلمات لهذي الأغنية'),
          const SizedBox(height: 16),
          FilledButton.icon(
              onPressed: _fetch,
              icon: const Icon(Icons.cloud_download),
              label: const Text('سحب من الإنترنت')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.edit),
              label: const Text('إضافة يدوياً')),
        ]),
      );
    } else {
      content = ScrollablePositionedList.builder(
        itemScrollController: sc,
        padding: const EdgeInsets.symmetric(vertical: 140),
        itemCount: lyrics!.length,
        itemBuilder: (c, i) => _line(i),
      );
    }

    return Column(children: [
      Expanded(child: content),
      if (lyrics != null)
        Container(
          color: surface,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            IconButton(
                tooltip: 'تعديل الكلمات',
                onPressed: _edit,
                icon: const Icon(Icons.edit)),
            IconButton(
                tooltip: 'سحب من الإنترنت',
                onPressed: _fetch,
                icon: const Icon(Icons.cloud_download)),
            const Spacer(),
            if (lyrics!.synced) ...[
              const Text('ضبط التوقيت', style: TextStyle(color: muted, fontSize: 13)),
              IconButton(
                  onPressed: () => setState(() => offsetMs -= 500),
                  icon: const Icon(Icons.remove_circle_outline)),
              SizedBox(
                width: 48,
                child: Text(
                  '${offsetMs >= 0 ? '+' : ''}${(offsetMs / 1000).toStringAsFixed(1)}',
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                ),
              ),
              IconButton(
                  onPressed: () => setState(() => offsetMs += 500),
                  icon: const Icon(Icons.add_circle_outline)),
            ],
          ]),
        ),
    ]);
  }
}

class Controls extends StatelessWidget {
  const Controls({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            StreamBuilder<Duration?>(
              stream: Ctrl.player.durationStream,
              builder: (c, ds) {
                final dur = ds.data ?? Duration.zero;
                final mx = dur.inMilliseconds < 1 ? 1.0 : dur.inMilliseconds.toDouble();
                return StreamBuilder<Duration>(
                  stream: Ctrl.player.positionStream,
                  builder: (c, ps) {
                    final pos = ps.data ?? Duration.zero;
                    final v = pos.inMilliseconds.toDouble().clamp(0.0, mx);
                    return Column(children: [
                      Slider(
                        value: v,
                        max: mx,
                        onChanged: (x) =>
                            Ctrl.player.seek(Duration(milliseconds: x.toInt())),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_fmt(pos), style: const TextStyle(color: muted)),
                            Text(_fmt(dur), style: const TextStyle(color: muted)),
                          ],
                        ),
                      ),
                    ]);
                  },
                );
              },
            ),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                  iconSize: 38,
                  onPressed: Ctrl.prev,
                  icon: const Icon(Icons.skip_previous)),
              const SizedBox(width: 12),
              StreamBuilder<PlayerState>(
                stream: Ctrl.player.playerStateStream,
                builder: (c, st) {
                  final playing = st.data?.playing ?? false;
                  return IconButton.filled(
                    iconSize: 44,
                    style: IconButton.styleFrom(
                        backgroundColor: saffron, foregroundColor: Colors.black),
                    onPressed: () =>
                        playing ? Ctrl.player.pause() : Ctrl.player.play(),
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  );
                },
              ),
              const SizedBox(width: 12),
              IconButton(
                  iconSize: 38,
                  onPressed: Ctrl.next,
                  icon: const Icon(Icons.skip_next)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class EditPage extends StatefulWidget {
  final SongModel song;
  final String initial;
  const EditPage({super.key, required this.song, required this.initial});
  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final TextEditingController c = TextEditingController(text: widget.initial);

  Future<void> _save() async {
    final t = c.text.trim();
    if (t.isEmpty) {
      await Db.delete(widget.song.id);
    } else {
      await Db.save(widget.song.id, t);
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _fetch() async {
    final r = await fetchOnline(context, widget.song);
    if (r != null) setState(() => c.text = r);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الكلمات'),
        actions: [
          IconButton(
              tooltip: 'سحب من الإنترنت',
              onPressed: _fetch,
              icon: const Icon(Icons.cloud_download)),
          IconButton(tooltip: 'حفظ', onPressed: _save, icon: const Icon(Icons.check)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          const Text(
            'للتزامن اكتب كل سطر بهذي الصيغة:  [01:23.50] نص السطر\n'
            'أو الصق نص عادي بدون توقيت (يظهر بدون تزامن). مسح كل النص يحذف الكلمات.',
            style: TextStyle(color: muted, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: c,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(height: 1.5),
              decoration: InputDecoration(
                filled: true,
                fillColor: surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
