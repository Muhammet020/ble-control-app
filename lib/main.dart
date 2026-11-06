import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const BleControlApp());

class BleControlApp extends StatelessWidget {
  const BleControlApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BLE Kontrol',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff176b5b),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff4f7f6),
    ),
    home: const BleHomePage(),
  );
}

class BleDevice {
  const BleDevice({required this.id, required this.name, required this.rssi});
  final String id;
  final String name;
  final int rssi;

  factory BleDevice.fromMap(Map<dynamic, dynamic> map) => BleDevice(
    id: map['id'] as String,
    name: map['name'] as String? ?? 'İsimsiz cihaz',
    rssi: (map['rssi'] as num?)?.toInt() ?? 0,
  );
}

class BleService {
  const BleService({required this.uuid, required this.characteristics});
  final String uuid;
  final List<Map<String, dynamic>> characteristics;

  factory BleService.fromMap(Map<dynamic, dynamic> map) => BleService(
    uuid: map['uuid'] as String,
    characteristics: (map['characteristics'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(),
  );
}

class BleHomePage extends StatefulWidget {
  const BleHomePage({super.key});

  @override
  State<BleHomePage> createState() => _BleHomePageState();
}

class _BleHomePageState extends State<BleHomePage> {
  static const _methods = MethodChannel('ble_control/methods');
  static const _events = EventChannel('ble_control/events');
  final _payload = TextEditingController();
  final _serviceUuid = TextEditingController();
  final _characteristicUuid = TextEditingController();
  final List<BleDevice> _devices = [];
  final List<BleService> _services = [];
  final List<String> _received = [];
  StreamSubscription<dynamic>? _eventSubscription;
  BleDevice? _connected;
  String _status = 'Bluetooth bağlantısı hazır';
  bool _scanning = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _eventSubscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) => _showError(error),
    );
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _payload.dispose();
    _serviceUuid.dispose();
    _characteristicUuid.dispose();
    super.dispose();
  }

  void _onEvent(dynamic raw) {
    if (!mounted || raw is! Map) return;
    final event = Map<dynamic, dynamic>.from(raw);
    switch (event['type']) {
      case 'device':
        final device = BleDevice.fromMap(event['device'] as Map);
        if (!_devices.any((item) => item.id == device.id)) {
          setState(() => _devices.add(device));
        }
      case 'connection':
        setState(() {
          final connected = event['state'] == 'connected';
          _status = connected ? 'Cihaza bağlandı' : 'Bağlantı kesildi';
          if (!connected) {
            _connected = null;
            _services.clear();
          }
        });
      case 'services':
        final list = event['services'] as List<dynamic>? ?? const [];
        setState(() {
          _services
            ..clear()
            ..addAll(list.map((item) => BleService.fromMap(item as Map)));
          _status = '${_services.length} servis keşfedildi';
        });
      case 'data':
        final values = (event['value'] as List<dynamic>? ?? const [])
            .map((item) => (item as num).toInt())
            .toList();
        final text = utf8.decode(values, allowMalformed: true);
        final hex = values
            .map((value) => value.toRadixString(16).padLeft(2, '0'))
            .join(' ');
        setState(() {
          _received.insert(0, 'HEX  $hex\nTXT  $text');
          if (_received.length > 8) _received.removeLast();
        });
      case 'error':
        setState(
          () => _status = event['message'] as String? ?? 'Bluetooth hatası',
        );
    }
  }

  Future<void> _run(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _methods.invokeMethod<Object?>(method, args);
    } on PlatformException catch (error) {
      _showError(error.message ?? error.code);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _status = error.toString());
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _run('stopScan');
      if (mounted) setState(() => _scanning = false);
      return;
    }
    try {
      final permitted =
          await _methods.invokeMethod<bool>('requestPermissions') ?? false;
      if (!permitted) {
        _showError(
          'Bluetooth izni verilmedi. Ayarlardan izin verip tekrar deneyin.',
        );
        return;
      }
    } on PlatformException catch (error) {
      _showError(error.message ?? error.code);
      return;
    }
    setState(() {
      _devices.clear();
      _scanning = true;
      _status = 'Yakındaki BLE cihazları aranıyor';
    });
    await _run('startScan');
  }

  Future<void> _connect(BleDevice device) async {
    if (_scanning) {
      await _run('stopScan');
      if (mounted) setState(() => _scanning = false);
    }
    await _run('connect', {'deviceId': device.id});
    if (mounted) {
      setState(() {
        _connected = device;
        _status = 'Bağlantı kuruluyor';
      });
      await _methods.invokeMethod<void>('discoverServices');
    }
  }

  Future<void> _send() async {
    final service = _serviceUuid.text.trim();
    final characteristic = _characteristicUuid.text.trim();
    if (service.isEmpty || characteristic.isEmpty) {
      _showError('Önce servis ve karakteristik seçin.');
      return;
    }
    await _run('write', {
      'serviceUuid': service,
      'characteristicUuid': characteristic,
      'value': utf8.encode(_payload.text),
    });
  }

  Future<void> _subscribe() async {
    await _run('subscribe', {
      'serviceUuid': _serviceUuid.text.trim(),
      'characteristicUuid': _characteristicUuid.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('BLE Kontrol'),
          Text(
            'Platform Channel Demo',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Bağlantıyı kes',
          onPressed: _connected == null ? null : () => _run('disconnect'),
          icon: const Icon(Icons.link_off),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _statusCard,
          const SizedBox(height: 16),
          _sectionHeader('Cihazlar', trailing: '${_devices.length} bulundu'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _toggleScan,
            icon: Icon(_scanning ? Icons.stop : Icons.radar),
            label: Text(_scanning ? 'Taramayı durdur' : 'Cihazları tara'),
          ),
          const SizedBox(height: 8),
          if (_devices.isEmpty)
            _emptyHint('Taramayı başlatıp yakındaki BLE cihazlarını bulun.')
          else
            ..._devices.map(_deviceTile),
          if (_connected != null) ...[
            const SizedBox(height: 20),
            _sectionHeader('Bağlı cihaz'),
            const SizedBox(height: 8),
            _connectedCard,
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run('discoverServices'),
              icon: const Icon(Icons.account_tree_outlined),
              label: const Text('Servisleri keşfet'),
            ),
            if (_services.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionHeader('Servisler ve karakteristikler'),
              const SizedBox(height: 8),
              ..._services.map(_serviceTile),
            ],
            const SizedBox(height: 20),
            _sectionHeader('Veri aktarımı'),
            const SizedBox(height: 8),
            _uuidField(_serviceUuid, 'Servis UUID'),
            const SizedBox(height: 8),
            _uuidField(_characteristicUuid, 'Karakteristik UUID'),
            const SizedBox(height: 8),
            TextField(
              controller: _payload,
              decoration: const InputDecoration(
                labelText: 'Gönderilecek metin',
                hintText: 'UTF-8 olarak gönderilir',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.send),
                    label: const Text('Veri gönder'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _subscribe,
                    icon: const Icon(Icons.sensors),
                    label: const Text('Veriyi dinle'),
                  ),
                ),
              ],
            ),
            if (_received.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionHeader('Gelen veriler'),
              const SizedBox(height: 8),
              ..._received.map(
                (line) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      line,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    ),
  );

  Widget get _statusCard => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: _connected == null
                ? Colors.amber.shade100
                : Colors.green.shade100,
            child: Icon(
              _connected == null
                  ? Icons.bluetooth_searching
                  : Icons.bluetooth_connected,
              color: _connected == null
                  ? Colors.orange.shade800
                  : Colors.green.shade800,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _connected == null ? 'Bağlantı durumu' : 'Bağlı',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(_status, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (_busy)
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    ),
  );

  Widget _sectionHeader(String title, {String? trailing}) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (trailing != null)
        Text(trailing, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Widget _emptyHint(String text) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Center(child: Text(text, textAlign: TextAlign.center)),
    ),
  );

  Widget _deviceTile(BleDevice device) => Card(
    child: ListTile(
      leading: const CircleAvatar(child: Icon(Icons.bluetooth)),
      title: Text(device.name.isEmpty ? 'İsimsiz cihaz' : device.name),
      subtitle: Text('${device.id}\nSinyal: ${device.rssi} dBm'),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: _busy ? null : () => _connect(device),
    ),
  );

  Widget get _connectedCard => Card(
    child: ListTile(
      leading: const CircleAvatar(child: Icon(Icons.bluetooth_connected)),
      title: Text(
        _connected!.name.isEmpty ? 'İsimsiz cihaz' : _connected!.name,
      ),
      subtitle: Text(_connected!.id),
      trailing: IconButton(
        tooltip: 'Bağlantıyı kes',
        onPressed: _busy ? null : () => _run('disconnect'),
        icon: const Icon(Icons.link_off),
      ),
    ),
  );

  Widget _serviceTile(BleService service) => Card(
    child: ExpansionTile(
      title: SelectableText(
        service.uuid,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: Text('${service.characteristics.length} karakteristik'),
      children: service.characteristics.map((characteristic) {
        final uuid = characteristic['uuid'] as String;
        final properties =
            (characteristic['properties'] as List<dynamic>? ?? []).join(' · ');
        return ListTile(
          dense: true,
          title: SelectableText(
            uuid,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          subtitle: Text(properties),
          onTap: () => setState(() {
            _serviceUuid.text = service.uuid;
            _characteristicUuid.text = uuid;
          }),
        );
      }).toList(),
    ),
  );

  Widget _uuidField(TextEditingController controller, String label) =>
      TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: 'Temizle',
            onPressed: controller.clear,
            icon: const Icon(Icons.clear),
          ),
        ),
      );
}
