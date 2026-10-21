import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bms_core/bms_core.dart';
import 'package:eco_battery_bms/eco_battery_bms.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

// Fixtures captured read-only from a real pack: LZH22-v2.9.7A-Gen2, 16S 95 Ah.
final capture = jsonDecode(File('test/fixtures/capture-1.json').readAsStringSync()) as Map<String, dynamic>;
Uint8List replyOf(String label) => Uint8List.fromList(_hex(
    (capture['reads'] as List).cast<Map<String, dynamic>>().firstWhere((r) => r['label'] == label)['reply']
        as String));
Uint8List requestOf(String label) => Uint8List.fromList(_hex(
    (capture['reads'] as List).cast<Map<String, dynamic>>().firstWhere((r) => r['label'] == label)['request']
        as String));
List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

List<int> regs(String label) {
  final f = replyOf(label);
  final chunks = [for (var i = 0; i < f.length; i += 20) f.sublist(i, i + 20 > f.length ? f.length : i + 20)];
  final a = ModbusAssembler();
  return chunks.expand(a.add).single.registers; // reassembled from 20-byte chunks
}

final alarmRaw = File('test/fixtures/alarm_log_LZH22.bin').readAsBytesSync();
final runningRaw = File('test/fixtures/running_log_LZH22.bin').readAsBytesSync();

void main() {
  test('request frames are what the stock app sends', () {
    const rtu = ModbusRtu(unitId: kUnitId);
    expect(rtu.readHolding(regVersion, regVersionCount), requestOf('version'));
    expect(rtu.readHolding(0, pollRegisterCount(16, newFirmware: false)), requestOf('live98'));
    expect(EcoLogKind.alarm.request, _hex('01dd0102030405064 8d2'.replaceAll(' ', '')));
  });

  test('version', () {
    final v = EcoVersion.fromBytes(replyOf('version').sublist(3, 23));
    expect(v.raw, 'LZH22-v2.9.7A-Gen2');
    expect(v.model, 'LZH22');
    expect(v.isNewFirmware, isFalse);
    expect(EcoVersion('EB26-v3.2.1A-G3').isNewFirmware, isTrue);
    expect(EcoVersion('EB22-v3.1.0A-Gen2').isNewFirmware, isFalse);
  });

  test('live registers decode to sane values', () {
    final s = EcoSnapshot(regs('live98'), newFirmware: false);
    expect(s.cellCount, 16);
    expect(s.nominalAh, 95.0);
    expect(s.voltage, 53.0);
    expect(s.current, 0.0);
    expect(s.soc, 73);
    expect(s.soh, 99.3);
    expect(s.cycles, 25);
    expect(s.temperaturesC, [21, 20, 21, 20]);
    expect(s.cellVoltages, hasLength(16));
    expect(s.cellVoltages.reduce((a, b) => a + b), closeTo(s.voltage, 0.15));
    expect(s.chargeMosOn, isTrue);
    expect(s.dischargeMosOn, isTrue);
    expect(s.activeProtections, isEmpty);
    expect(s.cellUnderVoltageMv, 2450);
    expect(s.cellOverVoltageMv, 3650);
    expect(s.clock, isNotNull); // 98 registers include the clock at 66..68
  });

  test('clock registers', () {
    final r = regs('rtc');
    expect(EcoClockTime.fromRegisters(r[0], r[1], r[2]).toString(), '2026-11-24 07:11:53');
    expect(EcoClockTime.registersFor(DateTime(2026, 10, 21, 10, 22, 37)), [0x1A0A, 0x150A, 0x1625]);
    expect(rtcRegister(16), 66);
  });

  test('alarm log: 37 records, length-walked', () {
    final recs = parseAlarmLog(alarmRaw, cellCount: 16, newFirmware: false);
    expect(recs, hasLength(37));
    expect(recs.first.bmsTime.toString(), '2026-11-20 23:45:26');
    final deep = recs[2];
    expect(deep.faults, ['UV']);
    expect(deep.soc, 0);
    expect(deep.current, -57.2);
    expect(deep.cellMillivolts.reduce((a, b) => a < b ? a : b), 2394);
    expect(recs.last.flags, contains('OV'));
  });

  test('running log: 600 records with states', () {
    final recs = parseRunningLog(runningRaw, newFirmware: false);
    expect(recs, hasLength(600));
    expect(recs.first.state, 'Work end');
    expect(recs[1].isStart, isTrue);
    expect(recs[3].current, -58.5);
    expect(recs.first.flags, containsAll(['CHG', 'DSG']));
    expect(recs.first.faults, isEmpty); // MOS-on flags are informational
  });

  test('entries are placed on the real timeline; unset-clock alarms are not', () {
    final reading = ClockReading(DateTime(2026, 11, 24, 7, 11, 53), DateTime(2026, 10, 21, 10, 22, 37));
    final alarms = entriesFromAlarms(parseAlarmLog(alarmRaw, cellCount: 16, newFirmware: false), reading);
    expect(alarms.first.time, DateTime(2026, 10, 18, 2, 56, 10));
    expect(alarms[2].title, 'Cell under-voltage');
    expect(alarms.where((e) => e.time == null), hasLength(17)); // the 2022 records
    final running = entriesFromRunning(parseRunningLog(runningRaw, newFirmware: false), reading);
    expect(running.every((e) => e.time != null), isTrue);
    expect(running.first.time!.isBefore(DateTime(2026, 10, 21, 10, 22)), isTrue);
    expect(running.where((e) => e.sessionStart).length, greaterThan(100));
    final keys = {...alarms.map((e) => e.key), ...running.map((e) => e.key)};
    expect(keys.length, alarms.length + running.length); // unique, for de-duplication
    final back = BatteryLogEntry.fromJson(jsonDecode(jsonEncode(running.first.toJson())));
    expect(back.toJson(), running.first.toJson());
  });

  test('driver: claims ECO names on FF00, not other FF00 devices', () {
    final d = EcoBatteryDriver();
    BleDevice dev(String n) => BleDevice(deviceId: n, name: n, rssi: -60, services: [kServiceUuid]);
    expect(d.score(dev('WO231020972022')), greaterThan(d.signature.services.length * 10));
    expect(d.score(dev('xiaoxiang')), 10); // service only: a JBD driver with the same service ties
    expect(d.describe(dev('WO231020972022')).serial, 'WO231020972022');
  });
}
