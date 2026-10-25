import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';

/// Everything the app knows about a clip. Detection output is written once and never
/// rewritten, so the user's edits are the only thing a re-analysis could destroy - and
/// it is the reason `analyzed_at` exists at all.
class AppDatabase {
  AppDatabase(this._db);

  static const _name = 'basketball_highlights.db';

  final Database _db;

  static Future<AppDatabase> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(p.join(dir, _name), version: 1,
        onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE videos(
          id TEXT PRIMARY KEY,
          uri TEXT NOT NULL,
          duration_us INTEGER NOT NULL,
          fps REAL,
          width INTEGER,
          height INTEGER,
          analyzed_at INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE shots(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          video_id TEXT NOT NULL,
          t_us INTEGER NOT NULL,
          is_make INTEGER NOT NULL,
          origin TEXT NOT NULL,
          window_before_us INTEGER NOT NULL,
          window_after_us INTEGER NOT NULL,
          enabled INTEGER NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX shots_video ON shots(video_id, t_us)');
    });
    return AppDatabase(db);
  }

  Future<List<Video>> videos() async =>
      (await _db.query('videos', orderBy: 'rowid')).map(Video.fromRow).toList();

  /// The library rows show how much of each clip is already marked, so counting is done in
  /// the same read instead of a query per video.
  Future<List<({Video video, int shots, int makes})>> videoSummaries() async {
    final rows = await _db.rawQuery('''
      SELECT v.*,
             (SELECT COUNT(*) FROM shots s WHERE s.video_id = v.id) AS shot_count,
             (SELECT COUNT(*) FROM shots s WHERE s.video_id = v.id AND s.is_make = 1)
               AS make_count
      FROM videos v ORDER BY v.rowid
    ''');
    return [
      for (final row in rows)
        (
          video: Video.fromRow(row),
          shots: (row['shot_count'] as int?) ?? 0,
          makes: (row['make_count'] as int?) ?? 0,
        ),
    ];
  }

  Future<void> deleteVideo(Video video) async {
    await _db.delete('shots', where: 'video_id = ?', whereArgs: [video.id]);
    await _db.delete('videos', where: 'id = ?', whereArgs: [video.id]);
  }

  /// Registering a clip twice (the picker hands back the same uri) must not duplicate its
  /// markers, so the uri is the primary key and the row is kept as-is.
  Future<void> upsertVideo(Video video) => _db.insert('videos', video.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore);

  /// Opening a clip fills in what the picker could not know. Only these columns are written,
  /// so a re-open cannot reset `analyzed_at` and let detection overwrite edited markers.
  Future<void> updateVideoMeta(Video video) async {
    await _db.update('videos', {
      'duration_us': video.durationUs,
      'width': video.width,
      'height': video.height,
    }, where: 'id = ?', whereArgs: [video.id]);
  }

  Future<List<Shot>> shots(String videoId) async =>
      (await _db.query('shots', where: 'video_id = ?', whereArgs: [videoId], orderBy: 't_us'))
          .map(Shot.fromRow)
          .toList();

  /// No-op once the clip has been analysed; returns the markers that are actually stored.
  Future<List<Shot>> saveAnalysis(Video video, List<Shot> detected) async {
    final existing = await _db.query('videos',
        columns: ['analyzed_at'], where: 'id = ?', whereArgs: [video.id], limit: 1);
    final analysed = existing.isNotEmpty && existing.first['analyzed_at'] != null;
    if (!analysed) {
      await _db.transaction((txn) async {
        for (final shot in detected) {
          await txn.insert('shots', shot.toRow());
        }
        await txn.update('videos', {'analyzed_at': DateTime.now().microsecondsSinceEpoch},
            where: 'id = ?', whereArgs: [video.id]);
      });
    }
    // Always the stored rows: they carry the ids the editor needs to write back, and on a
    // second run they are the user's edited version, not the fresh detection.
    return shots(video.id);
  }

  Future<int> insertShot(Shot shot) => _db.insert('shots', shot.toRow());

  Future<void> updateShot(Shot shot) async {
    await _db.update('shots', shot.toRow()..remove('id'),
        where: 'id = ?', whereArgs: [shot.id]);
  }

  Future<void> deleteShot(Shot shot) async =>
      _db.delete('shots', where: 'id = ?', whereArgs: [shot.id]);

  Future<void> close() => _db.close();
}
