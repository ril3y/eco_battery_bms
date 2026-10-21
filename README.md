# eco_battery_bms

ECO Battery (EB / LZH family) BMS driver for [bms_core](https://github.com/ril3y/bms_core).

These packs speak **Modbus RTU over BLE** (service FF00, notify FF01, write FF02):

- Live register map decode: voltage, current, SOC, SOH, cycles, per-cell voltages,
  up to 6 temperature sensors, protection/status flags — for 8/12/16/22/24-cell packs.
- On-board **alarm** and **running** logs downloaded and parsed into `BatteryLogEntry`.
- BMS **clock** handling: these boards have no time-zone and drift (often an internal
  RC source), and reset to a default date on power loss, so log timestamps are placed
  on the real timeline per *clock period* and corrected only where it's safe.

Test fixtures under `test/fixtures/` are captured read-only from real hardware
(`LZH22-v2.9.7A`, 16S 51.2 V), with the device identifier redacted.

Read-only by default; the clock write is offered through a `BatteryNotice`, never automatic.

## License

MIT. Reverse-engineered for interoperability; not affiliated with ECO Battery / Eco Capital.
