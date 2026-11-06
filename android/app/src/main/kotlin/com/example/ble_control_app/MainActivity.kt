package com.example.ble_control_app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private var eventSink: EventChannel.EventSink? = null
    private var adapter: BluetoothAdapter? = null
    private var gatt: BluetoothGatt? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingConnectResult: MethodChannel.Result? = null
    private var pendingServicesResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methods = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ble_control/methods")
        methods.setMethodCallHandler(this)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "ble_control/events")
            .setStreamHandler(this)
        adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermissions" -> requestBlePermissions(result)
            "startScan" -> withPermission(result) {
                val bluetoothAdapter = adapter
                if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
                    result.error("bluetooth_off", "Cihaz Bluetooth kapalı veya desteklenmiyor.", null)
                    return@withPermission
                }
                val filters = (call.argument<List<String>>("serviceUuids") ?: emptyList()).map {
                    ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(it))).build()
                }
                val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
                val scanner = bluetoothAdapter.bluetoothLeScanner
                if (scanner == null) result.error("scan_unavailable", "BLE tarayıcısı kullanılamıyor.", null)
                else {
                    scanner.startScan(filters, settings, scanCallback)
                    result.success(null)
                }
            }
            "stopScan" -> withPermission(result) {
                adapter?.bluetoothLeScanner?.stopScan(scanCallback)
                result.success(null)
            }
            "connect" -> withPermission(result) {
                val id = call.argument<String>("deviceId")
                if (id == null) {
                    result.error("invalid_device", "Cihaz kimliği boş.", null)
                } else {
                    pendingConnectResult = result
                    adapter?.getRemoteDevice(id)?.connectGatt(this, false, gattCallback)
                        ?: run { pendingConnectResult = null; result.error("connect_failed", "Bağlantı başlatılamadı.", null) }
                }
            }
            "disconnect" -> withPermission(result) {
                gatt?.disconnect()
                gatt?.close()
                gatt = null
                emit(mapOf("type" to "connection", "state" to "disconnected"))
                result.success(null)
            }
            "discoverServices" -> withPermission(result) {
                if (gatt == null) result.error("not_connected", "Önce cihaza bağlanın.", null)
                else { pendingServicesResult = result; gatt?.discoverServices() }
            }
            "write" -> withPermission(result) { write(call, result) }
            "subscribe" -> withPermission(result) { subscribe(call, result) }
            else -> result.notImplemented()
        }
    }

    private fun requestBlePermissions(result: MethodChannel.Result) {
        val requested = if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else if (Build.VERSION.SDK_INT >= 23) {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        } else emptyArray()
        val missing = requested.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) result.success(true)
        else {
            pendingPermissionResult = result
            requestPermissions(missing.toTypedArray(), REQUEST_BLE_PERMISSIONS)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_BLE_PERMISSIONS) {
            val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun withPermission(result: MethodChannel.Result, action: () -> Unit) {
        if (hasBlePermission()) action()
        else result.error("permission_denied", "Bluetooth izinlerini vermek için izin isteyin.", null)
    }

    private fun hasBlePermission(): Boolean = if (Build.VERSION.SDK_INT >= 31) {
        checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    } else Build.VERSION.SDK_INT < 23 ||
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            emit(mapOf("type" to "device", "device" to mapOf(
                "id" to device.address, "name" to (device.name ?: result.scanRecord?.deviceName ?: ""),
                "rssi" to result.rssi,
            )))
        }

        override fun onScanFailed(errorCode: Int) {
            emit(mapOf("type" to "error", "message" to "BLE taraması başarısız: $errorCode"))
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(deviceGatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emit(mapOf("type" to "error", "message" to "GATT bağlantı hatası: $status"))
            }
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    gatt = deviceGatt
                    emit(mapOf("type" to "connection", "state" to "connected"))
                    pendingConnectResult?.success(true)
                    pendingConnectResult = null
                    deviceGatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    emit(mapOf("type" to "connection", "state" to "disconnected"))
                    pendingConnectResult?.error("connect_failed", "BLE bağlantısı kurulamadı.", null)
                    pendingConnectResult = null
                }
            }
        }

        override fun onServicesDiscovered(deviceGatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                pendingServicesResult?.error("service_discovery_failed", "Servis keşfi başarısız.", null)
                pendingServicesResult = null
                return
            }
            val services = deviceGatt.services.map { service -> service.toMap() }
            emit(mapOf("type" to "services", "services" to services))
            pendingServicesResult?.success(services)
            pendingServicesResult = null
        }

        override fun onCharacteristicChanged(deviceGatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            emitData(characteristic)
        }

        override fun onCharacteristicChanged(deviceGatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            emitData(characteristic, value)
        }

        override fun onCharacteristicWrite(deviceGatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            emit(mapOf("type" to "write", "success" to (status == BluetoothGatt.GATT_SUCCESS)))
        }
    }

    private fun BluetoothGattService.toMap(): Map<String, Any> = mapOf(
        "uuid" to uuid.toString(),
        "characteristics" to characteristics.map { characteristic ->
            val flags = mutableListOf<String>()
            val p = characteristic.properties
            if (p and BluetoothGattCharacteristic.PROPERTY_READ != 0) flags.add("read")
            if (p and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) flags.add("write")
            if (p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) flags.add("writeWithoutResponse")
            if (p and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) flags.add("notify")
            if (p and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) flags.add("indicate")
            mapOf("uuid" to characteristic.uuid.toString(), "properties" to flags)
        },
    )

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        val characteristic = findCharacteristic(call, result) ?: return
        val values = call.argument<List<Number>>("value") ?: emptyList()
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        characteristic.value = values.map { it.toByte() }.toByteArray()
        val accepted = gatt?.writeCharacteristic(characteristic) == true
        if (accepted) result.success(true) else result.error("write_failed", "Veri yazma işlemi başlatılamadı.", null)
    }

    private fun subscribe(call: MethodCall, result: MethodChannel.Result) {
        val characteristic = findCharacteristic(call, result) ?: return
        val active = gatt?.setCharacteristicNotification(characteristic, true) == true
        val descriptor = characteristic.getDescriptor(UUID.fromString(CLIENT_CONFIGURATION_UUID))
        if (active && descriptor != null) {
            val indication = characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
            descriptor.value = if (indication) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                else BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (gatt?.writeDescriptor(descriptor) != true) {
                result.error("subscribe_failed", "Bildirim aboneliği başlatılamadı.", null)
                return
            }
        }
        if (active) result.success(true) else result.error("subscribe_failed", "Karakteristik dinlenemiyor.", null)
    }

    private fun findCharacteristic(call: MethodCall, result: MethodChannel.Result): BluetoothGattCharacteristic? {
        val serviceId = call.argument<String>("serviceUuid")
        val characteristicId = call.argument<String>("characteristicUuid")
        val service = serviceId?.let { id -> gatt?.services?.firstOrNull { it.uuid.toString().equals(id, true) } }
        val characteristic = characteristicId?.let { id -> service?.characteristics?.firstOrNull { it.uuid.toString().equals(id, true) } }
        if (characteristic == null) result.error("characteristic_not_found", "Servis veya karakteristik bulunamadı.", null)
        return characteristic
    }

    private fun emitData(characteristic: BluetoothGattCharacteristic, data: ByteArray = characteristic.value ?: byteArrayOf()) {
        emit(mapOf("type" to "data", "serviceUuid" to characteristic.service.uuid.toString(),
            "characteristicUuid" to characteristic.uuid.toString(),
            "value" to data.map { it.toInt() and 0xff }))
    }

    private fun emit(value: Map<String, Any?>) = runOnUiThread { eventSink?.success(value) }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
    override fun onCancel(arguments: Any?) { eventSink = null }

    override fun onDestroy() {
        adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        gatt?.close()
        gatt = null
        super.onDestroy()
    }

    companion object {
        private const val REQUEST_BLE_PERMISSIONS = 7124
        private const val CLIENT_CONFIGURATION_UUID = "00002902-0000-1000-8000-00805f9b34fb"
    }
}
