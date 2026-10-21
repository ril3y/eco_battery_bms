// ECO Battery BMS clock: placing log timestamps on the real timeline when the
// clock is wrong.
//
// The ECO BMS clock has no time zone, resets to ~2022-01-01 when the board loses
// power, and is only set when an app writes it (the stock app does on every
// connect, overwriting the evidence). So logged times
// can be off by days or meaningless. We compare the BMS clock with a trusted
// clock once, then split the log into "clock periods" at every detectable reset
// or re-set. Only the current period can be corrected with the measured offset.

/// The BMS clock compared with a trusted clock at one moment.
class ClockReading {
  /// BMS time as a naive local DateTime, or null if the BMS returned garbage.
  final DateTime? bms;

  /// Trusted time (the phone/PC) when the BMS clock was read.
  final DateTime trusted;
  final String timeZoneName;
  final Duration timeZoneOffset;

  /// Dates before this mean the BMS clock was never set (driver-specific default).
  final DateTime unsetBefore;

  ClockReading(this.bms, this.trusted, {DateTime? unsetBefore})
      : timeZoneName = trusted.timeZoneName,
        timeZoneOffset = trusted.timeZoneOffset,
        unsetBefore = unsetBefore ?? DateTime(2023);

  /// How far the BMS clock is ahead (positive) or behind (negative) of local
  /// wall-clock time, compared field by field (no DST arithmetic).
  Duration? get offset {
    final b = bms;
    if (b == null) return null;
    return _wall(b).difference(_wall(trusted.toLocal()));
  }

  /// Real local time of an event the BMS stamped [bmsTime]. The BMS clock just
  /// counts seconds, so this goes by elapsed time since [bmsTime] on that clock,
  /// which stays right across DST changes.
  DateTime? realTimeOf(DateTime bmsTime) {
    final b = bms;
    if (b == null) return null;
    final elapsed = _wall(b).difference(_wall(bmsTime));
    return trusted.toUtc().subtract(elapsed).toLocal();
  }

  /// Wall-clock fields as UTC, so differences ignore DST.
  static DateTime _wall(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second, d.millisecond);

  bool get isUnset => bms == null || bms!.isBefore(unsetBefore);

  /// Off by more than [tolerance] (default 2 minutes)?
  bool isWrong({Duration tolerance = const Duration(minutes: 2)}) =>
      isUnset || (offset != null && offset!.abs() > tolerance);
}

/// A record placed on the real timeline.
class Placed<T> {
  final T record;

  /// Corrected local time, or null when it can't be known.
  final DateTime? time;

  /// 0 = current clock period (correctable); higher = older periods.
  final int period;

  /// When [time] is null: the record happened before this (oldest corrected) time.
  final DateTime? before;

  const Placed(this.record, this.time, this.period, {this.before});
}

/// Split [newestFirst] records into clock periods and correct the current one.
///
/// A new (older) period starts where time runs *backwards* between consecutive
/// records, i.e. the clock was reset or set back in between. Records showing the
/// unset default are never corrected. A clock that was set *forward* looks the
/// same as idle time and can't be detected.
List<Placed<T>> placeOnTimeline<T>(
  List<T> newestFirst,
  DateTime? Function(T) bmsTimeOf,
  ClockReading reading,
) {
  final usable = !reading.isUnset;
  final out = <Placed<T>>[];
  var period = 0;
  DateTime? prev;
  DateTime? oldestCorrected;
  for (final r in newestFirst) {
    final t = bmsTimeOf(r);
    final unset = t == null || t.isBefore(reading.unsetBefore);
    if (unset) {
      if (period == 0 && out.isNotEmpty) period = 1;
    } else if (prev != null && t.isAfter(prev)) {
      period++;
    }
    if (t != null && !unset) prev = t;
    if (period == 0 && usable && !unset) {
      final real = reading.realTimeOf(t)!;
      oldestCorrected = real;
      out.add(Placed(r, real, 0));
    } else {
      out.add(Placed(r, null, period == 0 ? 1 : period, before: oldestCorrected));
    }
  }
  return out;
}
