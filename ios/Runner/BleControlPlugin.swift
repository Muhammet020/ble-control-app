import CoreBluetooth
import Flutter
import Foundation

final class BleControlPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
  private var central: CBCentralManager!
  private var sink: FlutterEventSink?
  private var peripherals: [String: CBPeripheral] = [:]
  private var activePeripheral: CBPeripheral?
  private var connectResult: FlutterResult?
  private var servicesResult: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BleControlPlugin()
    let methods = FlutterMethodChannel(name: "ble_control/methods", binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: "ble_control/events", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
    instance.central = CBCentralManager(delegate: instance, queue: .main)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermissions": result(true) // iOS displays its Bluetooth prompt when scanning starts.
    case "startScan":
      let args = call.arguments as? [String: Any] ?? [:]
      let ids = (args["serviceUuids"] as? [String] ?? []).map(CBUUID.init(string:))
      central.scanForPeripherals(withServices: ids.isEmpty ? nil : ids, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
      result(nil)
    case "stopScan": central.stopScan(); result(nil)
    case "connect":
      guard let args = call.arguments as? [String: Any], let id = args["deviceId"] as? String,
            let peripheral = peripherals[id] else {
        result(FlutterError(code: "device_not_found", message: "Önce tarama yapıp bir cihaz seçin.", details: nil)); return
      }
      activePeripheral = peripheral
      peripheral.delegate = self
      connectResult = result
      central.connect(peripheral, options: nil)
    case "disconnect":
      if let peripheral = activePeripheral { central.cancelPeripheralConnection(peripheral) }
      activePeripheral = nil
      result(nil)
    case "discoverServices":
      guard let peripheral = activePeripheral else {
        result(FlutterError(code: "not_connected", message: "Önce cihaza bağlanın.", details: nil)); return
      }
      servicesResult = result
      peripheral.discoverServices(nil)
    case "write", "subscribe": performCharacteristicOperation(call, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func performCharacteristicOperation(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let peripheral = activePeripheral,
          let args = call.arguments as? [String: Any],
          let serviceId = args["serviceUuid"] as? String,
          let characteristicId = args["characteristicUuid"] as? String,
          let characteristic = peripheral.services?.first(where: { $0.uuid.uuidString.caseInsensitiveCompare(serviceId) == .orderedSame })?
            .characteristics?.first(where: { $0.uuid.uuidString.caseInsensitiveCompare(characteristicId) == .orderedSame }) else {
      result(FlutterError(code: "characteristic_not_found", message: "Servis veya karakteristik bulunamadı.", details: nil)); return
    }
    if call.method == "subscribe" {
      peripheral.setNotifyValue(true, for: characteristic)
      result(nil)
    } else {
      let bytes = (args["value"] as? [NSNumber] ?? []).map { UInt8(truncating: $0) }
      let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
      peripheral.writeValue(Data(bytes), for: characteristic, type: type)
      result(nil)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .poweredOn {
      emit(["type": "error", "message": "Bluetooth kullanılamıyor (durum: \(central.state.rawValue))."])
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let id = peripheral.identifier.uuidString
    peripherals[id] = peripheral
    emit(["type": "device", "device": ["id": id, "name": peripheral.name ?? "", "rssi": RSSI]])
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    activePeripheral = peripheral
    peripheral.delegate = self
    connectResult?(true)
    connectResult = nil
    emit(["type": "connection", "state": "connected"])
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    connectResult?(FlutterError(code: "connect_failed", message: error?.localizedDescription ?? "Bağlantı kurulamadı.", details: nil))
    connectResult = nil
    emit(["type": "error", "message": error?.localizedDescription ?? "Bağlantı kurulamadı."])
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    emit(["type": "connection", "state": "disconnected"])
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil else {
      servicesResult?(FlutterError(code: "service_discovery_failed", message: error?.localizedDescription, details: nil))
      servicesResult = nil
      return
    }
    for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    if (peripheral.services ?? []).isEmpty { publishServices(peripheral) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if error != nil { return }
    let complete = (peripheral.services ?? []).allSatisfy { $0.characteristics != nil }
    if complete { publishServices(peripheral) }
  }

  private func publishServices(_ peripheral: CBPeripheral) {
    let services = (peripheral.services ?? []).map { service -> [String: Any] in
      let characteristics = (service.characteristics ?? []).map { characteristic -> [String: Any] in
        var properties: [String] = []
        if characteristic.properties.contains(.read) { properties.append("read") }
        if characteristic.properties.contains(.write) { properties.append("write") }
        if characteristic.properties.contains(.writeWithoutResponse) { properties.append("writeWithoutResponse") }
        if characteristic.properties.contains(.notify) { properties.append("notify") }
        if characteristic.properties.contains(.indicate) { properties.append("indicate") }
        return ["uuid": characteristic.uuid.uuidString, "properties": properties]
      }
      return ["uuid": service.uuid.uuidString, "characteristics": characteristics]
    }
    emit(["type": "services", "services": services])
    servicesResult?(services)
    servicesResult = nil
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard error == nil, let value = characteristic.value else { return }
    emit(["type": "data", "serviceUuid": characteristic.service?.uuid.uuidString ?? "",
          "characteristicUuid": characteristic.uuid.uuidString, "value": [UInt8](value).map(Int.init)])
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    emit(["type": "write", "success": error == nil])
  }

  private func emit(_ event: [String: Any]) { sink?(event) }
}
