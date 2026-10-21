// On-board logs. Unlike most BLE BMSs, ECO Battery boards keep a timestamped
// alarm log and a running (charge/discharge) log, downloadable over BLE.

import 'dart:typed_data';

import 'registers.dart';

enum EcoLogKind {
  alarm(0xDD),
  running(0xEE);

  const EcoLogKind(this.tag);
  final int tag;

  /// Download request. The trailing 48 D2 is a fixed suffix, not a CRC.
  Uint8List get request => Uint8List.fromList([0x01, tag, 1, 2, 3, 4, 5, 6, 0x48, 0xD2]);

  List<int> get header => [0x01, tag, 0x00, 1, 2, 3, 4, 5];
  List<int> get trailer => [tag, 1, 2, 3, 4, 5, 6];
}

/// Collects the raw notification stream of one log download.
class EcoLogCollector {
  final EcoLogKind kind;
  final BytesBuilder _b = BytesBuilder(copy: false);
  EcoLogCollector(this.kind);

  void add(List<int> chunk) => _b.add(chunk);

  Uint8List get bytes => _b.toBytes();

  bool get complete {
    final t = kind.trailer;
    final b = _b.toBytes();
    if (b.length < t.length) return false;
    for (var i = 0; i < t.length; i++) {
      if (b[b.length - t.length + i] != t[i]) return false;
    }
    return true;
  }
}

/// Splits a downloaded log into records (newest first), walking the
/// `aa 55 <len> …` structure by length rather than splitting on `aa 55`,
/// which can also occur inside record data.
List<Uint8List> splitLogRecords(Uint8List raw, EcoLogKind kind) {
  final head = _find(raw, kind.header, 0);
  final tail = _findLast(raw, kind.trailer);
  final start = head < 0 ? 0 : head + kind.header.length;
  final end = (tail > start) ? tail - 1 : raw.length;
  final out = <Uint8List>[];
  var p = start;
  while (p + 3 <= end) {
    if (raw[p] != 0xAA || raw[p + 1] != 0x55) {
      p++;
      continue;
    }
    final n = raw[p + 2] + 3;
    if (p + 2 + n > end) break;
    out.add(Uint8List.sublistView(raw, p + 2, p + 2 + n));
    p += 2 + n;
  }
  return out;
}

int _find(List<int> h, List<int> n, int from) {
  for (var i = from; i + n.length <= h.length; i++) {
    var ok = true;
    for (var j = 0; j < n.length && ok; j++) {
      ok = h[i + j] == n[j];
    }
    if (ok) return i;
  }
  return -1;
}

int _findLast(List<int> h, List<int> n) {
  for (var i = h.length - n.length; i >= 0; i--) {
    var ok = true;
    for (var j = 0; j < n.length && ok; j++) {
      ok = h[i + j] == n[j];
    }
    if (ok) return i;
  }
  return -1;
}

int _u16(List<int> b, int i) => (b[i] << 8) | b[i + 1];
int _s16(List<int> b, int i) {
  final v = _u16(b, i);
  return v >= 0x8000 ? v - 0x10000 : v;
}

int _s8(int v) => v >= 0x80 ? v - 0x100 : v;

/// Flag word at [i]: little-endian on newer firmware, big-endian on older.
int _word(List<int> b, int i, bool newFw) => newFw ? (b[i + 1] << 8) | b[i] : _u16(b, i);

List<String> _labels(int word, Map<int, String> names) => [
      for (final e in names.entries)
        if (msbBit(word, e.key)) e.value,
    ];

/// Readable names for the stock app's log flag codes.
const Map<String, String> kLogFlagNames = {
  'UV': 'Cell under-voltage', 'CUV': 'Cell under-voltage', 'OV': 'Cell over-voltage', 'COV': 'Cell over-voltage',
  'OT_Bat': 'Charge over-temp', 'COT': 'Charge over-temp', 'OT_Mos': 'MOS over-temp', 'MOSOT': 'MOS over-temp',
  'UT_CHG': 'Charge under-temp', 'CUT': 'Charge under-temp', 'UT_DSG': 'Discharge under-temp',
  'DCUT': 'Discharge under-temp', 'OC_DSG': 'Discharge over-current', 'DCOC': 'Discharge over-current',
  'OC_CHG': 'Charge over-current', 'COC': 'Charge over-current', 'SCD': 'Short circuit', 'SC': 'Short circuit',
  'POV': 'Pack over-voltage', 'PUV': 'Pack under-voltage', 'UV_T': 'Secondary under-voltage',
  'OV_T': 'Secondary over-voltage', 'OCD_T': 'Secondary over-current', 'OT_BatDSG': 'Discharge over-temp',
  'DCOT': 'Discharge over-temp', 'VDIFFW': 'Cell difference too high', 'TDIFF': 'Temperature difference',
  'SOCLow': 'Low state of charge', 'LowTemp': 'Low temperature', 'CHIP-E': 'BMS chip error',
  'TEMP_E': 'Temperature sensor error', 'VS': 'Voltage sensor fault', 'TS': 'Temperature sensor fault',
  'MOS Anomaly': 'MOS fault', 'HON': 'Heating on', 'HT': 'Heating timeout', 'TINR': 'Temperature not rising',
  'SR': 'Status record', 'CHG': 'Charge MOS on', 'DSG': 'Discharge MOS on', 'BAL': 'Balancing', 'HEAT': 'Heating',
};

/// Codes describing normal state rather than a problem.
const Set<String> kInformationalFlags = {'SR', 'CHG', 'DSG', 'BAL', 'HEAT', 'HON'};

const _ddOld1 = {1: 'SR', 4: 'SOCLow', 5: 'LowTemp'};
const _ddOld2 = {
  0: 'UV', 1: 'OV', 2: 'OT_Bat', 3: 'OT_Mos', 4: 'UT_CHG', 5: 'UT_DSG', 6: 'OC_DSG', 7: 'OC_CHG',
  8: 'SCD', 9: 'POV', 10: 'PUV', 11: 'UV_T', 12: 'OV_T', 13: 'OCD_T', 15: 'OT_BatDSG',
};
const _ddOld3 = {6: 'CHIP-E', 7: 'TEMP_E'};
const _ddNew1 = {1: 'MOS Anomaly', 10: 'VDIFFW', 11: 'TDIFF', 12: 'SR', 13: 'HON', 14: 'HT', 15: 'TINR'};
const _ddNew2 = {
  0: 'SC', 1: 'POV', 2: 'PUV', 3: 'CUV', 4: 'COV', 5: 'COC', 6: 'SOCLow', 7: 'DCOT',
  8: 'CUV', 9: 'COV', 10: 'COT', 11: 'MOSOT', 12: 'CUT', 13: 'DCUT', 14: 'DCOC', 15: 'COC',
};
const _ddNew3 = {10: 'VS', 15: 'TS'};

const _eeOld1 = _ddOld2;
const _eeOld2 = {4: 'CHG', 5: 'DSG', 6: 'CHIP-E', 7: 'TEMP_E', 9: 'BAL', 10: 'HEAT'};
const _eeNew1 = {
  0: 'CUV', 1: 'COV', 2: 'COT', 3: 'MOSOT', 4: 'CUT', 5: 'DCUT', 6: 'DCOC', 7: 'COC',
  8: 'SC', 9: 'POV', 10: 'PUV', 14: 'VDIFFW', 15: 'DCOT',
};
const _eeNew2 = {4: 'CHG', 5: 'DSG', 6: 'VS', 7: 'TS', 8: 'MOS Anomaly', 9: 'BAL', 10: 'HEAT', 15: 'SOCLow'};

const Map<int, String> _statesOld = {
  0x00: 'Work end', 0x01: 'Work start', 0x02: 'Working', 0x03: 'Sleep', 0x04: 'Wake',
  0x14: 'SOC recalculated', 0x15: 'Low SOC', 0x18: 'Low temperature',
  0x33: 'Reset 51', 0x34: 'Reset 52', 0x35: 'Reset 53',
};
const Map<int, String> _statesNew = {
  0x00: 'Charge/discharge end', 0x01: 'Charge/discharge start', 0x02: 'Charging/discharging',
  0x03: 'Sleep', 0x04: 'Wake', 0x05: 'Idle', 0x06: 'Sleep 2', 0x07: 'Default', 0x08: 'Download',
  0x09: 'Clear cache', 0x14: 'SOC recalculated', 0x18: 'Low temperature',
  0x33: 'Reset 51', 0x34: 'Reset 52', 0x35: 'Reset 53', 0x36: 'Heating waiting', 0x37: 'Heating',
  0x38: 'Heating end', 0x40: 'Temperature not rising', 0x41: 'Heating timeout', 0x42: 'Heating limit reached',
};

/// Common to both log kinds.
abstract class EcoLogRecord {
  final Uint8List raw;
  EcoLogRecord(this.raw);

  EcoClockTime get bmsTime => EcoClockTime.fromBytes(raw.sublist(1, 7));

  /// Stock-app flag codes (see [kLogFlagNames]).
  List<String> get flags;

  /// Flags that indicate a problem.
  List<String> get faults => flags.where((f) => !kInformationalFlags.contains(f)).toList();

  /// Stable identity for de-duplicating overlapping downloads.
  String get key => raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// One alarm-log entry: a full pack snapshot taken when something happened.
class EcoAlarmRecord extends EcoLogRecord {
  final int cellCount;
  final bool newFirmware;
  EcoAlarmRecord(super.raw, {required this.cellCount, required this.newFirmware});

  @override
  List<String> get flags {
    final w1 = _word(raw, 7, newFirmware), w2 = _word(raw, 9, newFirmware), w3 = _word(raw, 11, newFirmware);
    return newFirmware
        ? [..._labels(w1, _ddNew1), ..._labels(w2, _ddNew2), ..._labels(w3, _ddNew3)]
        : [..._labels(w1, _ddOld1), ..._labels(w2, _ddOld2), ..._labels(w3, _ddOld3)];
  }

  int get soc => raw[13];
  double get current => _s16(raw, 14) / 10;

  List<int> get cellMillivolts => [
        for (var c = 0; c < cellCount && 17 + 2 * c < raw.length; c++) _u16(raw, 16 + 2 * c),
      ];

  List<int> get temperaturesC {
    final t0 = 16 + 2 * cellCount;
    return [
      for (var k = 0; k < 4 && t0 + 2 * k + 1 < raw.length; k++) _s16(raw, t0 + 2 * k),
    ];
  }
}

/// One running-log entry: state changes and periodic samples.
class EcoRunningRecord extends EcoLogRecord {
  final bool newFirmware;
  EcoRunningRecord(super.raw, {required this.newFirmware});

  int get stateCode => raw[7];
  String get state =>
      (newFirmware ? _statesNew : _statesOld)[stateCode] ?? 'State 0x${stateCode.toRadixString(16)}';

  bool get isStart => stateCode == 0x01;
  bool get isEnd => stateCode == 0x00;

  @override
  List<String> get flags {
    final w1 = _word(raw, 8, newFirmware), w2 = _word(raw, 10, newFirmware);
    return newFirmware
        ? [..._labels(w1, _eeNew1), ..._labels(w2, _eeNew2)]
        : [..._labels(w1, _eeOld1), ..._labels(w2, _eeOld2)];
  }

  int get soc => raw[12];
  double get voltage => _u16(raw, 13) / 10;
  double get current => _s16(raw, 15) / 10;
  double get peakCurrent => _s16(raw, 17) / 10;
  int get maxCellMv => _u16(raw, 19);
  int get minCellMv => _u16(raw, 21);
  List<int> get temperaturesC => [for (final i in [24, 26, 28]) if (i < raw.length) _s8(raw[i])];
}

List<EcoAlarmRecord> parseAlarmLog(Uint8List raw, {required int cellCount, required bool newFirmware}) => [
      for (final r in splitLogRecords(raw, EcoLogKind.alarm))
        EcoAlarmRecord(r, cellCount: cellCount, newFirmware: newFirmware),
    ];

List<EcoRunningRecord> parseRunningLog(Uint8List raw, {required bool newFirmware}) => [
      for (final r in splitLogRecords(raw, EcoLogKind.running)) EcoRunningRecord(r, newFirmware: newFirmware),
    ];
