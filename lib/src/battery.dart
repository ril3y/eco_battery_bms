// ECO Battery driver for bms_core.

import 'dart:async';
import 'dart:typed_data';

import 'package:bms_core/bms_core.dart';
import 'package:universal_ble/universal_ble.dart';

import 'clock.dart';
import 'gatt.dart';
import 'logs.dart';
import 'registers.dart';

class EcoBatteryDriver extends BatteryDriver {
  @override
  String get id => 'eco';

  @override
  String get name => 'ECO Battery';

  @override
  final BleSignature signature = BleSignature(services: [kServiceUuid], namePattern: kEcoNamePattern);

  /// ECO packs report cells, temps, SOH and cycles, keep a time-stamped
  /// on-board log, have a settable clock, and accept setting writes. Their
  /// protection history lives in the log, not in lifetime counters.
  @override
  BatteryCapabilities get capabilities => const BatteryCapabilities(
        cells: true,
        cellBalancing: true,
        temperatures: true,
        stateOfHealth: true,
        cycleCount: true,
        protectionTotals: false,
        onBoardLog: true,
        clock: true,
        settings: true,
      );

  /// The advertised name is the pack serial.
  @override
  BatteryIdentity describe(BleDevice device) => BatteryIdentity(serial: device.name);

  @override
  Battery create(BleDevice device) => EcoBattery(device, this);
}

class EcoBattery extends Battery implements HasStoredLogs {
  final BleDevice device;
  @override
  final EcoBatteryDriver driver;

  final BleLink _link;
  final ModbusRtu _rtu = const ModbusRtu(unitId: kUnitId);
  final ModbusAssembler _asm = ModbusAssembler(unitId: kUnitId);
  final _replies = StreamController<ModbusReply>.broadcast();
  final _snapshots = StreamController<BatterySnapshot>.broadcast();
  final _cells = StreamController<List<double>>.broadcast();
  StreamSubscription<Uint8List>? _rx;
  EcoLogCollector? _collector;
  Timer? _poll;

  EcoVersion? version;
  int cellCount = 0;
  EcoSnapshot? last;

  EcoBattery(this.device, this.driver)
      : _link = BleLink(device,
            service: kServiceUuid, notify: kNotifyUuid, write: kWriteUuid, writeWithResponse: true);

  @override
  String get id => 'eco-${device.deviceId}';

  @override
  String get displayName => device.name?.isNotEmpty == true ? device.name! : 'ECO Battery';

  @override
  Stream<BatterySnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<List<double>> get cellVoltages => _cells.stream;
  @override
  Stream<bool> get connection => _link.connection;

  bool get _newFw => version?.isNewFirmware ?? false;

  @override
  Future<void> connect() async {
    _rx = _link.incoming.listen((chunk) {
      final c = _collector;
      if (c != null) {
        c.add(chunk);
      } else {
        _asm.add(chunk).forEach(_replies.add);
      }
    });
    await _link.connect();
    version = EcoVersion.fromBytes(await _readBytes(regVersion, regVersionCount));
    cellCount = (await readRegisters(0, 0x50))[2];
  }

  /// One Modbus exchange: send [frame], wait for the reply to [function].
  Future<ModbusReply> _exchange(Uint8List frame, int function, {Duration timeout = const Duration(seconds: 3)}) =>
      _link.exclusive(() async {
        final reply = _replies.stream
            .firstWhere((r) => r.function == function || r.function == (function | 0x80))
            .timeout(timeout);
        await _link.write(frame);
        final r = await reply;
        if (r.isException) throw StateError('BMS refused request: Modbus exception ${r.exceptionCode}');
        return r;
      });

  Future<Uint8List> _readBytes(int address, int count) async =>
      (await _exchange(_rtu.readHolding(address, count), fnReadHolding)).data;

  Future<List<int>> readRegisters(int address, int count) async =>
      (await _exchange(_rtu.readHolding(address, count), fnReadHolding)).registers;

  Future<EcoSnapshot> readSnapshot() async {
    final regs = await readRegisters(0, pollRegisterCount(cellCount, newFirmware: _newFw));
    final s = EcoSnapshot(regs, newFirmware: _newFw);
    last = s;
    return s;
  }

  @override
  void startLive() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final s = await readSnapshot();
        _snapshots.add(_toSnapshot(s));
        _cells.add(s.cellVoltages);
      } catch (_) {
        // A missed poll is retried on the next tick.
      }
    });
  }

  @override
  void stopLive() => _poll?.cancel();

  BatterySnapshot _toSnapshot(EcoSnapshot s) => BatterySnapshot(
        time: DateTime.now(),
        voltage: s.voltage,
        current: s.current,
        soc: s.soc,
        remainingAh: s.remainingAh,
        fullAh: s.nominalAh * (s.soh > 0 ? s.soh / 100 : 1),
        cycles: s.cycles,
        temperaturesC: s.temperaturesC,
        activeProtections: s.activeProtections,
        protectionMask: s.protectionWord,
        chargeEnabled: s.chargeMosOn,
        dischargeEnabled: s.dischargeMosOn,
      );

  @override
  Future<BatteryIdentity> identify() async {
    final s = last ?? await readSnapshot();
    return BatteryIdentity(
      model: version?.model,
      firmware: version?.raw,
      serial: device.name,
      cellCount: s.cellCount,
      nominalAh: s.nominalAh,
      nominalVoltage: s.cellCount * 3.2,
      soc: s.soc,
    );
  }

  @override
  Future<HealthReport?> readHealth() async {
    final s = last ?? await readSnapshot();
    return HealthReport(
      cycles: s.cycles,
      model: version?.model,
      firmware: version?.raw,
      designAh: s.nominalAh,
      reportedSoh: s.soh > 0 ? s.soh / 100 : null,
    );
  }

  // ---------- clock ----------

  /// Clock reading taken when the logs were last downloaded.
  ClockReading? logClock;

  /// Compare the BMS clock with this device's clock.
  Future<ClockReading> readClock() async {
    final reg = rtcRegister(cellCount);
    if (reg == null) throw UnsupportedError('No clock registers known for $cellCount cells');
    final before = DateTime.now();
    final r = await readRegisters(reg, 3);
    final after = DateTime.now();
    final trusted = before.add(after.difference(before) ~/ 2);
    return ClockReading(EcoClockTime.fromRegisters(r[0], r[1], r[2]).dateTime, trusted,
        unsetBefore: DateTime(2023));
  }

  /// Write the BMS clock. This changes the battery: offer it through [notices]
  /// only, after the logs (and the old clock offset) have been captured.
  Future<void> setClock(DateTime localTime) async {
    final reg = rtcRegister(cellCount);
    if (reg == null) throw UnsupportedError('No clock registers known for $cellCount cells');
    final values = EcoClockTime.registersFor(localTime);
    for (var i = 0; i < 3; i++) {
      final frame = _rtu.writeSingle(reg + i, values[i]);
      final echo = await _exchange(frame, fnWriteSingle);
      if (!_listEquals(echo.frame, frame)) throw StateError('BMS did not confirm clock write');
    }
  }

  // ---------- logs ----------

  /// Raw download of one log (newest record first).
  Future<Uint8List> downloadRawLog(EcoLogKind kind, {Duration silence = const Duration(seconds: 15)}) =>
      _link.exclusive(() async {
        final c = EcoLogCollector(kind);
        _collector = c;
        try {
          await _link.write(kind.request);
          var lastLen = -1;
          var quiet = Duration.zero;
          const tick = Duration(milliseconds: 250);
          while (!c.complete && quiet < silence) {
            await Future<void>.delayed(tick);
            final len = c.bytes.length;
            quiet = len == lastLen ? quiet + tick : Duration.zero;
            lastLen = len;
          }
          return c.bytes;
        } finally {
          _collector = null;
          _asm.clear();
        }
      });

  @override
  Future<List<BatteryLogEntry>> downloadLogs({void Function(double)? onProgress}) async {
    final wasLive = _poll?.isActive ?? false;
    stopLive();
    try {
      final reading = await readClock();
      logClock = reading;
      onProgress?.call(0.1);
      final alarms = parseAlarmLog(await downloadRawLog(EcoLogKind.alarm), cellCount: cellCount, newFirmware: _newFw);
      onProgress?.call(0.4);
      final running = parseRunningLog(await downloadRawLog(EcoLogKind.running), newFirmware: _newFw);
      onProgress?.call(1);
      return [
        ...entriesFromAlarms(alarms, reading),
        ...entriesFromRunning(running, reading),
      ];
    } finally {
      if (wasLive) startLive();
    }
  }

  // ---------- notices ----------

  /// A wrong BMS clock means wrong log dates. Offered only once the logs have
  /// been downloaded with the old offset recorded, so nothing is lost by fixing it.
  @override
  Future<List<BatteryNotice>> notices() async {
    final logged = logClock;
    if (logged == null) return const [];
    final now = await readClock();
    if (!now.isWrong()) return const [];
    return [
      BatteryNotice(
        id: 'eco.clock',
        severity: NoticeSeverity.warning,
        title: now.isUnset ? 'Battery clock isn\'t set' : 'Battery clock is ${describeOffset(now.offset!)}',
        message: now.isUnset
            ? 'The battery lost track of the date, so it stamps its own log with the wrong time. '
                'Set it to this device\'s time so future entries are dated correctly.'
            : 'The battery says ${_fmt(now.bms!)}, this device says ${_fmt(now.trusted)}. '
                'Setting it dates future log entries correctly. History already downloaded keeps its '
                'corrected dates.',
        actions: [
          BatteryAction(
            label: 'Set battery clock',
            changesBattery: true,
            run: () async {
              await setClock(DateTime.now());
              final check = await readClock();
              if (check.isWrong()) throw StateError('The battery didn\'t keep the new time');
              return 'Battery clock set';
            },
          ),
        ],
      ),
    ];
  }

  static String _fmt(DateTime t) =>
      '${t.year}-${_pad2(t.month)}-${_pad2(t.day)} ${_pad2(t.hour)}:${_pad2(t.minute)}';
  static String _pad2(int v) => v.toString().padLeft(2, '0');

  @override
  Future<void> disconnect() async {
    stopLive();
    await _rx?.cancel();
    await _link.disconnect();
  }
}

/// "33 days fast", "4 minutes slow", …
String describeOffset(Duration d) {
  final a = d.abs();
  final dir = d.isNegative ? 'slow' : 'fast';
  if (a.inDays >= 2) return '${a.inDays} days $dir';
  if (a.inHours >= 2) return '${a.inHours} hours $dir';
  return '${a.inMinutes} minutes $dir';
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _readable(String code) => kLogFlagNames[code] ?? code;

/// Alarm-log records as brand-neutral entries on the real timeline.
List<BatteryLogEntry> entriesFromAlarms(List<EcoAlarmRecord> newestFirst, ClockReading reading) => [
      for (final p in placeOnTimeline(newestFirst, (r) => r.bmsTime.dateTime, reading))
        () {
          final r = p.record;
          final faults = r.faults.map(_readable).toSet().toList();
          final cells = r.cellMillivolts;
          return BatteryLogEntry(
            key: 'eco-alarm:${r.key}',
            kind: BatteryLogKind.alarm,
            title: faults.isEmpty ? 'Status snapshot' : faults.join(', '),
            time: p.time,
            bmsTime: r.bmsTime.dateTime,
            before: p.before,
            faults: faults,
            soc: r.soc,
            current: r.current,
            minCellMv: cells.isEmpty ? null : cells.reduce((a, b) => a < b ? a : b),
            maxCellMv: cells.isEmpty ? null : cells.reduce((a, b) => a > b ? a : b),
            temperaturesC: r.temperaturesC,
          );
        }(),
    ];

/// Running-log records as brand-neutral entries on the real timeline.
List<BatteryLogEntry> entriesFromRunning(List<EcoRunningRecord> newestFirst, ClockReading reading) => [
      for (final p in placeOnTimeline(newestFirst, (r) => r.bmsTime.dateTime, reading))
        BatteryLogEntry(
          key: 'eco-run:${p.record.key}',
          kind: BatteryLogKind.state,
          title: p.record.state,
          time: p.time,
          bmsTime: p.record.bmsTime.dateTime,
          before: p.before,
          faults: p.record.faults.map(_readable).toSet().toList(),
          soc: p.record.soc,
          voltage: p.record.voltage,
          current: p.record.current,
          peakCurrent: p.record.peakCurrent,
          minCellMv: p.record.minCellMv,
          maxCellMv: p.record.maxCellMv,
          temperaturesC: p.record.temperaturesC,
          sessionStart: p.record.isStart,
          sessionEnd: p.record.isEnd,
        ),
    ];
