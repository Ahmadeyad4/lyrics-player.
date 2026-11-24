import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, FileSystemException, IOSink;
import 'dart:math' show Random;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:audio_service/audio_service.dart'
    show
        AudioProcessingState,
        AudioService,
        AudioServiceConfig,
        BaseAudioHandler,
        MediaAction,
        MediaControl,
        MediaItem,
        PlaybackState,
        SeekHandler;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// يرتفع رقمه لما تتغير المكتبة (مثلاً بعد نقل أغنية) حتى الرئيسية تعيد القراءة
final libraryVersion = ValueNotifier<int>(0);

/// نفس القناة اللي يستعملها MainActivity (فتح الملفات + مسح الميديا)
const _nativeCh = MethodChannel('lyricplayer/open');

/// يرتفع رقمه لما تخلّص الرئيسية من إعادة قراءة المكتبة (حتى الصفحات المفتوحة تتحدّث)
final libraryLoaded = ValueNotifier<int>(0);

/// آخر قائمة أغاني قرأها التطبيق (بعد تطبيق الأسماء المعدّلة)
Map<int, SongModel> libraryById = {};

SongModel _withMeta(SongModel s, String title, String artist) => SongModel({
      '_id': s.id,
      '_data': s.data,
      '_uri': s.uri,
      '_display_name': s.displayName,
      '_display_name_wo_ext': p.basenameWithoutExtension(s.displayName),
      '_size': s.size,
      'album': s.album,
      'artist': artist,
      'duration': s.duration,
      'title': title,
    });

/// يطبّق الأسماء/الفنانين اللي عدّلها المستخدم داخل التطبيق
Future<List<SongModel>> applyMeta(List<SongModel> list) async {
  final m = await Db.metaAll();
  if (m.isEmpty) return list;
  return [
    for (final s in list)
      m[s.id] == null ? s : _withMeta(s, m[s.id]![0], m[s.id]![1])
  ];
}

class Db {
  static Database? _db;

  static const _tables = [
    'CREATE TABLE IF NOT EXISTS lyrics(song_id INTEGER PRIMARY KEY, body TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS translations(song_id INTEGER PRIMARY KEY, body TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS favorites(song_id INTEGER PRIMARY KEY)',
    'CREATE TABLE IF NOT EXISTS hidden(song_id INTEGER PRIMARY KEY)',
    'CREATE TABLE IF NOT EXISTS playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS playlist_songs(playlist_id INTEGER NOT NULL, song_id INTEGER NOT NULL, pos INTEGER NOT NULL, PRIMARY KEY(playlist_id, song_id))',
    'CREATE TABLE IF NOT EXISTS meta_override(song_id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL)',
  ];

  static Future<void> _create(Database d) async {
    for (final q in _tables) {
      await d.execute(q);
    }
  }

  static Future<Database> get _d async => _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'lyrics.db'),
        version: 6,
        onCreate: (d, v) => _create(d),
        onUpgrade: (d, o, n) async {
          await _create(d);
          // الترجمة صارت من الإنكليزي للعربي، فنمسح القديمة
          if (o < 3) await d.execute('DELETE FROM translations');
        },
      );

  // ---- إعدادات بسيطة (مفتاح/قيمة) ----
  static Future<String?> getKv(String k) async {
    final r = await (await _d).query('kv', where: 'k=?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String;
  }

  static Future<void> setKv(String k, String v) async {
    await (await _d).insert('kv', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---- أغاني مخفية من التطبيق ----
  static Future<Set<int>> hiddenIds() async {
    final r = await (await _d).query('hidden');
    return r.map((e) => e['song_id'] as int).toSet();
  }

  static Future<void> hide(int id) async {
    await (await _d).insert('hidden', {'song_id': id},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> unhide(int id) async {
    await (await _d).delete('hidden', where: 'song_id=?', whereArgs: [id]);
  }

  /// بعد الحذف النهائي: نمسح كل شي مرتبط بالأغنية ونخفيها
  static Future<void> purge(int id) async {
    final d = await _d;
    await d.delete('lyrics', where: 'song_id=?', whereArgs: [id]);
    await d.delete('translations', where: 'song_id=?', whereArgs: [id]);
    await d.delete('favorites', where: 'song_id=?', whereArgs: [id]);
    await d.delete('playlist_songs', where: 'song_id=?', whereArgs: [id]);
    await d.delete('meta_override', where: 'song_id=?', whereArgs: [id]);
    await d.delete('kv', where: 'k=?', whereArgs: ['off_$id']);
    await hide(id);
  }

  // ---- أسماء/فنانين معدّلين داخل التطبيق ----
  static Future<Map<int, List<String>>> metaAll() async {
    final r = await (await _d).query('meta_override');
    return {
      for (final e in r)
        e['song_id'] as int: [e['title'] as String, e['artist'] as String]
    };
  }

  static Future<void> setMeta(int id, String title, String artist) async {
    await (await _d).insert(
        'meta_override', {'song_id': id, 'title': title, 'artist': artist},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> clearMeta(int id) async {
    await (await _d).delete('meta_override', where: 'song_id=?', whereArgs: [id]);
  }

  /// ضبط توقيت الكلمات لكل أغنية (محفوظ كـ off_<id>)
  static Future<Map<int, int>> offsets() async {
    final r = await (await _d).query('kv', where: "k LIKE 'off_%'");
    final m = <int, int>{};
    for (final e in r) {
      final id = int.tryParse((e['k'] as String).substring(4));
      final v = int.tryParse(e['v'] as String);
      if (id != null && v != null) m[id] = v;
    }
    return m;
  }

  /// بعد نقل الملف يتغير رقم الأغنية بالمكتبة، فننقل الكلمات والترجمة والمفضلة والقوائم للرقم الجديد
  static Future<void> moveId(int from, int to) async {
    if (from == to) return;
    final d = await _d;
    await d.transaction((t) async {
      final wasHidden =
          (await t.query('hidden', where: 'song_id=?', whereArgs: [from])).isNotEmpty;
      for (final tb in ['lyrics', 'translations', 'favorites', 'playlist_songs', 'meta_override']) {
        await t.rawUpdate('UPDATE OR REPLACE $tb SET song_id=? WHERE song_id=?', [to, from]);
      }
      final off = await t.query('kv', where: 'k=?', whereArgs: ['off_$from']);
      if (off.isNotEmpty) {
        await t.insert('kv', {'k': 'off_$to', 'v': off.first['v']},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await t.delete('kv', where: 'k=?', whereArgs: ['off_$from']);
      }
      if (wasHidden) {
        await t.insert('hidden', {'song_id': to},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      // الرقم القديم يبقى مخفي حتى ما يطلع نسخة وهمية إذا المكتبة لسا تذكره
      await t.insert('hidden', {'song_id': from},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  // ---- المفضلة ----
  static Future<Set<int>> favs() async {
    final r = await (await _d).query('favorites');
    return r.map((e) => e['song_id'] as int).toSet();
  }

  static Future<void> setFav(int id, bool on) async {
    final d = await _d;
    if (on) {
      await d.insert('favorites', {'song_id': id},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await d.delete('favorites', where: 'song_id=?', whereArgs: [id]);
    }
  }

  // ---- قوائم التشغيل ----
  static Future<List<Map<String, Object?>>> playlists() async {
    return (await _d).rawQuery(
        'SELECT p.id AS id, p.name AS name, '
        '(SELECT COUNT(*) FROM playlist_songs s WHERE s.playlist_id = p.id) AS n '
        'FROM playlists p ORDER BY p.id');
  }

  static Future<int> newPlaylist(String name) async =>
      (await _d).insert('playlists', {'name': name});

  static Future<void> renamePlaylist(int id, String name) async {
    await (await _d)
        .update('playlists', {'name': name}, where: 'id=?', whereArgs: [id]);
  }

  static Future<void> deletePlaylist(int id) async {
    final d = await _d;
    await d.delete('playlist_songs', where: 'playlist_id=?', whereArgs: [id]);
    await d.delete('playlists', where: 'id=?', whereArgs: [id]);
  }

  static Future<List<int>> playlistSongIds(int pid) async {
    final r = await (await _d).query('playlist_songs',
        where: 'playlist_id=?', whereArgs: [pid], orderBy: 'pos');
    return r.map((e) => e['song_id'] as int).toList();
  }

  static Future<void> addToPlaylist(int pid, int songId) async {
    await (await _d).rawInsert(
        'INSERT OR IGNORE INTO playlist_songs(playlist_id, song_id, pos) '
        'VALUES(?, ?, (SELECT COALESCE(MAX(pos), 0) + 1 FROM playlist_songs WHERE playlist_id = ?))',
        [pid, songId, pid]);
  }

  static Future<void> removeFromPlaylist(int pid, int songId) async {
    await (await _d).delete('playlist_songs',
        where: 'playlist_id=? AND song_id=?', whereArgs: [pid, songId]);
  }

  static Future<Map<int, String>> allTr() async {
    final r = await (await _d).query('translations');
    return {for (final e in r) e['song_id'] as int: e['body'] as String};
  }

  static Future<String?> get(int id) async {
    final r = await (await _d).query('lyrics', where: 'song_id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first['body'] as String;
  }

  /// حفظ الكلمات (وأي ترجمة قديمة تنحذف لأن الأسطر تغيّرت)
  static Future<void> save(int id, String body) async {
    final d = await _d;
    await d.insert('lyrics', {'song_id': id, 'body': body},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await d.delete('translations', where: 'song_id=?', whereArgs: [id]);
  }

  static Future<void> delete(int id) async {
    final d = await _d;
    await d.delete('lyrics', where: 'song_id=?', whereArgs: [id]);
    await d.delete('translations', where: 'song_id=?', whereArgs: [id]);
  }

  static Future<List<String>?> getTr(int id) async {
    final r = await (await _d)
        .query('translations', where: 'song_id=?', whereArgs: [id]);
    if (r.isEmpty) return null;
    return (jsonDecode(r.first['body'] as String) as List)
        .map((e) => e.toString())
        .toList();
  }

  static Future<void> saveTr(int id, List<String> t) async {
    await (await _d).insert('translations', {'song_id': id, 'body': jsonEncode(t)},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<int, String>> all() async {
    final r = await (await _d).query('lyrics');
    return {for (final e in r) e['song_id'] as int: e['body'] as String};
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

/// ترجمة سطر بسطر من الإنكليزي للعربي (تحتاج إنترنت، وتنحفظ بالهاتف بعدها)
class Translator {
  static final _arabic = RegExp(r'[\u0600-\u06FF]');
  static final _latin = RegExp(r'[A-Za-z]');

  static Future<String> _one(String text) async {
    Object? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await http.get(
          Uri.https('translate.googleapis.com', '/translate_a/single', {
            'client': 'gtx',
            'sl': 'auto',
            'tl': 'ar',
            'dt': 't',
            'q': text,
          }),
          headers: {'User-Agent': 'Mozilla/5.0'},
        ).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) throw Exception('http ${r.statusCode}');
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as List;
        return (j[0] as List)
            .map((e) => ((e as List)[0] ?? '').toString())
            .join()
            .trim();
      } catch (e) {
        last = e;
      }
    }
    throw last ?? Exception('translate failed');
  }

  /// يترجم الأسطر الإنكليزية فقط (الأسطر العربية تبقى بدون ترجمة)، ويرجع قائمة بنفس الطول
  static Future<List<String>> lines(List<String> src) async {
    final out = List<String>.filled(src.length, '');
    final todo = [
      for (var i = 0; i < src.length; i++)
        if (_latin.hasMatch(src[i]) && !_arabic.hasMatch(src[i])) i
    ];
    for (var k = 0; k < todo.length; k += 6) {
      final end = k + 6 > todo.length ? todo.length : k + 6;
      final chunk = todo.sublist(k, end);
      final res = await Future.wait(chunk.map((i) => _one(src[i])));
      for (var j = 0; j < chunk.length; j++) {
        out[chunk[j]] = res[j];
      }
    }
    return out;
  }
}

String cleanArtist(String? a) => (a == null || a == '<unknown>') ? '' : a;

/// المشغّل الرئيسي (واحد لكل التطبيق)
class Ctrl {
  static final player = AudioPlayer();
  static List<SongModel> queue = [];
  static String queueName = 'كل الأغاني';
  static final current = ValueNotifier<SongModel?>(null);

  /// تشغيل عشوائي
  static final shuffle = ValueNotifier<bool>(false);

  /// 0 = بدون تكرار (يوقف بنهاية القائمة)، 1 = تكرار القائمة، 2 = تكرار الأغنية
  static final repeat = ValueNotifier<int>(1);

  static final fontScale = ValueNotifier<double>(1.0);
  static final speed = ValueNotifier<double>(1.0);
  static final sleepEnd = ValueNotifier<DateTime?>(null);
  static final sleepAfterSong = ValueNotifier<bool>(false);
  static Timer? _sleepTimer;

  static final List<int> _history = [];
  static final Set<int> _played = {};
  static final _rand = Random();
  static DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _inited = false;

  static Future<void> loadPrefs() async {
    shuffle.value = (await Db.getKv('shuffle')) == '1';
    repeat.value = int.tryParse(await Db.getKv('repeat') ?? '') ?? 1;
    fontScale.value = double.tryParse(await Db.getKv('font_scale') ?? '') ?? 1.0;
  }

  static void init() {
    if (_inited) return;
    _inited = true;
    player.processingStateStream.listen((st) {
      if (st != ProcessingState.completed) return;
      if (sleepAfterSong.value) {
        sleepAfterSong.value = false;
        _stopAtEnd();
        return;
      }
      if (repeat.value == 2) {
        player.seek(Duration.zero);
        player.play();
      } else {
        next(auto: true);
      }
    });
    player.playingStream.listen((p) {
      if (!p) _savePos(player.position);
    });
    player.positionStream.listen((pos) {
      if (!player.playing) return;
      final now = DateTime.now();
      if (now.difference(_lastSave) > const Duration(seconds: 5)) {
        _lastSave = now;
        _savePos(pos);
      }
    });
    shuffle.addListener(() => Db.setKv('shuffle', shuffle.value ? '1' : '0'));
    repeat.addListener(() => Db.setKv('repeat', '${repeat.value}'));
    fontScale.addListener(
        () => Db.setKv('font_scale', fontScale.value.toStringAsFixed(2)));
  }

  static void _savePos(Duration p) {
    if (current.value == null) return;
    Db.setKv('last_pos', '${p.inMilliseconds}');
  }

  static void _saveQueue() {
    final c = current.value;
    if (c == null) return;
    Db.setKv('last_id', '${c.id}');
    Db.setKv('last_queue', queue.map((e) => e.id).join(','));
    Db.setKv('last_qname', queueName);
    Db.setKv('last_pos', '0');
  }

  /// يرجّع آخر أغنية ومكانها (بدون تشغيل تلقائي)
  static Future<void> restore(List<SongModel> all) async {
    if (current.value != null) return;
    final id = int.tryParse(await Db.getKv('last_id') ?? '');
    if (id == null) return;
    final byId = {for (final s in all) s.id: s};
    final s = byId[id];
    if (s == null) return;
    final csv = await Db.getKv('last_queue') ?? '';
    var q = <SongModel>[];
    for (final part in csv.split(',')) {
      final x = int.tryParse(part);
      final song = x == null ? null : byId[x];
      if (song != null) q.add(song);
    }
    if (!q.any((e) => e.id == id)) q = all;
    queue = q;
    queueName = await Db.getKv('last_qname') ?? 'كل الأغاني';
    final pos = int.tryParse(await Db.getKv('last_pos') ?? '') ?? 0;
    try {
      await _open(s, at: Duration(milliseconds: pos), autoplay: false);
    } catch (_) {}
  }

  static int _indexOf(SongModel s) => queue.indexWhere((e) => e.id == s.id);

  /// تشغيل أغنية من قائمة. name = اسم الفنان/الألبوم/المجلد (للعرض)
  static Future<void> play(List<SongModel> q, int i, {String? name}) async {
    queue = q;
    queueName = name ?? 'كل الأغاني';
    _history.clear();
    _played.clear();
    await _start(i);
  }

  static Future<void> _open(SongModel s,
      {Duration? at, required bool autoplay}) async {
    _played.add(s.id);
    current.value = s;
    final uri = s.uri != null ? Uri.parse(s.uri!) : Uri.file(s.data);
    final artist = cleanArtist(s.artist);
    await player.setAudioSource(
      AudioSource.uri(
        uri,
        tag: MediaItem(
          id: '${s.id}',
          title: s.title,
          artist: artist.isEmpty ? null : artist,
          album: s.album,
          duration: s.duration != null ? Duration(milliseconds: s.duration!) : null,
        ),
      ),
      initialPosition: at,
    );
    if (autoplay) player.play();
  }

  static Future<void> _start(int i) async {
    await _open(queue[i], autoplay: true);
    _saveQueue();
  }

  static Future<void> _stopAtEnd() async {
    await player.pause();
    await player.seek(Duration.zero);
  }

  static Future<void> next({bool auto = false}) async {
    final c = current.value;
    if (c == null || queue.isEmpty) return;
    final i = _indexOf(c);
    int n;
    if (shuffle.value && queue.length > 1) {
      var left = [
        for (var k = 0; k < queue.length; k++)
          if (!_played.contains(queue[k].id)) k
      ];
      if (left.isEmpty) {
        if (auto && repeat.value == 0) {
          await _stopAtEnd();
          return;
        }
        _played
          ..clear()
          ..add(c.id);
        left = [
          for (var k = 0; k < queue.length; k++)
            if (k != i) k
        ];
      }
      n = left[_rand.nextInt(left.length)];
      _history.add(i);
    } else {
      n = i + 1;
      if (n >= queue.length) {
        if (auto && repeat.value == 0) {
          await _stopAtEnd();
          return;
        }
        n = 0;
      }
    }
    await _start(n);
  }

  static Future<void> prev() async {
    final c = current.value;
    if (c == null || queue.isEmpty) return;
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
      return;
    }
    if (shuffle.value && _history.isNotEmpty) {
      await _start(_history.removeLast());
      return;
    }
    final i = _indexOf(c);
    await _start((i - 1 + queue.length) % queue.length);
  }

  /// بعد تعديل اسم/فنان أغنية: نحدّث نسختها داخل القائمة الحالية والأغنية الشغالة
  static void refreshSongs(List<SongModel> all) {
    final by = {for (final s in all) s.id: s};
    queue = [for (final s in queue) by[s.id] ?? s];
    final c = current.value;
    if (c == null) return;
    final n = by[c.id];
    if (n != null &&
        (n.title != c.title || cleanArtist(n.artist) != cleanArtist(c.artist))) {
      current.value = n;
    }
  }

  /// يشيل أغنية انحذفت من القائمة، ويوقف التشغيل إذا هي الحالية
  static Future<void> forget(int id) async {
    queue = queue.where((e) => e.id != id).toList();
    if (current.value?.id == id) {
      await player.stop();
      current.value = null;
    }
  }

  static void toggleShuffle() => shuffle.value = !shuffle.value;

  static void cycleRepeat() {
    repeat.value = repeat.value == 1 ? 2 : (repeat.value == 2 ? 0 : 1);
  }

  static Future<void> setSpeed(double v) async {
    speed.value = v;
    await player.setSpeed(v);
  }

  /// مؤقت النوم: null = إلغاء
  static void setSleep(Duration? d) {
    _sleepTimer?.cancel();
    sleepAfterSong.value = false;
    if (d == null) {
      sleepEnd.value = null;
      return;
    }
    sleepEnd.value = DateTime.now().add(d);
    _sleepTimer = Timer(d, () {
      player.pause();
      sleepEnd.value = null;
    });
  }

  static void sleepAtSongEnd() {
    _sleepTimer?.cancel();
    sleepEnd.value = null;
    sleepAfterSong.value = true;
  }
}

const ink = Color(0xFF1B1424);
const surface = Color(0xFF261C33);
const saffron = Color(0xFFF2B84B);
const paper = Color(0xFFF3ECE2);
const muted = Color(0xFF9B8FAE);

/// يربط إشعار التشغيل / شاشة القفل / أزرار السماعة بالمشغّل الرئيسي (Ctrl)
class LpHandler extends BaseAudioHandler with SeekHandler {
  LpHandler() {
    final pl = Ctrl.player;
    pl.playbackEventStream.listen((_) => _broadcast(),
        onError: (Object e, StackTrace st) {});
    pl.playingStream.listen((_) => _broadcast());
    pl.durationStream.listen((d) {
      final m = mediaItem.value;
      if (m != null && d != null && m.duration != d) {
        mediaItem.add(m.copyWith(duration: d));
      }
    });
    Ctrl.current.addListener(_syncItem);
    _syncItem();
  }

  void _syncItem() {
    final s = Ctrl.current.value;
    if (s == null) return;
    final artist = cleanArtist(s.artist);
    mediaItem.add(MediaItem(
      id: '${s.id}',
      title: s.title,
      artist: artist.isEmpty ? null : artist,
      album: s.album,
      duration: s.duration != null ? Duration(milliseconds: s.duration!) : null,
    ));
  }

  void _broadcast() {
    final pl = Ctrl.player;
    final playing = pl.playing;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[pl.processingState]!,
      playing: playing,
      updatePosition: pl.position,
      bufferedPosition: pl.bufferedPosition,
      speed: pl.speed,
    ));
  }

  @override
  Future<void> play() => Ctrl.player.play();

  @override
  Future<void> pause() => Ctrl.player.pause();

  @override
  Future<void> seek(Duration position) => Ctrl.player.seek(position);

  @override
  Future<void> skipToNext() => Ctrl.next();

  @override
  Future<void> skipToPrevious() => Ctrl.prev();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AudioService.init(
    builder: () => LpHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.lyricplayer.audio',
      androidNotificationChannelName: 'تشغيل الموسيقى',
      androidNotificationOngoing: true,
    ),
  );
  await Ctrl.loadPrefs();
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

class Grp {
  final String title;
  final String? sub;
  final List<SongModel> songs;
  Grp(this.title, this.sub, this.songs);
}

String _dirOf(SongModel s) {
  final i = s.data.lastIndexOf('/');
  return i <= 0 ? '' : s.data.substring(0, i);
}

String _lastSeg(String p) {
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

String? _parentSeg(String p) {
  final i = p.lastIndexOf('/');
  if (i <= 0) return null;
  final q = p.substring(0, i).replaceFirst('/storage/emulated/0', '');
  return q.isEmpty ? '/' : q;
}

String _artistOf(SongModel s) {
  final a = cleanArtist(s.artist);
  return a.isEmpty ? 'فنان غير معروف' : a;
}

String _albumOf(SongModel s) {
  final a = s.album;
  return (a == null || a.isEmpty || a == '<unknown>') ? 'ألبوم غير معروف' : a;
}

List<Grp> _groupBy(
  List<SongModel> list,
  String Function(SongModel) key, {
  String Function(String)? title,
  String? Function(String)? sub,
}) {
  final m = <String, List<SongModel>>{};
  for (final s in list) {
    m.putIfAbsent(key(s), () => []).add(s);
  }
  final keys = m.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final k in keys)
      Grp(title != null ? title(k) : k, sub != null ? sub(k) : null, m[k]!),
  ];
}

Future<String?> askName(BuildContext context, String title,
    {String initial = ''}) {
  final t = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: t,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'الاسم'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, t.text.trim()),
            child: const Text('حفظ')),
      ],
    ),
  );
}

Future<void> addToPlaylistFlow(BuildContext context, SongModel s) async {
  final lists = await Db.playlists();
  if (!context.mounted) return;
  final pick = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('إضافة إلى قائمة'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, -1),
          child: const Row(children: [
            Icon(Icons.add, color: saffron),
            SizedBox(width: 8),
            Text('قائمة جديدة'),
          ]),
        ),
        for (final l in lists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, l['id'] as int),
            child: Text('${l['name']}  (${l['n']})'),
          ),
      ],
    ),
  );
  if (pick == null || !context.mounted) return;
  var pid = pick;
  if (pid == -1) {
    final name = await askName(context, 'قائمة جديدة');
    if (name == null || name.isEmpty) return;
    pid = await Db.newPlaylist(name);
  }
  await Db.addToPlaylist(pid, s.id);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تمت الإضافة')));
  }
}

/// حذف نهائي لملف الأغنية من الهاتف
Future<bool> deleteForever(BuildContext context, SongModel s) async {
  const red = Color(0xFFE5737F);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('حذف نهائي من الهاتف؟'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(s.data,
              textDirection: TextDirection.ltr,
              style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 12),
          const Text(
              'راح ينحذف ملف الأغنية من الهاتف نهائياً (ومن مدير الملفات)، مع كلماتها وترجمتها. ما تكدر ترجّعه.'),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: red, foregroundColor: Colors.black),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('حذف نهائياً'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;

  void toast(String t) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
    }
  }

  var st = await Permission.manageExternalStorage.status;
  if (!st.isGranted) st = await Permission.manageExternalStorage.request();
  if (!st.isGranted) {
    toast('لازم تفعّل صلاحية "الوصول لكل الملفات" للتطبيق من الإعدادات حتى يكدر يحذف الملف.');
    return false;
  }
  try {
    final f = File(s.data);
    if (await f.exists()) await f.delete();
    if (await f.exists()) throw Exception('still exists');
  } catch (_) {
    toast('تعذّر حذف الملف');
    return false;
  }
  await Ctrl.forget(s.id);
  await Db.purge(s.id);
  toast('انحذفت الأغنية من الهاتف');
  return true;
}

/// اختيار المجلد الوجهة: مجلدات موجودة بالمكتبة، أو مجلد جديد، أو أي مجلد من الهاتف
Future<String?> pickTargetFolder(BuildContext context, String currentDir) async {
  final dirs = <String>{};
  try {
    final all = await OnAudioQuery().querySongs(uriType: UriType.EXTERNAL);
    for (final e in all) {
      final d = _dirOf(e);
      if (d.isNotEmpty) dirs.add(d);
    }
  } catch (_) {}
  dirs.remove(currentDir);
  final list = dirs.toList()
    ..sort((a, b) => _lastSeg(a).toLowerCase().compareTo(_lastSeg(b).toLowerCase()));
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: surface,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
              title: Text('نقل الأغنية إلى...',
                  style: TextStyle(fontWeight: FontWeight.bold))),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('مجلد جديد...'),
            onTap: () async {
              final n = await askName(ctx, 'اسم المجلد الجديد');
              if (n == null || n.isEmpty || !ctx.mounted) return;
              final i = currentDir.lastIndexOf('/');
              final parent = i > 0 ? currentDir.substring(0, i) : '/storage/emulated/0';
              Navigator.pop(ctx, '$parent/${n.replaceAll('/', '_')}');
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('اختيار مجلد من الهاتف...'),
            onTap: () async {
              final d = await FilePicker.platform.getDirectoryPath();
              if (d == null || !ctx.mounted) return;
              Navigator.pop(ctx, d);
            },
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (c, i) => ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(_lastSeg(list[i]),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(_parentSeg(list[i]) ?? '',
                    textDirection: TextDirection.ltr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 12)),
                onTap: () => Navigator.pop(ctx, list[i]),
              ),
            ),
          ),
        ]),
      ),
    ),
  );
}

/// ينقل ملف أغنية (أو عدة أغاني) لمجلد ثاني، ويحدّث مكتبة الهاتف، وينقل الكلمات للأرقام الجديدة
Future<bool> moveSongs(BuildContext context, List<SongModel> list) async {
  if (list.isEmpty) return false;
  void toast(String t) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
    }
  }

  var st = await Permission.manageExternalStorage.status;
  if (!st.isGranted) st = await Permission.manageExternalStorage.request();
  if (!st.isGranted) {
    toast('لازم تفعّل صلاحية "الوصول لكل الملفات" للتطبيق من الإعدادات حتى يكدر ينقل الملفات.');
    return false;
  }
  if (!context.mounted) return false;

  final dirs = list.map(_dirOf).toSet();
  final destDir = await pickTargetFolder(context, dirs.length == 1 ? dirs.first : '');
  if (destDir == null || !context.mounted) return false;
  final todo = list.where((s) => _dirOf(s) != destDir).toList();
  if (todo.isEmpty) {
    toast('الأغاني موجودة أصلاً بهذا المجلد');
    return false;
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(todo.length == 1 ? 'نقل الأغنية؟' : 'نقل ${todo.length} أغنية؟'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(todo.length == 1 ? todo.first.title : '${todo.length} أغنية',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('إلى:', style: TextStyle(color: muted)),
          Text(destDir,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 13)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: const Text('نقل')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;

  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
        canPop: false, child: Center(child: CircularProgressIndicator())),
  );

  final pairs = <MapEntry<SongModel, String>>[];
  var skipped = 0, failed = 0;
  try {
    await Directory(destDir).create(recursive: true);
    for (final s in todo) {
      final from = s.data;
      final dest = '$destDir/${p.basename(from)}';
      try {
        if (await File(dest).exists()) {
          skipped++;
          continue;
        }
        try {
          await File(from).rename(dest);
        } on FileSystemException {
          // مجلدين على وحدتين تخزين مختلفتين: ننسخ ثم نحذف الأصل
          await File(from).copy(dest);
          if (await File(dest).length() != await File(from).length()) {
            await File(dest).delete();
            throw Exception('copy mismatch');
          }
          await File(from).delete();
        }
        pairs.add(MapEntry(s, dest));
      } catch (_) {
        failed++;
      }
    }
    for (final e in pairs) {
      await Ctrl.forget(e.key.id);
    }
    if (pairs.isNotEmpty) {
      try {
        await _nativeCh.invokeMethod('scan', {
          'paths': [
            for (final e in pairs) ...[e.key.data, e.value]
          ]
        }).timeout(Duration(seconds: 8 + pairs.length));
      } catch (_) {}
      var byData = <String, int>{};
      try {
        final all = await OnAudioQuery().querySongs(uriType: UriType.EXTERNAL);
        byData = {for (final x in all) x.data: x.id};
      } catch (_) {}
      for (final e in pairs) {
        final nid = byData[e.value];
        if (nid != null) {
          await Db.moveId(e.key.id, nid);
        } else {
          await Db.hide(e.key.id);
        }
      }
      libraryVersion.value++;
    }
  } catch (_) {
    failed++;
  } finally {
    nav.pop();
  }

  var msg = pairs.isEmpty
      ? 'ما انتقلت أي أغنية'
      : (pairs.length == 1
          ? 'انتقلت الأغنية إلى ${_lastSeg(destDir)}'
          : 'انتقلت ${pairs.length} أغنية إلى ${_lastSeg(destDir)}');
  if (skipped > 0) msg += ' (تخطّيت $skipped لأن اسمها موجود بالمجلد)';
  if (failed > 0) msg += ' (فشل نقل $failed)';
  toast(msg);
  return pairs.isNotEmpty;
}

Future<bool> moveSong(BuildContext context, SongModel s) =>
    moveSongs(context, [s]);

/// تعديل اسم الأغنية والفنان داخل التطبيق فقط (ما يغيّر الملف)
Future<bool> editSongMeta(BuildContext context, SongModel s) async {
  final tt = TextEditingController(text: s.title);
  final ta = TextEditingController(text: cleanArtist(s.artist));
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تعديل الاسم والفنان'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            controller: tt,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'اسم الأغنية')),
        const SizedBox(height: 8),
        TextField(
            controller: ta,
            decoration: const InputDecoration(labelText: 'الفنان')),
        const SizedBox(height: 10),
        const Text('التعديل داخل التطبيق فقط، ما يغيّر الملف على الهاتف.',
            style: TextStyle(color: muted, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'reset'),
            child: const Text('رجوع للأصلي')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('حفظ')),
      ],
    ),
  );
  if (r == null) return false;
  if (r == 'reset') {
    await Db.clearMeta(s.id);
  } else {
    final t = tt.text.trim();
    if (t.isEmpty) return false;
    await Db.setMeta(s.id, t, ta.text.trim());
  }
  libraryVersion.value++;
  return true;
}

/// قائمة خيارات الأغنية (ضغطة مطوّلة)
Future<void> showSongMenu(BuildContext context, SongModel s,
    {int? playlistId, VoidCallback? onChanged, VoidCallback? onSelect}) async {
  final favs = await Db.favs();
  if (!context.mounted) return;
  final isFav = favs.contains(s.id);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: surface,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          title: Text(s.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        ListTile(
          leading: Icon(isFav ? Icons.favorite_border : Icons.favorite),
          title: Text(isFav ? 'إزالة من المفضلة' : 'إضافة للمفضلة'),
          onTap: () async {
            Navigator.pop(ctx);
            await Db.setFav(s.id, !isFav);
            onChanged?.call();
          },
        ),
        ListTile(
          leading: const Icon(Icons.playlist_add),
          title: const Text('إضافة إلى قائمة تشغيل'),
          onTap: () async {
            Navigator.pop(ctx);
            await addToPlaylistFlow(context, s);
            onChanged?.call();
          },
        ),
        if (playlistId != null && playlistId > 0)
          ListTile(
            leading: const Icon(Icons.remove_circle_outline),
            title: const Text('إزالة من هذي القائمة'),
            onTap: () async {
              Navigator.pop(ctx);
              await Db.removeFromPlaylist(playlistId!, s.id);
              onChanged?.call();
            },
          ),
        if (onSelect != null)
          ListTile(
            leading: const Icon(Icons.checklist),
            title: const Text('تحديد عدة أغاني'),
            onTap: () {
              Navigator.pop(ctx);
              onSelect?.call();
            },
          ),
        ListTile(
          leading: const Icon(Icons.edit_note),
          title: const Text('تعديل الاسم والفنان'),
          onTap: () async {
            Navigator.pop(ctx);
            await editSongMeta(context, s);
            onChanged?.call();
          },
        ),
        ListTile(
          leading: const Icon(Icons.drive_file_move_outline),
          title: const Text('نقل إلى مجلد آخر'),
          onTap: () async {
            Navigator.pop(ctx);
            final done = await moveSong(context, s);
            if (done) onChanged?.call();
          },
        ),
        ListTile(
          leading: const Icon(Icons.visibility_off_outlined),
          title: const Text('إخفاء من التطبيق'),
          subtitle: const Text('الملف يبقى بالهاتف'),
          onTap: () async {
            Navigator.pop(ctx);
            await Db.hide(s.id);
            onChanged?.call();
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever, color: Color(0xFFE5737F)),
          title: const Text('حذف نهائي من الهاتف',
              style: TextStyle(color: Color(0xFFE5737F))),
          onTap: () async {
            Navigator.pop(ctx);
            final done = await deleteForever(context, s);
            if (done) onChanged?.call();
          },
        ),
      ])),
    ),
  );
}

class FavButton extends StatefulWidget {
  final int id;
  const FavButton({super.key, required this.id});
  @override
  State<FavButton> createState() => _FavButtonState();
}

class _FavButtonState extends State<FavButton> {
  bool fav = false;

  @override
  void initState() {
    super.initState();
    Db.favs().then((set) {
      if (mounted) setState(() => fav = set.contains(widget.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'المفضلة',
      icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
          color: fav ? const Color(0xFFE5737F) : null),
      onPressed: () async {
        await Db.setFav(widget.id, !fav);
        if (mounted) setState(() => fav = !fav);
      },
    );
  }
}

void showPlaySettings(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: surface,
    isScrollControlled: true,
    builder: (ctx) => const SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: _PlaySettings(),
      ),
    ),
  );
}

class _PlaySettings extends StatelessWidget {
  const _PlaySettings();

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: const TextStyle(color: muted)),
      );

  String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title('حجم خط الكلمات'),
        ValueListenableBuilder<double>(
          valueListenable: Ctrl.fontScale,
          builder: (c, v, _) => Row(children: [
            const Text('أ', style: TextStyle(fontSize: 14)),
            Expanded(
              child: Slider(
                value: v,
                min: 0.8,
                max: 1.6,
                divisions: 8,
                label: v.toStringAsFixed(1),
                onChanged: (x) => Ctrl.fontScale.value = x,
              ),
            ),
            const Text('أ', style: TextStyle(fontSize: 24)),
          ]),
        ),
        _title('سرعة التشغيل'),
        ValueListenableBuilder<double>(
          valueListenable: Ctrl.speed,
          builder: (c, v, _) => Wrap(spacing: 8, children: [
            for (final x in const [0.75, 1.0, 1.25, 1.5])
              ChoiceChip(
                label: Text('${x}x'),
                selected: v == x,
                onSelected: (_) => Ctrl.setSpeed(x),
              ),
          ]),
        ),
        _title('مؤقت النوم'),
        ValueListenableBuilder<DateTime?>(
          valueListenable: Ctrl.sleepEnd,
          builder: (c, end, _) => ValueListenableBuilder<bool>(
            valueListenable: Ctrl.sleepAfterSong,
            builder: (c, after, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 8, children: [
                  ChoiceChip(
                    label: const Text('إيقاف'),
                    selected: end == null && !after,
                    onSelected: (_) => Ctrl.setSleep(null),
                  ),
                  for (final m in const [15, 30, 45, 60])
                    ChoiceChip(
                      label: Text('$m دقيقة'),
                      selected: false,
                      onSelected: (_) => Ctrl.setSleep(Duration(minutes: m)),
                    ),
                  ChoiceChip(
                    label: const Text('بعد هذي الأغنية'),
                    selected: after,
                    onSelected: (_) => Ctrl.sleepAtSongEnd(),
                  ),
                ]),
                if (end != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('يوقف التشغيل الساعة ${_hm(end)}',
                        style: const TextStyle(color: saffron)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// غلاف الأغنية (أو أيقونة إذا ماكو غلاف)
class Cover extends StatelessWidget {
  final int id;
  final double size;
  final double radius;
  const Cover(this.id, {super.key, this.size = 48, this.radius = 8});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return QueryArtworkWidget(
      id: id,
      type: ArtworkType.AUDIO,
      artworkWidth: size,
      artworkHeight: size,
      artworkBorder: r,
      artworkFit: BoxFit.cover,
      keepOldArtwork: true,
      nullArtworkWidget: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: surface, borderRadius: r),
        child: Icon(Icons.music_note, color: muted, size: size * 0.5),
      ),
    );
  }
}

/// خلفية شاشة التشغيل: الغلاف مغبّش ومعتّم خلف الكلمات
class Backdrop extends StatelessWidget {
  final int id;
  const Backdrop({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Opacity(
          opacity: 0.5,
          child: QueryArtworkWidget(
            id: id,
            type: ArtworkType.AUDIO,
            size: 400,
            quality: 80,
            artworkWidth: double.infinity,
            artworkHeight: double.infinity,
            artworkBorder: BorderRadius.zero,
            artworkFit: BoxFit.cover,
            keepOldArtwork: true,
            nullArtworkWidget: const SizedBox.shrink(),
          ),
        ),
      ),
      Container(color: ink.withOpacity(0.5)),
    ]);
  }
}

class SongTile extends StatelessWidget {
  final SongModel song;
  final bool hasLyrics;
  final bool isFav;
  final VoidCallback onTap;
  final VoidCallback? onLong;

  /// null = وضع عادي، true/false = وضع التحديد
  final bool? selected;
  const SongTile({
    super.key,
    required this.song,
    required this.hasLyrics,
    required this.onTap,
    this.isFav = false,
    this.onLong,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final artist = cleanArtist(song.artist);
    final sel = selected;
    return ListTile(
      tileColor: sel == true ? saffron.withOpacity(0.12) : null,
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: artist.isEmpty
          ? null
          : Text(artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted)),
      leading: Cover(song.id),
      trailing: sel != null
          ? Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked,
              color: sel ? saffron : muted)
          : (hasLyrics || isFav)
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              if (isFav)
                const Icon(Icons.favorite, color: Color(0xFFE5737F), size: 18),
              if (isFav && hasLyrics) const SizedBox(width: 6),
              if (hasLyrics) const Icon(Icons.lyrics, color: saffron, size: 20),
            ])
          : null,
      onTap: onTap,
      onLongPress: onLong,
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SongModel?>(
      valueListenable: Ctrl.current,
      builder: (c, s, _) {
        if (s == null) return const SizedBox.shrink();
        return Material(
          color: surface,
          child: SafeArea(
            child: ListTile(
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const PlayerPage())),
              leading: Cover(s.id, size: 40, radius: 6),
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
    );
  }
}

/// صفحة داخل فنان / ألبوم / مجلد / قائمة تشغيل
class GroupPage extends StatefulWidget {
  final Grp group;

  /// null = عادي، -1 = المفضلة، غير ذلك = رقم قائمة تشغيل
  final int? playlistId;
  final List<SongModel> allSongs;
  const GroupPage(
      {super.key, required this.group, this.playlistId, this.allSongs = const []});
  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  Set<int> ids = {};
  Set<int> favs = {};
  late List<SongModel> songs = widget.group.songs;
  bool selecting = false;
  Set<int> sel = {};

  @override
  void initState() {
    super.initState();
    libraryLoaded.addListener(_onLib);
    _refresh();
  }

  @override
  void dispose() {
    libraryLoaded.removeListener(_onLib);
    super.dispose();
  }

  void _onLib() => _refresh();

  void _toggleSel(int id) {
    setState(() {
      if (!sel.remove(id)) sel.add(id);
      if (sel.isEmpty) selecting = false;
    });
  }

  Future<void> _moveSelected() async {
    final list = songs.where((s) => sel.contains(s.id)).toList();
    final ok = await moveSongs(context, list);
    if (ok && mounted) {
      setState(() {
        selecting = false;
        sel = {};
      });
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final r = await Db.ids();
    final f = await Db.favs();
    final hid = await Db.hiddenIds();
    var list = widget.group.songs;
    final pid = widget.playlistId;
    if (pid != null) {
      final order = pid == -1 ? f.toList() : await Db.playlistSongIds(pid);
      final byId = {for (final s in widget.allSongs) s.id: s};
      list = [
        for (final i in order)
          if (byId[i] != null) byId[i]!
      ];
    }
    list = list.where((s) => !hid.contains(s.id)).toList();
    list = [for (final x in list) libraryById[x.id] ?? x];
    if (!mounted) return;
    setState(() {
      ids = r;
      favs = f;
      songs = list;
    });
  }

  Future<void> _play(int i) async {
    if (songs.isEmpty) return;
    Ctrl.play(songs, i, name: widget.group.title);
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const PlayerPage()));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) {
          setState(() {
            selecting = false;
            sel = {};
          });
        }
      },
      child: Scaffold(
      appBar: AppBar(
        leading: selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'إلغاء التحديد',
                onPressed: () => setState(() {
                      selecting = false;
                      sel = {};
                    }))
            : null,
        title: Text(selecting ? '${sel.length} محددة' : g.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: selecting
            ? [
                IconButton(
                    tooltip: 'تحديد الكل',
                    icon: const Icon(Icons.select_all),
                    onPressed: () =>
                        setState(() => sel = {for (final s in songs) s.id})),
                IconButton(
                    tooltip: 'نقل إلى مجلد',
                    icon: const Icon(Icons.drive_file_move_outline),
                    onPressed: sel.isEmpty ? null : _moveSelected),
              ]
            : [
                IconButton(
                    tooltip: 'تشغيل الكل',
                    onPressed: () => _play(0),
                    icon: const Icon(Icons.play_circle_fill, color: saffron)),
              ],
      ),
      body: songs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'ماكو أغاني هنا.\nاضغط مطولاً على أي أغنية وأضفها.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: songs.length,
              itemBuilder: (c, i) => SongTile(
                song: songs[i],
                hasLyrics: ids.contains(songs[i].id),
                isFav: favs.contains(songs[i].id),
                selected: selecting ? sel.contains(songs[i].id) : null,
                onTap: () {
                  if (selecting) {
                    _toggleSel(songs[i].id);
                  } else {
                    _play(i);
                  }
                },
                onLong: () {
                  if (selecting) {
                    _toggleSel(songs[i].id);
                  } else {
                    showSongMenu(context, songs[i],
                        playlistId: widget.playlistId,
                        onChanged: _refresh,
                        onSelect: () => setState(() {
                              selecting = true;
                              sel = {songs[i].id};
                            }));
                  }
                },
              ),
            ),
      bottomNavigationBar: const MiniPlayer(),
    ));
  }
}

// ====================== التحديث من داخل التطبيق ======================

/// عنوان المستودع (owner/repo) يدخل وقت البناء من الـ workflow
const _ghRepo = String.fromEnvironment('GH_REPO');

class UpdateInfo {
  final String tag;
  final int build;
  final String url;
  final int size;
  final String notes;
  const UpdateInfo(this.tag, this.build, this.url, this.size, this.notes);
}

enum UpState { idle, checking, upToDate, available, downloading, paused, ready, error }

/// يفحص آخر Release بالمستودع، وينزّل الـ APK مع إيقاف مؤقت واستكمال، ويثبّته
class UpdateService {
  static final rev = ValueNotifier<int>(0);
  static UpState state = UpState.idle;
  static UpdateInfo? info;
  static int received = 0;
  static double speed = 0;
  static String error = '';
  static String installMsg = '';
  static int current = 0;

  static bool _pauseReq = false, _cancelReq = false;
  static http.Client? _client;

  static void _set(UpState s) {
    state = s;
    rev.value++;
  }

  static Future<void> loadCurrent() async {
    try {
      final v = await _nativeCh.invokeMethod('version');
      if (v is Map) current = (v['code'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  static Future<String> _dir() async {
    final base = await _nativeCh.invokeMethod<String>('cacheDir');
    final d = Directory('${base ?? Directory.systemTemp.path}/updates');
    await d.create(recursive: true);
    return d.path;
  }

  static Future<void> _cleanup({String? keep}) async {
    try {
      final d = Directory(await _dir());
      await for (final f in d.list()) {
        if (keep != null && p.basename(f.path).startsWith(keep)) continue;
        await f.delete(recursive: true);
      }
    } catch (_) {}
  }

  static Future<UpdateInfo> _fetch() async {
    if (_ghRepo.isEmpty) {
      throw Exception('هذي النسخة ما فيها عنوان المستودع، ابنيها من GitHub Actions');
    }
    final r = await http.get(
      Uri.parse('https://api.github.com/repos/$_ghRepo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode == 404) {
      throw Exception('ما لقيت إصدارات (تأكد أن المستودع عام)');
    }
    if (r.statusCode != 200) {
      throw Exception('تعذّر الاتصال بالسيرفر (${r.statusCode})');
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final tag = (j['tag_name'] ?? '').toString();
    final build = int.tryParse(tag.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    Map? apk;
    for (final a in (j['assets'] as List? ?? const [])) {
      final m = a as Map;
      if ((m['name'] ?? '').toString().toLowerCase().endsWith('.apk')) {
        apk = m;
        break;
      }
    }
    if (apk == null) throw Exception('ما لقيت ملف APK بهذا الإصدار');
    return UpdateInfo(
      tag,
      build,
      apk['browser_download_url'].toString(),
      (apk['size'] as num?)?.toInt() ?? 0,
      (j['body'] ?? '').toString().trim(),
    );
  }

  /// فحص هادئ عند فتح التطبيق: يرجّع الإصدار الجديد أو null
  static Future<UpdateInfo?> quietCheck() async {
    try {
      final last = int.tryParse(await Db.getKv('upd_last') ?? '') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < 3600000) return null;
      await Db.setKv('upd_last', '$now');
      await loadCurrent();
      final i = await _fetch();
      return i.build > current ? i : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> checkNow() async {
    if (state == UpState.checking || state == UpState.downloading) return;
    _set(UpState.checking);
    try {
      await loadCurrent();
      final i = await _fetch();
      info = i;
      if (i.build <= current) {
        await _cleanup();
        _set(UpState.upToDate);
        return;
      }
      await _cleanup(keep: i.tag);
      final dir = await _dir();
      final done = File('$dir/${i.tag}.apk');
      final part = File('$dir/${i.tag}.apk.part');
      if (await done.exists() && (i.size == 0 || await done.length() == i.size)) {
        received = i.size;
        _set(UpState.ready);
      } else if (await part.exists() &&
          await part.length() > 0 &&
          await part.length() < i.size) {
        received = await part.length();
        _set(UpState.paused);
      } else {
        received = 0;
        _set(UpState.available);
      }
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      _set(UpState.error);
    }
  }

  static void pause() {
    if (state != UpState.downloading) return;
    _pauseReq = true;
    _client?.close();
  }

  static Future<void> cancel() async {
    if (state == UpState.downloading) {
      _cancelReq = true;
      _client?.close();
      return;
    }
    final i = info;
    if (i != null) {
      try {
        final part = File('${await _dir()}/${i.tag}.apk.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
    received = 0;
    _set(UpState.available);
  }

  /// يبدأ التنزيل، أو يكمّله من آخر نقطة إذا كان متوقف
  static Future<void> start() async {
    final i = info;
    if (i == null || state == UpState.downloading) return;
    _pauseReq = false;
    _cancelReq = false;
    installMsg = '';
    final dir = await _dir();
    final part = File('$dir/${i.tag}.apk.part');
    final done = File('$dir/${i.tag}.apk');
    IOSink? sink;
    try {
      var have = await part.exists() ? await part.length() : 0;
      if (i.size > 0 && have >= i.size) {
        await part.delete();
        have = 0;
      }
      received = have;
      speed = 0;
      _set(UpState.downloading);
      final client = http.Client();
      _client = client;
      final req = http.Request('GET', Uri.parse(i.url));
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final resp = await client.send(req);
      if (resp.statusCode == 200 && have > 0) {
        // السيرفر ما يدعم الاستكمال: نبدأ من الصفر
        have = 0;
        received = 0;
      } else if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw Exception('السيرفر رفض التنزيل (${resp.statusCode})');
      }
      sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var lastT = DateTime.now();
      var lastB = received;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        final dt = now.difference(lastT).inMilliseconds;
        if (dt >= 300) {
          speed = (received - lastB) * 1000 / dt;
          lastT = now;
          lastB = received;
          rev.value++;
        }
        if (_pauseReq || _cancelReq) break;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (_cancelReq) {
        if (await part.exists()) await part.delete();
        received = 0;
        _set(UpState.available);
        return;
      }
      if (_pauseReq) {
        _set(UpState.paused);
        return;
      }
      final len = await part.length();
      if (i.size > 0 && len != i.size) {
        throw Exception('التنزيل ناقص، اضغط استمرار');
      }
      if (await done.exists()) await done.delete();
      await part.rename(done.path);
      received = len;
      _set(UpState.ready);
    } catch (e) {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      if (_cancelReq) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
        received = 0;
        _set(UpState.available);
      } else if (_pauseReq) {
        try {
          received = await part.length();
        } catch (_) {}
        _set(UpState.paused);
      } else {
        try {
          received = await part.length();
        } catch (_) {}
        error = e.toString().replaceFirst('Exception: ', '');
        _set(UpState.error);
      }
    } finally {
      _client?.close();
      _client = null;
    }
  }

  static Future<void> install() async {
    final i = info;
    if (i == null) return;
    try {
      final path = '${await _dir()}/${i.tag}.apk';
      final r = await _nativeCh.invokeMethod<String>('install', {'path': path});
      if (r == 'need_permission') {
        installMsg =
            'فعّل "السماح بالتثبيت من هذا المصدر" للتطبيق، وبعدها ارجع واضغط تثبيت.';
      } else if (r == 'started') {
        installMsg = 'بانتظار تأكيدك بنافذة النظام...';
      } else if (r == 'missing') {
        installMsg = 'ملف التحديث ما انلقى، نزّله من جديد.';
      } else {
        installMsg = r ?? '';
      }
    } catch (e) {
      installMsg = e.toString();
    }
    rev.value++;
  }

  static void onInstallStatus(Map m) {
    final status = (m['status'] as num?)?.toInt() ?? -1;
    if (status == 0) return;
    final msg = (m['message'] ?? '').toString();
    installMsg = status == 3 ? 'تم إلغاء التثبيت.' : 'فشل التثبيت: $msg';
    rev.value++;
  }
}

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});
  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  @override
  void initState() {
    super.initState();
    UpdateService.rev.addListener(_r);
    final s = UpdateService.state;
    if (s == UpState.idle || s == UpState.error || s == UpState.upToDate) {
      UpdateService.checkNow();
    } else {
      UpdateService.loadCurrent().then((_) => _r());
    }
  }

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    UpdateService.rev.removeListener(_r);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = UpdateService.state;
    final i = UpdateService.info;
    final size = i?.size ?? 0;
    final prog = size > 0 ? (UpdateService.received / size).clamp(0.0, 1.0) : 0.0;
    String mb(num b) => (b / 1048576).toStringAsFixed(1);
    const pad = EdgeInsets.all(16);

    final kids = <Widget>[
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('الإصدار الحالي'),
        subtitle: Text(UpdateService.current > 0 ? 'v${UpdateService.current}' : '—'),
      ),
      const Divider(),
    ];

    switch (st) {
      case UpState.idle:
      case UpState.checking:
        kids.add(const Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('جاري البحث عن تحديث...'),
            ]),
          ),
        ));
        break;
      case UpState.upToDate:
        kids.addAll([
          const SizedBox(height: 24),
          const Icon(Icons.check_circle, color: saffron, size: 56),
          const SizedBox(height: 12),
          const Center(child: Text('عندك آخر إصدار')),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton(
                onPressed: UpdateService.checkNow, child: const Text('فحص مرة ثانية')),
          ),
        ]);
        break;
      case UpState.available:
        kids.addAll([
          ListTile(
            leading: const Icon(Icons.system_update, color: saffron),
            title: Text('يتوفر إصدار جديد: v${i?.build ?? ''}'),
            subtitle: Text('الحجم ${mb(size)} ميغابايت'),
          ),
          if ((i?.notes ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(i!.notes, style: const TextStyle(color: muted)),
            ),
          Padding(
            padding: pad,
            child: FilledButton.icon(
              onPressed: UpdateService.start,
              icon: const Icon(Icons.download),
              label: const Text('تنزيل التحديث'),
            ),
          ),
        ]);
        break;
      case UpState.downloading:
      case UpState.paused:
        {
          final paused = st == UpState.paused;
          final pct = (prog * 100).toStringAsFixed(0);
          final speedTxt = (!paused && UpdateService.speed > 0)
              ? '  •  ${mb(UpdateService.speed)} MB/s'
              : '';
          kids.addAll([
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(paused ? 'متوقف مؤقتاً' : 'جاري التنزيل...',
                  style: TextStyle(
                      color: paused ? muted : saffron, fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LinearProgressIndicator(
                value: size > 0 ? prog : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                  '$pct%  •  ${mb(UpdateService.received)} / ${mb(size)} MB$speedTxt',
                  textDirection: TextDirection.ltr),
            ),
            Padding(
              padding: pad,
              child: Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: paused ? UpdateService.start : UpdateService.pause,
                    icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                    label: Text(paused ? 'استمرار' : 'إيقاف مؤقت'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: UpdateService.cancel,
                  icon: const Icon(Icons.close),
                  label: const Text('إلغاء'),
                ),
              ]),
            ),
          ]);
        }
        break;
      case UpState.ready:
        kids.addAll([
          const ListTile(
            leading: Icon(Icons.check_circle, color: saffron),
            title: Text('اكتمل التنزيل'),
          ),
          Padding(
            padding: pad,
            child: FilledButton.icon(
              onPressed: UpdateService.install,
              icon: const Icon(Icons.system_update_alt),
              label: const Text('تثبيت التحديث'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
                'النظام راح يطلب منك تأكيد التثبيت، وبعده يتسكّر التطبيق ويتحدّث.',
                style: TextStyle(color: muted, fontSize: 12)),
          ),
          if (UpdateService.installMsg.isNotEmpty)
            Padding(padding: pad, child: Text(UpdateService.installMsg)),
        ]);
        break;
      case UpState.error:
        {
          final resumable = UpdateService.info != null && UpdateService.received > 0;
          kids.addAll([
            Padding(
              padding: pad,
              child: Text(UpdateService.error,
                  style: const TextStyle(color: Color(0xFFE5737F))),
            ),
            Padding(
              padding: pad,
              child: FilledButton(
                onPressed: resumable ? UpdateService.start : UpdateService.checkNow,
                child: Text(resumable ? 'استمرار' : 'إعادة المحاولة'),
              ),
            ),
          ]);
        }
        break;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('تحديث التطبيق')),
      body: ListView(children: kids),
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
  List<SongModel> rawSongs = [];
  List<SongModel> songs = [];
  Set<int> withLyrics = {};
  Set<int> favs = {};
  List<Map<String, Object?>> lists = [];
  bool loading = true, denied = false;
  String filter = '';
  String lyricsFilter = 'all'; // all | none | has
  String sort = 'title'; // title | artist | recent

  // فتح ملف صوتي من برّا التطبيق (فتح باستخدام / مدير الملفات)
  static const _openCh = MethodChannel('lyricplayer/open');
  Map? _pendingOpen;
  bool _ready = false;

  // وضع تحديد عدة أغاني
  bool selecting = false;
  Set<int> sel = {};

  void _toggleSel(int id) {
    setState(() {
      if (!sel.remove(id)) sel.add(id);
      if (sel.isEmpty) selecting = false;
    });
  }

  Future<void> _moveSelected() async {
    final list = songs.where((s) => sel.contains(s.id)).toList();
    final ok = await moveSongs(context, list);
    if (ok && mounted) {
      setState(() {
        selecting = false;
        sel = {};
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _openCh.setMethodCallHandler(_onOpenCall);
    libraryVersion.addListener(_onLibrary);
    _load().then((_) async {
      await _checkOpenIntent();
      _quietUpdateCheck();
    });
  }

  @override
  void dispose() {
    libraryVersion.removeListener(_onLibrary);
    super.dispose();
  }

  void _onLibrary() => _reloadLibrary();

  /// يعيد قراءة الأغاني من مكتبة الهاتف (بدون شاشة تحميل)
  Future<void> _reloadLibrary() async {
    try {
      final all = await _q.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      rawSongs = await applyMeta(
          all.where((s) => (s.duration ?? 0) > 30000).toList());
    } catch (_) {}
    libraryById = {for (final x in rawSongs) x.id: x};
    Ctrl.refreshSongs(rawSongs);
    await _refreshMeta();
    libraryLoaded.value++;
  }

  Future<void> _onOpenCall(MethodCall call) async {
    if (call.method == 'opened' && call.arguments is Map) {
      _pendingOpen = Map.from(call.arguments as Map);
      await _handleOpen();
    } else if (call.method == 'installStatus' && call.arguments is Map) {
      UpdateService.onInstallStatus(Map.from(call.arguments as Map));
    }
  }

  /// فحص هادئ عن تحديث (مرة بالساعة): يظهر إشعار صغير إذا في إصدار جديد
  Future<void> _quietUpdateCheck() async {
    final i = await UpdateService.quietCheck();
    if (i == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('يتوفر تحديث جديد (v${i.build})'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: 'تحديث',
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const UpdatePage())),
      ),
    ));
  }

  Future<void> _checkOpenIntent() async {
    try {
      final r = await _openCh.invokeMethod('initial');
      if (r is Map) _pendingOpen = Map.from(r);
    } catch (_) {}
    await _handleOpen();
  }

  /// يدوّر على الأغنية بالمكتبة (حتى تشتغل الكلمات)، وإذا ما لقاها يسوي أغنية مؤقتة
  SongModel _songForOpen(Map info) {
    final uri = (info['uri'] ?? '').toString();
    final name = info['name']?.toString();
    final size = info['size'] is int ? info['size'] as int : null;

    final mid = RegExp(r'/audio/media/(\d+)').firstMatch(uri);
    if (mid != null) {
      final id = int.parse(mid.group(1)!);
      for (final s in rawSongs) {
        if (s.id == id) return s;
      }
    }
    String? path;
    if (uri.startsWith('file://')) {
      path = Uri.decodeComponent(uri.substring(7));
      for (final s in rawSongs) {
        if (s.data == path) return s;
      }
    }
    if (name != null) {
      for (final s in rawSongs) {
        if (s.displayName == name && (size == null || s.size == size)) {
          return s;
        }
      }
    }
    final base = name == null ? 'ملف صوتي' : p.basenameWithoutExtension(name);
    return SongModel({
      '_id': -(uri.hashCode.abs() + 1),
      '_data': path ?? uri,
      '_uri': uri,
      '_display_name': name ?? base,
      '_display_name_wo_ext': base,
      'title': base,
      '_size': size ?? 0,
      'duration': null,
      'artist': '<unknown>',
      'album': '<unknown>',
      'album_id': 0,
      'artist_id': 0,
      'file_extension': '',
    });
  }

  Future<void> _handleOpen() async {
    final info = _pendingOpen;
    if (info == null || !_ready || !mounted) return;
    _pendingOpen = null;
    final song = _songForOpen(info);
    final i = songs.indexWhere((e) => e.id == song.id);
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (i >= 0) {
      await _playFrom(songs, i);
    } else {
      await _playFrom([song], 0);
    }
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
    await Permission.notification.request();
    final all = await _q.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );
    rawSongs = await applyMeta(
        all.where((s) => (s.duration ?? 0) > 30000).toList());
    libraryById = {for (final x in rawSongs) x.id: x};
    final hid = await Db.hiddenIds();
    songs = rawSongs.where((s) => !hid.contains(s.id)).toList();
    sort = await Db.getKv('sort') ?? 'title';
    _applySort();
    withLyrics = await Db.ids();
    favs = await Db.favs();
    lists = await Db.playlists();
    await Ctrl.restore(songs);
    if (mounted) setState(() => loading = false);
    _ready = true;
    _handleOpen();
  }

  void _applySort() {
    int byTitle(SongModel a, SongModel b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase());
    if (sort == 'recent') {
      songs.sort((a, b) {
        final c = b.id.compareTo(a.id); // رقم أكبر = أضيفت أحدث
        return c != 0 ? c : byTitle(a, b);
      });
    } else if (sort == 'artist') {
      songs.sort((a, b) {
        final c = cleanArtist(a.artist)
            .toLowerCase()
            .compareTo(cleanArtist(b.artist).toLowerCase());
        return c != 0 ? c : byTitle(a, b);
      });
    } else {
      songs.sort(byTitle);
    }
  }

  Future<void> _pickSort() async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('ترتيب الأغاني'),
        children: [
          for (final o in const [
            ['title', 'بالاسم'],
            ['artist', 'بالفنان'],
            ['recent', 'الأحدث إضافة'],
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o[0]),
              child: Row(children: [
                Icon(
                    sort == o[0]
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: saffron,
                    size: 20),
                const SizedBox(width: 10),
                Text(o[1]),
              ]),
            ),
        ],
      ),
    );
    if (v == null) return;
    setState(() {
      sort = v;
      _applySort();
    });
    Db.setKv('sort', v);
  }

  Future<void> _refreshMeta() async {
    final ids = await Db.ids();
    final f = await Db.favs();
    final l = await Db.playlists();
    final hid = await Db.hiddenIds();
    if (mounted) {
      setState(() {
        withLyrics = ids;
        favs = f;
        lists = l;
        songs = rawSongs.where((s) => !hid.contains(s.id)).toList();
        _applySort();
      });
    }
  }

  /// قائمة الأغاني المخفية مع زر إرجاع
  Future<void> _showHidden() async {
    final hid = await Db.hiddenIds();
    final list = rawSongs.where((s) => hid.contains(s.id)).toList();
    if (list.isEmpty) {
      _toast('ماكو أغاني مخفية');
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, st) => SafeArea(
          child: ConstrainedBox(
            constraints:
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: ListView(shrinkWrap: true, children: [
              const ListTile(
                title: Text('الأغاني المخفية',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final s in list)
                ListTile(
                  title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: TextButton(
                    onPressed: () async {
                      await Db.unhide(s.id);
                      st(() => list.remove(s));
                    },
                    child: const Text('إرجاع'),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
    await _refreshMeta();
  }

  Future<void> _playFrom(List<SongModel> list, int i, {String? name}) async {
    Ctrl.play(list, i, name: name);
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const PlayerPage()));
    _refreshMeta();
  }

  void _toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  /// سحب كلمات كل الأغاني اللي ما عندها كلمات
  Future<void> _bulkFetch() async {
    final todo = songs.where((s) => !withLyrics.contains(s.id)).toList();
    if (todo.isEmpty) {
      _toast('كل الأغاني عندها كلمات');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('سحب الكلمات الناقصة'),
        content: Text(
            'راح أبحث بالإنترنت عن كلمات لـ ${todo.length} أغنية. ممكن ياخذ وقت، وتقدر توقفه بأي لحظة. النتائج تقريبية، وتكدر تعدّل أي كلمات بعدين.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ابدأ')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    var cancel = false;
    var done = 0, found = 0;
    StateSetter? setDlg;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(builder: (ctx, st) {
          setDlg = st;
          return AlertDialog(
            title: const Text('جاري سحب الكلمات'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: done / todo.length),
              const SizedBox(height: 12),
              Text('$done / ${todo.length}  (لقيت كلمات لـ $found)'),
            ]),
            actions: [
              TextButton(onPressed: () => cancel = true, child: const Text('إيقاف')),
            ],
          );
        }),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 200));
    for (final s in todo) {
      if (cancel || !mounted) break;
      try {
        final r = await LrcLib.fetch(
            s.title, cleanArtist(s.artist), (s.duration ?? 0) ~/ 1000);
        if (r != null) {
          await Db.save(s.id, r);
          found++;
        }
      } catch (_) {}
      done++;
      setDlg?.call(() {});
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await _refreshMeta();
    _toast('خلصت: لقيت كلمات لـ $found من $done أغنية');
  }

  Future<void> _export() async {
    final all = await Db.all();
    final trs = await Db.allTr();
    final favIds = await Db.favs();
    final hid = await Db.hiddenIds();
    final offs = await Db.offsets();
    final meta = await Db.metaAll();
    final pls = await Db.playlists();
    final byId = {for (final x in rawSongs) x.id: x};

    Map<String, dynamic> ref(int id) {
      final x = byId[id];
      return {
        'id': id,
        'file': x?.displayName ?? '',
        'size': x?.size ?? 0,
        'title': x?.title ?? '',
        'artist': cleanArtist(x?.artist),
      };
    }

    // الكلمات والترجمة
    final items = <Map<String, dynamic>>[];
    for (final e in all.entries) {
      final x = byId[e.key];
      final tr = trs[e.key];
      items.add({
        ...ref(e.key),
        'album': x?.album ?? '',
        'duration': x?.duration ?? 0,
        'lrc': e.value,
        'tr': tr == null ? null : jsonDecode(tr),
      });
    }

    // المفضلة والمخفي وضبط التوقيت والأسماء المعدّلة
    final extraIds = <int>{...favIds, ...hid, ...offs.keys, ...meta.keys};
    final extra = <Map<String, dynamic>>[];
    for (final id in extraIds) {
      if (!byId.containsKey(id)) continue;
      extra.add({
        ...ref(id),
        if (favIds.contains(id)) 'fav': true,
        if (hid.contains(id)) 'hidden': true,
        if (offs.containsKey(id)) 'off': offs[id],
        if (meta.containsKey(id))
          'meta': {'title': meta[id]![0], 'artist': meta[id]![1]},
      });
    }

    // قوائم التشغيل (بالترتيب)
    final playlists = <Map<String, dynamic>>[];
    for (final pl in pls) {
      final ids = await Db.playlistSongIds(pl['id'] as int);
      playlists.add({
        'name': pl['name'],
        'songs': [
          for (final i in ids)
            if (byId.containsKey(i)) ref(i)
        ],
      });
    }

    final settings = <String, String>{};
    for (final k in ['sort', 'shuffle', 'repeat', 'font_scale', 'player_page']) {
      final v = await Db.getKv(k);
      if (v != null) settings[k] = v;
    }

    if (items.isEmpty && extra.isEmpty && playlists.isEmpty) {
      _toast('ماكو بيانات للتصدير');
      return;
    }
    final text = jsonEncode({
      'app': 'lyrics_player',
      'version': 3,
      'items': items,
      'songs': extra,
      'playlists': playlists,
      'settings': settings,
    });
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'حفظ النسخة الاحتياطية',
        fileName: 'lyrics_player_backup.json',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (path != null) {
        _toast(
            'تم التصدير: ${items.length} كلمات، ${favIds.length} مفضلة، ${playlists.length} قوائم');
      }
    } catch (_) {
      _toast('تعذّر حفظ الملف');
    }
  }

  Future<void> _import() async {
    try {
      final r = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true);
      if (r == null || r.files.isEmpty) return;
      final bytes = r.files.first.bytes;
      if (bytes == null) {
        _toast('تعذّر قراءة الملف');
        return;
      }
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      String norm(String? x) => (x ?? '').trim().toLowerCase();
      final byFile = <String, SongModel>{};
      final byKey = <String, SongModel>{};
      final byTitle = <String, List<SongModel>>{};
      for (final x in rawSongs) {
        byFile['${x.displayName}|${x.size}'] = x;
        byKey['${norm(x.title)}|${norm(cleanArtist(x.artist))}'] = x;
        byTitle.putIfAbsent(norm(x.title), () => []).add(x);
      }
      final byId = {for (final x in rawSongs) x.id: x};

      // الأفضل: اسم الملف + حجمه، بعدين العنوان والفنان
      SongModel? find(Map<String, dynamic> it) {
        final file = it['file'];
        final size = it['size'];
        if (file is String && file.isNotEmpty && size is int) {
          final f = byFile['$file|$size'];
          if (f != null) return f;
        }
        final title = norm(it['title'] as String?);
        final artist = norm(it['artist'] as String?);
        final k = byKey['$title|$artist'];
        if (k != null) return k;
        if (title.isNotEmpty) {
          final c = byTitle[title];
          return (c != null && c.length == 1) ? c.first : null;
        }
        final id = it['id'];
        return id is int ? byId[id] : null;
      }

      List<Map<String, dynamic>> listOf(String key) => [
            for (final x in (data[key] as List? ?? const []))
              (x as Map).cast<String, dynamic>()
          ];

      var lyr = 0, skipped = 0, favN = 0, plN = 0;

      for (final it in listOf('items')) {
        final lrc = (it['lrc'] as String?) ?? '';
        if (lrc.trim().isEmpty) continue;
        final target = find(it);
        if (target == null) {
          skipped++;
          continue;
        }
        await Db.save(target.id, lrc);
        final tr = it['tr'];
        if (tr is List) {
          final list = tr.map((x) => x.toString()).toList();
          if (list.length == Lyrics.parse(lrc).length) {
            await Db.saveTr(target.id, list);
          }
        }
        lyr++;
      }

      for (final it in listOf('songs')) {
        final t = find(it);
        if (t == null) continue;
        if (it['fav'] == true) {
          await Db.setFav(t.id, true);
          favN++;
        }
        if (it['hidden'] == true) await Db.hide(t.id);
        final off = it['off'];
        if (off is int) await Db.setKv('off_${t.id}', '$off');
        final m = it['meta'];
        if (m is Map) {
          final mt = (m['title'] ?? '').toString().trim();
          if (mt.isNotEmpty) {
            await Db.setMeta(t.id, mt, (m['artist'] ?? '').toString().trim());
          }
        }
      }

      final existing = {
        for (final e in await Db.playlists()) e['name'] as String: e['id'] as int
      };
      for (final pl in listOf('playlists')) {
        final name = (pl['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final pid = existing[name] ?? await Db.newPlaylist(name);
        existing[name] = pid;
        for (final x in (pl['songs'] as List? ?? const [])) {
          final t = find((x as Map).cast<String, dynamic>());
          if (t != null) await Db.addToPlaylist(pid, t.id);
        }
        plN++;
      }

      final st = data['settings'];
      if (st is Map) {
        for (final k in ['sort', 'shuffle', 'repeat', 'font_scale', 'player_page']) {
          final v = st[k];
          if (v is String) await Db.setKv(k, v);
        }
        await Ctrl.loadPrefs();
        sort = await Db.getKv('sort') ?? sort;
      }

      libraryVersion.value++; // يعيد القراءة (الأسماء المعدّلة وغيرها)
      final parts = <String>[];
      if (lyr > 0) parts.add('$lyr كلمات');
      if (favN > 0) parts.add('$favN مفضلة');
      if (plN > 0) parts.add('$plN قوائم');
      var msg = parts.isEmpty
          ? 'ما لقيت شي جديد يتستورد'
          : 'تم استيراد: ${parts.join('، ')}';
      if (skipped > 0) msg += ' (تخطّيت $skipped لأن الأغنية غير موجودة)';
      _toast(msg);
    } catch (_) {
      _toast('الملف غير صالح');
    }
  }

  Future<void> _openList(int pid, String name) async {
    final ids = pid == -1 ? (await Db.favs()).toList() : await Db.playlistSongIds(pid);
    final byId = {for (final s in songs) s.id: s};
    final list = [
      for (final i in ids)
        if (byId[i] != null) byId[i]!
    ];
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupPage(
            group: Grp(name, null, list), playlistId: pid, allSongs: songs),
      ),
    );
    _refreshMeta();
  }

  Future<void> _listMenu(int pid, String name) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: surface,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('إعادة تسمية'),
              onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('حذف القائمة'),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    if (choice == 'rename') {
      final n = await askName(context, 'إعادة تسمية', initial: name);
      if (n != null && n.isNotEmpty) {
        await Db.renamePlaylist(pid, n);
        _refreshMeta();
      }
    } else if (choice == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('حذف القائمة؟'),
          content: Text('راح تنحذف القائمة "$name" (الأغاني نفسها ما تنحذف).'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('حذف')),
          ],
        ),
      );
      if (ok == true) {
        await Db.deletePlaylist(pid);
        _refreshMeta();
      }
    }
  }

  Widget _listsTab() {
    final byId = {for (final s in songs) s.id: s};
    final favCount = favs.where(byId.containsKey).length;
    return ListView(children: [
      ListTile(
        leading: const Icon(Icons.add_circle_outline, color: saffron),
        title: const Text('قائمة جديدة'),
        onTap: () async {
          final name = await askName(context, 'قائمة جديدة');
          if (name == null || name.isEmpty) return;
          await Db.newPlaylist(name);
          _refreshMeta();
        },
      ),
      ListTile(
        leading: const Icon(Icons.favorite, color: Color(0xFFE5737F)),
        title: const Text('المفضلة'),
        subtitle: Text('$favCount أغنية', style: const TextStyle(color: muted)),
        trailing: const Icon(Icons.chevron_left, color: muted),
        onTap: () => _openList(-1, 'المفضلة'),
      ),
      for (final l in lists)
        ListTile(
          leading: const Icon(Icons.queue_music, color: muted),
          title: Text('${l['name']}'),
          subtitle: Text('${l['n']} أغنية', style: const TextStyle(color: muted)),
          trailing: const Icon(Icons.chevron_left, color: muted),
          onTap: () => _openList(l['id'] as int, '${l['name']}'),
          onLongPress: () => _listMenu(l['id'] as int, '${l['name']}'),
        ),
    ]);
  }

  Widget _groupsTab(List<Grp> gs, IconData icon, {bool art = false}) {
    if (gs.isEmpty) return const Center(child: Text('ماكو نتائج'));
    return ListView.builder(
      itemCount: gs.length,
      itemBuilder: (c, i) {
        final g = gs[i];
        return ListTile(
          leading: art ? Cover(g.songs.first.id) : Icon(icon, color: muted),
          title: Text(g.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${g.songs.length} أغنية', style: const TextStyle(color: muted)),
            if (g.sub != null)
              Text(g.sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(color: muted, fontSize: 12)),
          ]),
          trailing: const Icon(Icons.chevron_left, color: muted),
          onTap: () async {
            await Navigator.push(
                context, MaterialPageRoute(builder: (_) => GroupPage(group: g)));
            _refreshMeta();
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = filter.trim().toLowerCase();
    var shown = f.isEmpty
        ? songs
        : songs
            .where((s) =>
                s.title.toLowerCase().contains(f) ||
                cleanArtist(s.artist).toLowerCase().contains(f) ||
                _albumOf(s).toLowerCase().contains(f) ||
                _lastSeg(_dirOf(s)).toLowerCase().contains(f))
            .toList();
    if (lyricsFilter == 'none') {
      shown = shown.where((s) => !withLyrics.contains(s.id)).toList();
    } else if (lyricsFilter == 'has') {
      shown = shown.where((s) => withLyrics.contains(s.id)).toList();
    }
    final noLyricsCount = songs.where((s) => !withLyrics.contains(s.id)).length;
    final scoped = f.isNotEmpty || lyricsFilter != 'all';

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
      body = TabBarView(children: [
        shown.isEmpty
            ? const Center(child: Text('ماكو نتائج'))
            : ListView.builder(
                itemCount: shown.length,
                itemBuilder: (c, i) => SongTile(
                  song: shown[i],
                  hasLyrics: withLyrics.contains(shown[i].id),
                  isFav: favs.contains(shown[i].id),
                  selected: selecting ? sel.contains(shown[i].id) : null,
                  onTap: () {
                    if (selecting) {
                      _toggleSel(shown[i].id);
                    } else {
                      _playFrom(shown, i, name: scoped ? 'نتائج البحث' : null);
                    }
                  },
                  onLong: () {
                    if (selecting) {
                      _toggleSel(shown[i].id);
                    } else {
                      showSongMenu(context, shown[i],
                          onChanged: _refreshMeta,
                          onSelect: () => setState(() {
                                selecting = true;
                                sel = {shown[i].id};
                              }));
                    }
                  },
                ),
              ),
        _groupsTab(_groupBy(shown, _artistOf), Icons.person, art: true),
        _groupsTab(_groupBy(shown, _albumOf), Icons.album, art: true),
        _groupsTab(
          _groupBy(shown, _dirOf, title: _lastSeg, sub: _parentSeg),
          Icons.folder,
        ),
        _listsTab(),
      ]);
    }

    return DefaultTabController(
      length: 5,
      child: PopScope(
        canPop: !selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && selecting) {
            setState(() {
              selecting = false;
              sel = {};
            });
          }
        },
        child: Scaffold(
        appBar: AppBar(
          leading: selecting
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'إلغاء التحديد',
                  onPressed: () => setState(() {
                        selecting = false;
                        sel = {};
                      }))
              : null,
          title: Text(selecting ? '${sel.length} محددة' : 'مشغل الكلمات'),
          actions: selecting
              ? [
                  IconButton(
                      tooltip: 'تحديد الكل',
                      icon: const Icon(Icons.select_all),
                      onPressed: () =>
                          setState(() => sel = {for (final x in shown) x.id})),
                  IconButton(
                      tooltip: 'نقل إلى مجلد',
                      icon: const Icon(Icons.drive_file_move_outline),
                      onPressed: sel.isEmpty ? null : _moveSelected),
                ]
              : [
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'sort':
                    _pickSort();
                    break;
                  case 'bulk':
                    _bulkFetch();
                    break;
                  case 'hidden':
                    _showHidden();
                    break;
                  case 'export':
                    _export();
                    break;
                  case 'import':
                    _import();
                    break;
                  case 'update':
                    Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const UpdatePage()));
                    break;
                }
              },
              itemBuilder: (c) => const [
                PopupMenuItem(value: 'sort', child: Text('ترتيب الأغاني')),
                PopupMenuItem(value: 'hidden', child: Text('الأغاني المخفية')),
                PopupMenuItem(
                    value: 'bulk', child: Text('سحب كلمات الأغاني الناقصة')),
                PopupMenuItem(
                    value: 'export', child: Text('نسخة احتياطية كاملة (تصدير)')),
                PopupMenuItem(value: 'import', child: Text('استيراد نسخة احتياطية')),
                PopupMenuItem(value: 'update', child: Text('تحديث التطبيق')),
              ],
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            indicatorColor: saffron,
            labelColor: saffron,
            unselectedLabelColor: muted,
            tabs: [
              Tab(text: 'الأغاني'),
              Tab(text: 'الفنانين'),
              Tab(text: 'الألبومات'),
              Tab(text: 'المجلدات'),
              Tab(text: 'القوائم'),
            ],
          ),
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => filter = v),
              decoration: InputDecoration(
                hintText: 'ابحث باسم الأغنية أو الفنان أو الألبوم',
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
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final o in [
                  ['all', 'الكل'],
                  ['none', 'بدون كلمات ($noLyricsCount)'],
                  ['has', 'مع كلمات'],
                ])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ChoiceChip(
                      label: Text(o[1]),
                      selected: lyricsFilter == o[0],
                      onSelected: (_) => setState(() => lyricsFilter = o[0]),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: body),
        ]),
        bottomNavigationBar: const MiniPlayer(),
      ),
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
            title: Row(children: [
              Cover(s.id, size: 40, radius: 6),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17)),
                  if (artist.isNotEmpty)
                    Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: muted)),
                ]),
              ),
            ]),
            actions: [
              FavButton(key: ValueKey(s.id), id: s.id),
              ValueListenableBuilder<DateTime?>(
                valueListenable: Ctrl.sleepEnd,
                builder: (c, end, _) => IconButton(
                  tooltip: 'إعدادات التشغيل',
                  onPressed: () => showPlaySettings(context),
                  icon: Icon(end != null ? Icons.bedtime : Icons.tune,
                      color: end != null ? saffron : null),
                ),
              ),
            ],
          ),
          body: Stack(children: [
            Positioned.fill(child: Backdrop(id: s.id)),
            Column(children: [
              Expanded(child: _PlayerPager(song: s)),
              const Controls(),
            ]),
          ]),
        );
      },
    );
  }
}

/// صفحتين بالسحب (يمين أو يسار): الكلمات، وصورة الغلاف. يتذكر آخر صفحة اخترتها.
class _PlayerPager extends StatefulWidget {
  final SongModel song;
  const _PlayerPager({required this.song});
  @override
  State<_PlayerPager> createState() => _PlayerPagerState();
}

class _PlayerPagerState extends State<_PlayerPager> {
  PageController? pc;
  int page = 0;

  @override
  void initState() {
    super.initState();
    Db.getKv('player_page').then((v) {
      final i = v == '1' ? 1 : 0;
      if (!mounted) return;
      setState(() {
        page = i;
        // صفحات لا نهائية حتى السحب يشتغل للجهتين
        pc = PageController(initialPage: 1000 + i);
      });
    });
  }

  @override
  void dispose() {
    pc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = pc;
    if (c == null) return const SizedBox.shrink();
    final s = widget.song;
    return Column(children: [
      Expanded(
        child: PageView.builder(
          controller: c,
          onPageChanged: (k) {
            final i = k % 2;
            setState(() => page = i);
            Db.setKv('player_page', '$i');
          },
          itemBuilder: (context, k) => k.isEven
              ? LyricsView(key: ValueKey('${s.id}_$k'), song: s)
              : _CoverPage(song: s),
        ),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 2; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            width: page == i ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: page == i ? saffron : muted.withOpacity(0.5),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ]),
    ]);
  }
}

/// صفحة صورة الأغنية / الألبوم بحجم كبير
class _CoverPage extends StatelessWidget {
  final SongModel song;
  const _CoverPage({required this.song});

  @override
  Widget build(BuildContext context) {
    final artist = cleanArtist(song.artist);
    final alb = song.album;
    final sub = [
      if (artist.isNotEmpty) artist,
      if (alb != null && alb.isNotEmpty && alb != '<unknown>') alb,
    ].join(' • ');
    return LayoutBuilder(builder: (context, c) {
      var side = c.maxWidth - 56;
      final maxH = c.maxHeight - 110;
      if (side > maxH) side = maxH;
      if (side > 420) side = 420;
      if (side < 120) side = 120;
      final r = BorderRadius.circular(22);
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              borderRadius: r,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.45),
                    blurRadius: 28,
                    offset: const Offset(0, 12)),
              ],
            ),
            child: QueryArtworkWidget(
              id: song.id,
              type: ArtworkType.AUDIO,
              size: 1000,
              quality: 100,
              artworkWidth: side,
              artworkHeight: side,
              artworkBorder: r,
              artworkFit: BoxFit.cover,
              keepOldArtwork: true,
              nullArtworkWidget: Container(
                width: side,
                height: side,
                decoration: BoxDecoration(color: surface, borderRadius: r),
                child: Icon(Icons.music_note, color: muted, size: side * 0.4),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(song.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          if (sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 28, right: 28),
              child: Text(sub,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted)),
            ),
        ]),
      );
    });
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
  List<String>? tr;
  bool showTr = true;
  bool translating = false;
  final sc = ItemScrollController();
  StreamSubscription<Duration>? sub;

  @override
  void initState() {
    super.initState();
    _load();
    Ctrl.fontScale.addListener(_onFont);
    sub = Ctrl.player.positionStream.listen(_onPos);
  }

  void _onFont() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    Ctrl.fontScale.removeListener(_onFont);
    sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final raw = await Db.get(widget.song.id);
    final l = raw == null ? null : Lyrics.parse(raw);
    var t = raw == null ? null : await Db.getTr(widget.song.id);
    if (l != null && t != null && t.length != l.length) t = null;
    final off = int.tryParse(await Db.getKv('off_${widget.song.id}') ?? '') ?? 0;
    if (!mounted) return;
    setState(() {
      offsetMs = off;
      lyrics = l;
      tr = t;
      loading = false;
      active = -1;
    });
  }

  Future<void> _translate() async {
    final l = lyrics;
    if (l == null || translating) return;
    setState(() => translating = true);
    final msg = ScaffoldMessenger.of(context);
    msg.showSnackBar(const SnackBar(
        content: Text('جاري الترجمة...'), duration: Duration(seconds: 60)));
    try {
      final src = l.synced
          ? l.lines.map((e) => e.text).toList()
          : List<String>.from(l.plain);
      final t = await Translator.lines(src);
      msg.hideCurrentSnackBar();
      if (t.every((e) => e.isEmpty)) {
        msg.showSnackBar(
            const SnackBar(content: Text('ماكو سطور إنكليزية تحتاج ترجمة')));
      } else {
        await Db.saveTr(widget.song.id, t);
        if (mounted) {
          setState(() {
            tr = t;
            showTr = true;
          });
        }
      }
    } catch (_) {
      msg.hideCurrentSnackBar();
      msg.showSnackBar(const SnackBar(
          content: Text('تعذّرت الترجمة. تأكد من الإنترنت وجرّب مرة ثانية.')));
    } finally {
      if (mounted) setState(() => translating = false);
    }
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

  void _bump(int d) {
    setState(() => offsetMs += d);
    Db.setKv('off_${widget.song.id}', '$offsetMs');
  }

  void _seekTo(LyricLine l) {
    var d = l.time - Duration(milliseconds: offsetMs);
    if (d < Duration.zero) d = Duration.zero;
    Ctrl.player.seek(d);
  }

  Widget _line(int i) {
    final l = lyrics!;
    final fs = Ctrl.fontScale.value;
    final raw = l.synced ? l.lines[i].text : l.plain[i];
    final text = raw.isEmpty ? (l.synced ? '♪' : ' ') : raw;
    final on = l.synced && i == active;
    final t = (showTr && tr != null && i < tr!.length) ? tr![i] : '';
    return InkWell(
      onTap: l.synced ? () => _seekTo(l.lines[i]) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 24),
        child: Column(children: [
          Directionality(
            textDirection: _isArabic(text) ? TextDirection.rtl : TextDirection.ltr,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 250),
              style: TextStyle(
                fontSize: (on ? 27 : 20) * fs,
                height: 1.45,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                color: on ? saffron : (l.synced ? muted : paper),
              ),
              textAlign: TextAlign.center,
              child: Text(text, textAlign: TextAlign.center),
            ),
          ),
          if (t.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                t,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: (on ? 18 : 16) * fs,
                  height: 1.4,
                  color: on ? paper : muted.withOpacity(0.85),
                ),
              ),
            ),
        ]),
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
            IconButton(
              tooltip: tr == null
                  ? 'ترجمة للعربي'
                  : (showTr ? 'إخفاء الترجمة' : 'إظهار الترجمة'),
              onPressed: translating
                  ? null
                  : () {
                      if (tr == null) {
                        _translate();
                      } else {
                        setState(() => showTr = !showTr);
                      }
                    },
              icon: translating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.translate,
                      color: (tr != null && showTr) ? saffron : null),
            ),
            const Spacer(),
            if (lyrics!.synced) ...[
              IconButton(
                  onPressed: () => _bump(-500),
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
                  onPressed: () => _bump(500),
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
            ValueListenableBuilder<SongModel?>(
              valueListenable: Ctrl.current,
              builder: (c, _, __) => Directionality(
                textDirection: TextDirection.rtl,
                child: Text('التشغيل من: ${Ctrl.queueName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 12)),
              ),
            ),
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
              ValueListenableBuilder<bool>(
                valueListenable: Ctrl.shuffle,
                builder: (c, on, _) => IconButton(
                  tooltip: 'تشغيل عشوائي',
                  onPressed: Ctrl.toggleShuffle,
                  icon: Icon(Icons.shuffle, color: on ? saffron : muted),
                ),
              ),
              IconButton(
                  iconSize: 38,
                  onPressed: Ctrl.prev,
                  icon: const Icon(Icons.skip_previous)),
              const SizedBox(width: 4),
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
              const SizedBox(width: 4),
              IconButton(
                  iconSize: 38,
                  onPressed: Ctrl.next,
                  icon: const Icon(Icons.skip_next)),
              ValueListenableBuilder<int>(
                valueListenable: Ctrl.repeat,
                builder: (c, m, _) => IconButton(
                  tooltip: m == 0
                      ? 'بدون تكرار'
                      : (m == 1 ? 'تكرار القائمة' : 'تكرار الأغنية'),
                  onPressed: Ctrl.cycleRepeat,
                  icon: Icon(m == 2 ? Icons.repeat_one : Icons.repeat,
                      color: m == 0 ? muted : saffron),
                ),
              ),
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
  final focus = FocusNode();
  bool stamping = false;
  final List<TextEditingValue> _undo = [];

  // تعويض بسيط لتأخر ضغطة الإصبع عن بداية السطر
  static const _reaction = Duration(milliseconds: 250);
  static final _tsPrefix =
      RegExp(r'^\s*(\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]\s*)+');

  @override
  void dispose() {
    c.dispose();
    focus.dispose();
    super.dispose();
  }

  String _clock(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = ((d.inMilliseconds ~/ 10) % 100).toString().padLeft(2, '0');
    return '$m:$s.$h';
  }

  void _toast(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  int _lineStart(String text, int off) =>
      off <= 0 ? 0 : text.lastIndexOf('\n', off - 1) + 1;

  int _cursor() {
    final text = c.text;
    var off = c.selection.baseOffset;
    if (off < 0) off = 0;
    if (off > text.length) off = text.length;
    return off;
  }

  /// يختم وقت الأغنية الحالي على السطر اللي عليه المؤشر، وينتقل للسطر التالي
  void _stamp() {
    if (Ctrl.current.value?.id != widget.song.id) {
      _toast('الأغنية الحالية تغيّرت. ارجع وافتح كلمات الأغنية اللي تشتغل هسه.');
      return;
    }
    final text = c.text;
    final off = _cursor();
    final start = _lineStart(text, off);
    var end = text.indexOf('\n', off);
    if (end < 0) end = text.length;
    final body = text.substring(start, end).replaceFirst(_tsPrefix, '').trimLeft();
    var pos = Ctrl.player.position - _reaction;
    if (pos < Duration.zero) pos = Duration.zero;
    final newLine = '[${_clock(pos)}] $body';
    final newText = text.substring(0, start) + newLine + text.substring(end);
    final next = start + newLine.length;
    final cursor = next < newText.length ? next + 1 : next;
    _undo.add(c.value);
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  void _undoStamp() {
    if (_undo.isEmpty) {
      _toast('ماكو شي للتراجع عنه');
      return;
    }
    c.value = _undo.removeLast();
  }

  Future<void> _importFile() async {
    try {
      final r = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true);
      if (r == null || r.files.isEmpty) return;
      final b = r.files.first.bytes;
      if (b == null) {
        _toast('تعذّر قراءة الملف');
        return;
      }
      _undo.add(c.value);
      setState(() => c.text = utf8.decode(b, allowMalformed: true).replaceFirst('\uFEFF', ''));
      _toast('تم استيراد الملف. اضغط ✓ للحفظ.');
    } catch (_) {
      _toast('تعذّر قراءة الملف');
    }
  }

  Future<void> _exportFile() async {
    final t = c.text.trim();
    if (t.isEmpty) {
      _toast('ماكو كلمات للتصدير');
      return;
    }
    try {
      final name = widget.song.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'حفظ الكلمات',
        fileName: '$name.lrc',
        bytes: Uint8List.fromList(utf8.encode(t)),
      );
      if (path != null) _toast('تم حفظ الملف');
    } catch (_) {
      _toast('تعذّر حفظ الملف');
    }
  }

  void _moveLine(int dir) {
    final text = c.text;
    final start = _lineStart(text, _cursor());
    int target;
    if (dir > 0) {
      final nl = text.indexOf('\n', start);
      target = nl < 0 ? text.length : nl + 1;
    } else if (start <= 1) {
      target = 0;
    } else {
      target = text.lastIndexOf('\n', start - 2) + 1;
    }
    c.selection = TextSelection.collapsed(offset: target);
  }

  void _seekBy(int sec) {
    var t = Ctrl.player.position + Duration(seconds: sec);
    if (t < Duration.zero) t = Duration.zero;
    Ctrl.player.seek(t);
  }

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

  Widget _panel() {
    return Container(
      color: surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                  value: false, label: Text('تحرير النص'), icon: Icon(Icons.edit)),
              ButtonSegment(
                  value: true, label: Text('ختم الوقت'), icon: Icon(Icons.timer)),
            ],
            selected: {stamping},
            onSelectionChanged: (v) {
              setState(() => stamping = v.first);
              if (stamping) {
                focus.requestFocus();
                SystemChannels.textInput.invokeMethod('TextInput.hide');
              }
            },
          ),
          if (stamping) ...[
            const SizedBox(height: 8),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                IconButton(
                    tooltip: 'من البداية',
                    onPressed: () => Ctrl.player.seek(Duration.zero),
                    icon: const Icon(Icons.skip_previous)),
                IconButton(
                    tooltip: 'رجوع 5 ثواني',
                    onPressed: () => _seekBy(-5),
                    icon: const Icon(Icons.replay_5)),
                StreamBuilder<bool>(
                  stream: Ctrl.player.playingStream,
                  builder: (c2, st) {
                    final playing = st.data ?? false;
                    return IconButton.filled(
                      style: IconButton.styleFrom(
                          backgroundColor: saffron, foregroundColor: Colors.black),
                      onPressed: () =>
                          playing ? Ctrl.player.pause() : Ctrl.player.play(),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    );
                  },
                ),
                IconButton(
                    tooltip: 'تقديم 5 ثواني',
                    onPressed: () => _seekBy(5),
                    icon: const Icon(Icons.forward_5)),
                StreamBuilder<Duration>(
                  stream: Ctrl.player.positionStream,
                  builder: (c2, st) => SizedBox(
                    width: 64,
                    child: Text(_clock(st.data ?? Duration.zero),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: muted, fontSize: 13)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Row(children: [
              IconButton.outlined(
                  tooltip: 'تراجع عن آخر ختم',
                  onPressed: _undoStamp,
                  icon: const Icon(Icons.undo)),
              const SizedBox(width: 8),
              IconButton.outlined(
                  tooltip: 'السطر السابق',
                  onPressed: () => _moveLine(-1),
                  icon: const Icon(Icons.keyboard_arrow_up)),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _stamp,
                  icon: const Icon(Icons.timer),
                  label: const Text('ختم الوقت للسطر'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: saffron,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                  tooltip: 'السطر التالي',
                  onPressed: () => _moveLine(1),
                  icon: const Icon(Icons.keyboard_arrow_down)),
            ]),
          ],
        ]),
      ),
    );
  }

  Future<void> _onPop(bool didPop, Object? result) async {
    if (didPop) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تريد تحفظ التغييرات؟'),
        content: const Text('عندك تعديلات (أو أختام وقت) ما انحفظت.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('رجوع للتعديل')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: const Text('تجاهل')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'save') {
      await _save();
    } else if (choice == 'discard') {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: c,
      builder: (context, value, _) => PopScope(
        canPop: value.text == widget.initial,
        onPopInvokedWithResult: _onPop,
        child: _scaffold(),
      ),
    );
  }

  Widget _scaffold() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الكلمات'),
        actions: [
          IconButton(
              tooltip: 'سحب من الإنترنت',
              onPressed: _fetch,
              icon: const Icon(Icons.cloud_download)),
          IconButton(tooltip: 'حفظ', onPressed: _save, icon: const Icon(Icons.check)),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'import' ? _importFile() : _exportFile(),
            itemBuilder: (c) => const [
              PopupMenuItem(
                  value: 'import', child: Text('استيراد من ملف (.lrc / .txt)')),
              PopupMenuItem(value: 'export', child: Text('تصدير كملف .lrc')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            stamping
                ? 'اضغط على السطر اللي تريد تختمه، شغّل الأغنية، واضغط الزر لحظة ما يبدأ السطر. المؤشر ينتقل للسطر التالي لحاله.'
                : 'اكتب أو الصق الكلمات (سطر لكل جملة)، وبعدها اختر "ختم الوقت" حتى تتزامن مع الأغنية. مسح كل النص يحذف الكلمات.',
            style: const TextStyle(color: muted, fontSize: 13, height: 1.5),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: c,
              focusNode: focus,
              readOnly: stamping,
              showCursor: true,
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
        ),
        const SizedBox(height: 8),
        _panel(),
      ]),
    );
  }
}
