import 'package:auto_internship_finder/pipeline/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dateKey', () {
    test('format yyyy-MM-dd dengan zero padding', () {
      expect(dateKey(DateTime(2026, 10, 1)), '2026-10-01');
      expect(dateKey(DateTime(2026, 1, 9)), '2026-01-09');
      expect(dateKey(DateTime(2026, 12, 31, 23, 59)), '2026-12-31');
    });

    test('jam tidak memengaruhi kunci tanggal', () {
      expect(dateKey(DateTime(2026, 10, 1, 0, 0)), dateKey(DateTime(2026, 10, 1, 23, 59)));
    });
  });

  group('decideWhetherToRun — target pukul 12:00', () {
    test('sebelum jam 12 tidak jalan', () {
      final d = decideWhetherToRun(
        now: DateTime(2026, 10, 1, 11, 59),
        dailyHour: 12,
        lastRunDate: null,
      );
      expect(d.shouldRun, isFalse);
      expect(d.reason, contains('12'));
      expect(d.dateKey, isNull);
    });

    test('tepat pukul 12:00 jalan', () {
      final d = decideWhetherToRun(
        now: DateTime(2026, 10, 1, 12, 0),
        dailyHour: 12,
        lastRunDate: null,
      );
      expect(d.shouldRun, isTrue);
      expect(d.dateKey, '2026-10-01');
    });

    test('tick pertama setelah jam 12 yang jalan, bukan tick sebelumnya', () {
      // Simulasi WorkManager periodik yang anchor-nya tidak pas di 12:00.
      final ticks = [
        DateTime(2026, 10, 1, 10, 20),
        DateTime(2026, 10, 1, 11, 20),
        DateTime(2026, 10, 1, 12, 20),
        DateTime(2026, 10, 1, 13, 20),
      ];

      String? lastRunDate;
      final executed = <DateTime>[];
      for (final tick in ticks) {
        final d = decideWhetherToRun(
          now: tick,
          dailyHour: 12,
          lastRunDate: lastRunDate,
        );
        if (d.shouldRun) {
          executed.add(tick);
          lastRunDate = d.dateKey;
        }
      }

      expect(executed, [DateTime(2026, 10, 1, 12, 20)],
          reason: 'hanya satu eksekusi, pada tick pertama setelah pukul 12');
    });

    test('tidak jalan dua kali dalam sehari', () {
      final d = decideWhetherToRun(
        now: DateTime(2026, 10, 1, 15, 0),
        dailyHour: 12,
        lastRunDate: '2026-10-01',
      );
      expect(d.shouldRun, isFalse);
      expect(d.reason, contains('Sudah dijalankan hari ini'));
    });

    test('jalan lagi keesokan hari walau jamnya lebih awal', () {
      final d = decideWhetherToRun(
        now: DateTime(2026, 10, 2, 12, 5),
        dailyHour: 12,
        lastRunDate: '2026-10-01',
      );
      expect(d.shouldRun, isTrue);
      expect(d.dateKey, '2026-10-02');
    });

    test('jam target bisa dikonfigurasi', () {
      final early = decideWhetherToRun(
        now: DateTime(2026, 10, 1, 7, 0),
        dailyHour: 7,
        lastRunDate: null,
      );
      expect(early.shouldRun, isTrue);

      final late = decideWhetherToRun(
        now: DateTime(2026, 10, 1, 7, 0),
        dailyHour: 20,
        lastRunDate: null,
      );
      expect(late.shouldRun, isFalse);
    });

    test('lewat tengah malam tanpa run kemarin tetap menunggu jam target', () {
      final d = decideWhetherToRun(
        now: DateTime(2026, 10, 2, 0, 30),
        dailyHour: 12,
        lastRunDate: null,
      );
      expect(d.shouldRun, isFalse, reason: 'jangan jalan dini hari sebelum jam target');
    });
  });
}
