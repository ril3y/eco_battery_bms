// ECO Battery BLE identity: what its advertisements and GATT look like.

const String kServiceUuid = '0000ff00-0000-1000-8000-00805f9b34fb';
const String kNotifyUuid = '0000ff01-0000-1000-8000-00805f9b34fb';
const String kWriteUuid = '0000ff02-0000-1000-8000-00805f9b34fb';

/// Advertised names the stock app accepts (serials like `WO231020972022`).
final RegExp kEcoNamePattern = RegExp(r'^(W|LZ|EB)');

/// Modbus unit id the BMS answers on.
const int kUnitId = 0x01;
