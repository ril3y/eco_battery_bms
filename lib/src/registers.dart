// Register map and decoding for ECO Battery BMS live data.
// Layout is fixed for registers 1..32; cell voltages start at 33.

int _s16(int v) => v >= 0x8000 ? v - 0x10000 : v;

/// Bit at [index] of a 16-bit word, counted MSB-first (index 0 = bit 15),
/// which is how the stock app labels these words.
bool msbBit(int word, int index) => (word >> (15 - index)) & 1 == 1;

const int regVersion = 0x04B0;
const int regVersionCount = 10;

/// Firmware identity read from 10 registers at 0x04B0, e.g. `LZH22-v2.9.7A-Gen2`.
class EcoVersion {
  final String raw;
  EcoVersion(this.raw);

  factory EcoVersion.fromBytes(List<int> data) =>
      EcoVersion(String.fromCharCodes(data.where((b) => b >= 0x20 && b < 0x7F)).trim());

  bool get isEcoFirmware => raw.contains('EB') || raw.contains('LZH');

  /// Newer firmware (the stock app's `versionNoYX`): v3.2+ or any Gen3 ("-G3").
  /// It reads longer register blocks and uses different bit layouts.
  bool get isNewFirmware {
    if (raw.contains('-G3')) return true;
    final m = RegExp(r'v3\.(\d)').firstMatch(raw);
    return m != null && int.parse(m.group(1)!) >= 2;
  }

  /// Model family prefix, e.g. `LZH22` or `EB22`.
  String get model => raw.split('-').first;

  @override
  String toString() => raw;
}

/// Registers to poll from address 0, per cell count (from the stock app).
int pollRegisterCount(int cells, {required bool newFirmware}) => switch (cells) {
      8 => 0x58,
      12 => newFirmware ? 0x76 : 0x5C,
      16 => newFirmware ? 0x7A : 0x62,
      22 => newFirmware ? 0x80 : 0x66,
      24 => 0x68,
      _ => 0x50,
    };

/// First of the three clock registers (YY|MM, DD|hh, mm|ss), per cell count.
int? rtcRegister(int cells) => switch (cells) {
      8 => 58,
      12 => 62,
      16 => 66,
      22 => 72,
      24 => 74,
      _ => null,
    };

/// Older firmware protection word, MSB-first index -> label.
const List<String> kProtectionLabelsOld = [
  'Cell under-voltage', 'Cell over-voltage', 'Charge over-temp', 'MOS over-temp',
  'Charge under-temp', 'Discharge under-temp', 'Discharge over-current', 'Charge over-current',
  'Short circuit', 'Pack over-voltage', 'Pack under-voltage', 'Secondary under-voltage',
  'Secondary over-voltage', 'Secondary over-current', 'Reserved', 'Discharge over-temp',
];

/// Newer firmware protection word: MSB-first index -> label.
const Map<int, String> kProtectionLabelsNew = {
  0: 'Cell under-voltage', 1: 'Cell over-voltage', 2: 'Charge over-temp', 3: 'MOS over-temp',
  4: 'Charge under-temp', 5: 'Discharge under-temp', 6: 'Discharge over-current', 7: 'Charge over-current',
  8: 'Short circuit', 9: 'Pack over-voltage', 10: 'Pack under-voltage', 14: 'Cell difference too high',
  15: 'Discharge over-temp',
};

/// Newer firmware status-word faults: MSB-first index -> label.
const Map<int, String> kStatusFaultsNew = {8: 'MOS fault', 6: 'Voltage sensor fault', 7: 'Temperature sensor fault'};

/// Older firmware status-word faults.
const Map<int, String> kStatusFaultsOld = {6: 'BMS chip error', 7: 'Temperature sensor error'};

const int kNoSensor = 0x03E8;

/// One live reading decoded from a register block read from address 0.
class EcoSnapshot {
  final List<int> registers;
  final bool newFirmware;

  EcoSnapshot(this.registers, {required this.newFirmware});

  int _r(int i) => i < registers.length ? registers[i] : 0;

  double get nominalAh => _r(1) / 10;
  int get cellCount => _r(2);
  double get voltage => _r(3) / 10;
  double get current => _s16(_r(4)) / 10;
  int get soc => _r(5);
  double get soh => _r(6) / 10;
  int get cycles => _r(7);
  int get protectionWord => _r(8);
  int get statusWord => _r(9);

  int get cellUnderVoltageMv => _r(10);
  int get cellOverVoltageMv => _r(11);

  /// Present temperature sensors in °C (slots reporting 0x03E8 are absent).
  List<double> get temperaturesC => [
        for (var i = 22; i <= 27; i++)
          if (_r(i) != kNoSensor) _s16(_r(i)).toDouble(),
      ];

  /// Cell voltages in volts (registers 33 .. 32+cells).
  List<double> get cellVoltages => [
        for (var i = 0; i < cellCount && 33 + i < registers.length; i++) _r(33 + i) / 1000,
      ];

  /// Remaining capacity estimated from SOC (the BMS doesn't report Ah left).
  double get remainingAh => nominalAh * soc / 100;

  bool get chargeMosOn => msbBit(statusWord, 4);
  bool get dischargeMosOn => msbBit(statusWord, 5);
  bool get balancing => msbBit(statusWord, 9);
  bool get heating => newFirmware && msbBit(statusWord, 10);

  List<String> get activeProtections {
    final out = <String>[];
    if (newFirmware) {
      kProtectionLabelsNew.forEach((i, l) {
        if (msbBit(protectionWord, i)) out.add(l);
      });
      kStatusFaultsNew.forEach((i, l) {
        if (msbBit(statusWord, i)) out.add(l);
      });
    } else {
      for (var i = 0; i < 16; i++) {
        if (i != 14 && msbBit(protectionWord, i)) out.add(kProtectionLabelsOld[i]);
      }
      kStatusFaultsOld.forEach((i, l) {
        if (msbBit(statusWord, i)) out.add(l);
      });
    }
    return out;
  }

  /// The BMS clock, if this block includes the clock registers.
  EcoClockTime? get clock {
    final r = rtcRegister(cellCount);
    if (r == null || r + 2 >= registers.length) return null;
    return EcoClockTime.fromRegisters(_r(r), _r(r + 1), _r(r + 2));
  }
}

/// A BMS timestamp as stored (year 2000+, local time of whoever last set it).
class EcoClockTime {
  final int year, month, day, hour, minute, second;

  const EcoClockTime(this.year, this.month, this.day, this.hour, this.minute, this.second);

  factory EcoClockTime.fromRegisters(int yymm, int ddhh, int mmss) =>
      EcoClockTime(2000 + (yymm >> 8), yymm & 0xFF, ddhh >> 8, ddhh & 0xFF, mmss >> 8, mmss & 0xFF);

  factory EcoClockTime.fromBytes(List<int> b) => EcoClockTime(2000 + b[0], b[1], b[2], b[3], b[4], b[5]);

  bool get isValid =>
      month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour < 24 && minute < 60 && second < 60;

  /// As a naive local DateTime, or null if the fields are out of range.
  DateTime? get dateTime => isValid ? DateTime(year, month, day, hour, minute, second) : null;

  /// The BMS falls back to 2022-01-01 after losing power; times this early mean "never set".
  bool get looksUnset => year < 2023;

  /// Register values to write: YY|MM, DD|hh, mm|ss.
  static List<int> registersFor(DateTime t) =>
      [((t.year - 2000) << 8) | t.month, (t.day << 8) | t.hour, (t.minute << 8) | t.second];

  @override
  String toString() =>
      '$year-${_pad2(month)}-${_pad2(day)} ${_pad2(hour)}:${_pad2(minute)}:${_pad2(second)}';

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  @override
  bool operator ==(Object other) =>
      other is EcoClockTime && other.year == year && other.month == month && other.day == day &&
      other.hour == hour && other.minute == minute && other.second == second;

  @override
  int get hashCode => Object.hash(year, month, day, hour, minute, second);
}
