import 'package:eco_battery_bms/eco_battery_bms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timeline', () {
    // Shape of a real ECO alarm log: current period (clock ~34 days fast),
    // then records written while the clock was unset (2022 default), with resets.
    // Real capture: BMS clock read 2026-11-24 07:11:53 at 2026-10-21 10:22:37.
    final trusted = DateTime(2026, 10, 21, 10, 22, 37);
    final reading = ClockReading(DateTime(2026, 11, 24, 7, 11, 53), trusted);
    final bms = [
      DateTime(2026, 11, 20, 23, 45, 26),
      DateTime(2026, 10, 29, 20, 15, 47),
      DateTime(2022, 1, 2, 12, 41),
      DateTime(2022, 1, 1, 23, 59),
      DateTime(2022, 1, 2, 0, 1), // clock went backwards: another reset
    ];

    test('current period is corrected, unset ones are not', () {
      final placed = placeOnTimeline(bms, (t) => t, reading);
      // Elapsed-time correction; the BMS dates straddle the DST change, real ones don't.
      expect(placed[0].time, DateTime(2026, 10, 18, 2, 56, 10));
      expect(placed[1].time, DateTime(2026, 9, 25, 23, 26, 31));
      expect(placed.skip(2).every((p) => p.time == null), isTrue);
      expect(placed[2].before, DateTime(2026, 9, 25, 23, 26, 31));
      expect(placed[0].period, 0);
      expect(placed[2].period, greaterThan(0));
    });

    test('a clock set back between records starts an older period', () {
      final times = [DateTime(2026, 5, 2), DateTime(2026, 5, 1), DateTime(2026, 6, 1), DateTime(2026, 5, 30)];
      final placed = placeOnTimeline(times, (t) => t, ClockReading(DateTime(2026, 5, 3), DateTime(2026, 5, 3)));
      expect(placed.map((p) => p.period), [0, 0, 1, 1]);
      expect(placed.map((p) => p.time != null), [true, true, false, false]);
    });

    test('unset or garbage BMS clock corrects nothing', () {
      final r = ClockReading(DateTime(2022, 1, 1, 0, 5), trusted);
      expect(r.isUnset, isTrue);
      expect(r.isWrong(), isTrue);
      expect(placeOnTimeline(bms, (t) => t, r).every((p) => p.time == null), isTrue);
    });

    test('isWrong tolerance', () {
      expect(ClockReading(trusted.add(const Duration(seconds: 30)), trusted).isWrong(), isFalse);
      expect(reading.isWrong(), isTrue);
      expect(reading.offset, const Duration(days: 33, hours: 20, minutes: 49, seconds: 16));
    });
  });

}
