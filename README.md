# BLE Control

A standalone Flutter app that demonstrates Android and iOS BLE communication over platform channels. The Flutter app owns scanning, connection, GATT service discovery, characteristic selection, text writes, and notification display.

## Run

```sh
flutter pub get
flutter run
```

## Platform behavior

- **Android:** Requests `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` at runtime on Android 12+, and fine location on Android 11 and earlier. BLE operations use `BluetoothLeScanner` and GATT callbacks.
- **iOS:** CoreBluetooth presents the Bluetooth permission prompt when scanning begins. The app declares `NSBluetoothAlwaysUsageDescription` in `Info.plist`.
- **BLE only:** Bluetooth Classic serial profiles such as SPP are not implemented. Android emulators may not expose BLE peripherals; use a physical phone and BLE device to validate radio behavior.

## Data flow

Native events arrive through `ble_control/events` as scan results, connection state, discovered services, and received byte arrays. Flutter sends scan, connect, disconnect, discover, subscribe, and write requests through `ble_control/methods`.

## Project layout

- `lib/main.dart` — BLE control UI and channel client
- `android/app/src/main/kotlin/.../MainActivity.kt` — Android BLE and permission bridge
- `ios/Runner/BleControlPlugin.swift` — iOS CoreBluetooth bridge
