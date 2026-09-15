import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:csv/csv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const LWDApp());

class LWDApp extends StatelessWidget {
  const LWDApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LWD PRO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF0A192F),
        scaffoldBackgroundColor: const Color(0xFF0A192F),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothConnection? _connection;
  StreamSubscription<Uint8List>? _btSub;
  List<BluetoothDevice> _devices = [];
  bool _isConnected = false;
  String _status = "Disconnected";

  double _evd = 0;
  double _deflection = 0;
  double _latitude = 0;
  double _longitude = 0;
  int _testCount = 0;
  final List<double> _waveform = List.filled(30, 0.0);

  double _calFactor = 1.0;
  String _calDate = 'Never';
  final String _password = 'admin123';
  late SharedPreferences _prefs;

  final List<List<dynamic>> _csvData = [
    ["Test #", "Time", "Evd (MN/m2)", "Def (mm)", "Lat", "Lng"]
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await [Permission.location, Permission.bluetooth, Permission.bluetoothConnect].request();
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _calFactor = _prefs.getDouble('cal') ?? 1.0;
      _calDate = _prefs.getString('calDate') ?? 'Never';
    });
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      setState(() => _devices = devices);
    } catch (e) {
      print('Error loading devices: $e');
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _status = "Connecting...");
    try {
      _connection = await BluetoothConnection.toAddress(device.address);
      setState(() {
        _isConnected = true;
        _status = "Online";
      });
      _btSub = _connection!.input!.listen((data) {
        final text = ascii.decode(data, allowInvalid: true);
        _parse(text);
      }, onDone: _disconnect);
    } catch (e) {
      setState(() {
        _isConnected = false;
        _status = "Failed: $e";
      });
    }
  }

  void _disconnect() {
    _btSub?.cancel();
    _connection?.close();
    setState(() {
      _isConnected = false;
      _status = "Disconnected";
    });
  }

  void _parse(String raw) {
    try {
      double? evd;
      double? def;
      for (final part in raw.trim().split(',')) {
        final kv = part.split('=');
        if (kv.length == 2) {
          final key = kv[0].trim();
          final val = double.tryParse(kv[1].trim());
          if (key == 'evd') evd = val;
          if (key == 'def') def = val;
        }
      }
      if (evd == null && def == null) return;

      final calibratedEvd = (evd ?? 0) * _calFactor;
      setState(() {
        if (evd != null) _evd = calibratedEvd;
        if (def != null) {
          _deflection = def;
          _waveform.add(def);
          if (_waveform.length > 30) _waveform.removeAt(0);
        }
      });

      if (calibratedEvd > 0.5) {
        _logTest(calibratedEvd, def ?? 0);
      }
    } catch (e) {
      print('Parse error: $e');
    }
  }

  Future<void> _logTest(double evd, double def) async {
    double lat = _latitude;
    double lng = _longitude;
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 3),
      );
      lat = pos.latitude;
      lng = pos.longitude;
      _latitude = lat;
      _longitude = lng;
    } catch (_) {}
    setState(() {
      _testCount++;
      _csvData.add([
        _testCount,
        DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
        evd.toStringAsFixed(1),
        def.toStringAsFixed(3),
        lat.toStringAsFixed(6),
        lng.toStringAsFixed(6),
      ]);
    });
  }

  Future<void> _exportCsv() async {
    final csv = const ListToCsvConverter().convert(_csvData);
    try {
      final path = "/storage/emulated/0/Download/LWD_${DateTime.now().millisecondsSinceEpoch}.csv";
      await File(path).writeAsString(csv);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to Downloads!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _saveCal(double factor) async {
    await _prefs.setDouble('cal', factor);
    await _prefs.setString('calDate', DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()));
    setState(() {
      _calFactor = factor;
      _calDate = _prefs.getString('calDate')!;
    });
  }

  void _showDeviceList() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select HC-05 Device'),
        content: SizedBox(
          width: double.maxFinite,
          child: _devices.isEmpty
              ? const Text('No paired devices. Pair HC-05 in phone Bluetooth settings first.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _devices.length,
                  itemBuilder: (c, i) => ListTile(
                    title: Text(_devices[i].name ?? 'Unknown'),
                    subtitle: Text(_devices[i].address),
                    onTap: () {
                      Navigator.pop(ctx);
                      _connect(_devices[i]);
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _loadDevices();
              Navigator.pop(ctx);
            },
            child: const Text('Refresh'),
          ),
        ],
      ),
    );
  }

  void _showCalDialog() {
    final pass = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Calibration - Enter Password'),
        content: TextField(
          controller: pass,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Password'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (pass.text == _password) {
                Navigator.pop(ctx);
                _showCalEditor();
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showCalEditor() {
    final factor = TextEditingController(text: _calFactor.toStringAsFixed(3));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Calibration Factor'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: factor,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Multiplier'),
            ),
            const SizedBox(height: 8),
            Text('Last: $_calDate', style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final v = double.tryParse(factor.text);
              if (v != null && v > 0) {
                _saveCal(v);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final passed = _evd >= 40;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A192F),
        title: const Text('LWD PRO', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock, color: Colors.amber),
            onPressed: _showCalDialog,
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isConnected ? Colors.green.shade900 : Colors.red.shade900,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_status, style: const TextStyle(fontSize: 10)),
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth),
            onPressed: _isConnected ? null : _showDeviceList,
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            onPressed: _isConnected ? _disconnect : null,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF112240), Color(0xFF1A365D)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('EVD', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          Text('${_evd.toStringAsFixed(1)}',
                              style: const TextStyle(
                                fontSize: 44, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF),
                              )),
                          const Text('MN/m²', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text('DEFLECTION', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          Text('${_deflection.toStringAsFixed(3)}',
                              style: const TextStyle(
                                fontSize: 28, fontWeight: FontWeight.bold, color: Colors.orangeAccent,
                              )),
                          const Text('mm', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: passed ? Colors.green.shade900 : Colors.red.shade900,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(passed ? 'PASS' : 'FAIL',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: (_evd / 80).clamp(0.0, 1.0),
                          minHeight: 8,
                          backgroundColor: Colors.grey.shade800,
                          valueColor: AlwaysStoppedAnimation(
                            passed ? Colors.green : Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _latitude != 0
                            ? '${_latitude.toStringAsFixed(4)}, ${_longitude.toStringAsFixed(4)}'
                            : 'No GPS',
                        style: const TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                      Text('#$_testCount', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF112240),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: LineChart(
                  LineChartData(
                    gridData: const FlGridData(show: true, drawVerticalLine: false),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    minX: 0,
                    maxX: 30,
                    minY: -0.2,
                    maxY: 2.0,
                    lineBarsData: [
                      LineChartBarData(
                        spots: _waveform.asMap().entries.map(
                              (e) => FlSpot(e.key.toDouble(), e.value),
                            ).toList(),
                        isCurved: true,
                        color: const Color(0xFF00E5FF),
                        barWidth: 2,
                        belowBarData: BarAreaData(
                          show: true,
                          color: const Color(0xFF00E5FF).withOpacity(0.1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _exportCsv,
                    icon: const Icon(Icons.save),
                    label: const Text('EXPORT CSV'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A365D),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _waveform.fillRange(0, _waveform.length, 0.0);
                        _evd = 0;
                        _deflection = 0;
                      });
                    },
                    icon: const Icon(Icons.clear),
                    label: const Text('CLEAR'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade900,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}