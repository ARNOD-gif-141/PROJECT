// Arno Link v4 - web control + Bluetooth control + music + AI + OTA + Add More for the ARNO OS Desk Buddy.  By- Arnod
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

const svcUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const rxUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
const txUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
const native = MethodChannel('arno/native');
const notifChannel = EventChannel('arno/notifs');

const mediaPkgs = {
  'com.spotify.music', 'com.google.android.youtube', 'com.google.android.apps.youtube.music', 'com.vanced.android.youtube',
  'org.videolan.vlc', 'com.amazon.mp3', 'com.apple.android.music', 'in.startv.hotstar', 'com.netflix.mediaclient',
  'com.jio.media.jiobeats', 'com.gaana', 'com.mxtech.videoplayer.ad', 'com.soundcloud.android', 'deezer.android.app',
  'com.google.android.music', 'com.miui.player', 'com.sec.android.app.music', 'com.audiomack', 'com.heytap.music',
};
const skipPkgs = {'android', 'com.android.systemui', 'com.android.providers.downloads', 'com.google.android.gms', 'com.arnod.arno_link'};

String appName(String pkg) {
  const known = {
    'com.whatsapp': 'WhatsApp', 'com.whatsapp.w4b': 'WhatsApp Biz', 'com.instagram.android': 'Instagram', 'org.telegram.messenger': 'Telegram',
    'com.google.android.gm': 'Gmail', 'com.google.android.apps.messaging': 'Messages', 'com.samsung.android.messaging': 'Messages',
    'com.google.android.dialer': 'Phone', 'com.android.phone': 'Phone', 'com.truecaller': 'Truecaller', 'com.facebook.orca': 'Messenger',
    'com.twitter.android': 'X', 'com.snapchat.android': 'Snapchat', 'com.discord': 'Discord', 'com.spotify.music': 'Spotify',
    'com.google.android.youtube': 'YouTube', 'com.google.android.apps.youtube.music': 'YT Music',
  };
  if (known.containsKey(pkg)) return known[pkg]!;
  final n = pkg.split('.').last;
  return n.isEmpty ? pkg : n[0].toUpperCase() + n.substring(1);
}

class Link extends ChangeNotifier {
  late SharedPreferences prefs;
  BluetoothDevice? dev;
  BluetoothCharacteristic? rx, tx;
  StreamSubscription? _stateSub, _valSub, _scanSub, _notifSub;
  bool connected = false, connecting = false, userStopped = false, fwd = true, listenerOn = false;
  String status = 'Not connected', phoneName = 'Phone', musicTitle = '', musicApp = '', lastMsg = '';
  final Map<String, String> info = {};
  final List<List<String>> aiLog = [];   // [question, answer]
  String host = '192.168.4.1';
  String _buf = '';
  Future<void> _chain = Future.value();
  int _retry = 0, sentCount = 0;
  Timer? _retryTimer;
  final Map<String, int> _recent = {};
  final List<String> _fwdQ = [];
  bool _fwdBusy = false;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    fwd = prefs.getBool('fwd') ?? true;
    host = prefs.getString('host') ?? '192.168.4.1';
    await _perms();
    try { phoneName = await FlutterBluePlus.adapterName; } catch (_) {}
    if (phoneName.isEmpty) phoneName = 'Phone';
    await checkListener();
    _notifSub = notifChannel.receiveBroadcastStream().listen(_onNotif, onError: (_) {});
    notifyListeners();
    connect();
  }

  Future<void> _perms() async {
    try { await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.notification].request(); } catch (_) {}
  }
  Future<void> checkListener() async {
    try { listenerOn = (await native.invokeMethod('listenerEnabled')) == true; } catch (_) { listenerOn = false; }
    notifyListeners();
  }
  Future<bool> openApp(String n) async { try { return (await native.invokeMethod('openApp', {'name': n})) == true; } catch (_) { return false; } }
  bool finding = false; Timer? _findT;
  Future<void> findStart() async { finding = true; notifyListeners(); try { await native.invokeMethod('findStart'); } catch (_) {} _findT?.cancel(); _findT = Timer(const Duration(seconds: 90), findStop); }
  Future<void> findStop() async { finding = false; _findT?.cancel(); notifyListeners(); try { await native.invokeMethod('findStop'); } catch (_) {} if (connected) send('FIND|0'); }
  Future<void> openOverlaySettings() async { try { await native.invokeMethod('openOverlay'); } catch (_) {} }
  Future<String> usePhoneLocation() async {
    try {
      await Permission.locationWhenInUse.request();
      final r = await native.invokeMethod('getLocation');
      if (r == null) return 'No recent location. Open Google Maps for a moment, then try again.';
      final p = (r as String).split('|');
      final name = p.length > 2 && p[2].trim().isNotEmpty ? p[2].trim() : 'My location';
      send('WL|${p[0]}|${p[1]}|$name');
      return 'Weather place set to $name';
    } catch (e) { return 'Location failed: $e'; }
  }
  Future<void> openListenerSettings() async { try { await native.invokeMethod('openListener'); } catch (_) {} }
  Future<void> openWeb() async { try { await native.invokeMethod('openUrl', {'url': 'http://$host'}); } catch (_) {} }
  Future<void> bindWifi(bool on) async { try { await native.invokeMethod('bindWifi', {'on': on}); } catch (_) {} }
  Future<void> setHost(String h) async { host = h.trim().isEmpty ? '192.168.4.1' : h.trim(); await prefs.setString('host', host); notifyListeners(); }
  void ask(String q) { aiLog.add([q, '...']); if (aiLog.length > 30) aiLog.removeAt(0); send('Q|' + q.replaceAll('|', '/').replaceAll('\n', ' ')); notifyListeners(); }
  // OTA: the Desk Buddy opens WiFi "OTA-UPDATE" (pass OTA1234), shows its OTA screen, receives the file, restarts and the network closes.
  Future<String> ota(String path, void Function(String) say) async {
    const base = 'http://192.168.4.1';
    try {
      final size = await File(path).length();
      say('Asking the Desk Buddy to open OTA-UPDATE...');
      send('OTA');
      await Future.delayed(const Duration(seconds: 4));
      say('Joining WiFi OTA-UPDATE - approve the phone popup (password OTA1234)');
      var joined = false;
      try { joined = (await native.invokeMethod('joinWifi', {'ssid': 'OTA-UPDATE', 'pass': 'OTA1234'})) == true; } catch (_) {}
      if (!joined) { say('Join WiFi "OTA-UPDATE" (password OTA1234) in your phone WiFi settings now...'); await bindWifi(true); }
      var reach = false;
      for (var i = 0; i < 12 && !reach; i++) {
        try { final r = await http.get(Uri.parse('$base/ping')).timeout(const Duration(seconds: 3)); reach = r.statusCode == 200; } catch (_) {}
        if (!reach) await Future.delayed(const Duration(seconds: 3));
      }
      if (!reach) return 'Could not reach the Desk Buddy on OTA-UPDATE. Try again.';
      say('Uploading ${(size / 1024).round()} KB - watch the Desk Buddy screen...');
      final req = http.MultipartRequest('POST', Uri.parse('$base/update?size=$size'));
      req.headers['Authorization'] = 'Basic ' + base64Encode(utf8.encode('arno:Arnod1702'));
      req.files.add(await http.MultipartFile.fromPath('fw', path, filename: 'ARNO_OS_update.bin'));
      final r = await req.send().timeout(const Duration(minutes: 5));
      final body = await r.stream.bytesToString();
      return r.statusCode == 200 && body.contains('OK') ? 'Done! The Desk Buddy restarts now and the OTA-UPDATE WiFi closes.' : 'Failed (${r.statusCode}) $body';
    } catch (e) {
      return 'Failed: $e';
    } finally { await bindWifi(false); }
  }
  void refresh() => notifyListeners();
  void _setStatus(String s) { status = s; notifyListeners(); }

  // ---- connection: own reconnect loop, works every time (no need to delete the phone's Bluetooth history)
  Future<void> connect() async {
    if (connecting || connected) return;
    userStopped = false; connecting = true; _retryTimer?.cancel();
    _setStatus('Looking for Desk Buddy...');
    try {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        try { await FlutterBluePlus.turnOn(); } catch (_) {}
        await Future.delayed(const Duration(seconds: 1));
      }
      BluetoothDevice? found;
      final lastId = prefs.getString('lastId');
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((rs) {
        for (final r in rs) {
          final n = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
          if (n.startsWith('ARNO') || r.advertisementData.serviceUuids.contains(Guid(svcUuid))) found ??= r.device;
        }
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      for (var i = 0; i < 90 && found == null && FlutterBluePlus.isScanningNow; i++) { await Future.delayed(const Duration(milliseconds: 100)); }
      try { await FlutterBluePlus.stopScan(); } catch (_) {}
      await _scanSub?.cancel();
      found ??= lastId != null ? BluetoothDevice.fromId(lastId) : null;
      if (found == null) throw 'not found';
      await _open(found!);
    } catch (e) {
      connecting = false; connected = false;
      _setStatus('Not found - retrying...');
      _scheduleRetry();
    }
  }

  Future<void> _open(BluetoothDevice d) async {
    dev = d;
    await _stateSub?.cancel();
    _stateSub = d.connectionState.listen((s) { if (s == BluetoothConnectionState.disconnected && (connected || connecting)) _lost(); });
    _setStatus('Connecting...');
    try { await d.disconnect(); } catch (_) {}
    await d.connect(autoConnect: false, timeout: const Duration(seconds: 15));
    try { await d.clearGattCache(); } catch (_) {}
    try { await d.requestMtu(247); } catch (_) {}
    final svcs = await d.discoverServices();
    rx = null; tx = null;
    for (final s in svcs) {
      if (s.uuid == Guid(svcUuid)) {
        for (final c in s.characteristics) { if (c.uuid == Guid(rxUuid)) rx = c; if (c.uuid == Guid(txUuid)) tx = c; }
      }
    }
    if (rx == null || tx == null) throw 'wrong device';
    await _valSub?.cancel();
    _buf = '';
    _valSub = tx!.onValueReceived.listen(_onBytes);
    await tx!.setNotifyValue(true);
    await prefs.setString('lastId', d.remoteId.str);
    connected = true; connecting = false; _retry = 0;
    _setStatus('Connected');
    send('PN|$phoneName');
    await Future.delayed(const Duration(milliseconds: 250));
    send('I?');
  }

  void _lost() {
    connected = false; connecting = false; rx = null; tx = null; _valSub?.cancel();
    _setStatus(userStopped ? 'Disconnected' : 'Connection lost - reconnecting...');
    if (!userStopped) _scheduleRetry();
  }
  void _scheduleRetry() {
    _retryTimer?.cancel();
    final wait = Duration(seconds: (2 + _retry * 2).clamp(2, 12));
    _retry++;
    _retryTimer = Timer(wait, () { if (!connected && !connecting && !userStopped) connect(); });
  }
  Future<void> disconnect() async {
    userStopped = true; _retryTimer?.cancel();
    try { await dev?.disconnect(); } catch (_) {}
    connected = false; connecting = false;
    _setStatus('Disconnected');
  }

  // ---- protocol (one text line per message)
  void send(String s) {
    if (rx == null || !connected) return;
    final c = rx!;
    _chain = _chain.then((_) async { try { await c.write(utf8.encode('$s\n'), withoutResponse: false, allowLongWrite: true); } catch (_) {} });
  }
  void _onBytes(List<int> b) {
    _buf += utf8.decode(b, allowMalformed: true);
    int i;
    while ((i = _buf.indexOf('\n')) >= 0) {
      final line = _buf.substring(0, i).trim();
      _buf = _buf.substring(i + 1);
      if (line.isNotEmpty) _onLine(line);
    }
    if (_buf.length > 600) _buf = '';
  }
  void _onLine(String l) {
    final p = l.split('|');
    if (p.length < 2) return;
    switch (p[0]) {
      case 'I': info[p[1]] = p.length > 2 ? p.sublist(2).join('|') : ''; break;
      case 'S': if (p[1] == 'cd') _toast('Timer completed', 'Your timer on the Desk Buddy is done.'); break;
      case 'FIND': { if (p.length > 1 && p[1] == '1') { findStart(); } else { finding = false; _findT?.cancel(); notifyListeners(); native.invokeMethod('findStop').catchError((_) {}); } break; }
      case 'OPEN': { final nm = p.sublist(1).join('|'); openApp(nm).then((ok) { if (!ok) send('T|App not found: ' + nm); }); break; }
      case 'AI': { final a = p.sublist(1).join('|'); if (aiLog.isNotEmpty) { aiLog.last[1] = a; } else { aiLog.add(['', a]); } break; }
      case 'G': lastMsg = p.sublist(1).join('|'); _toast('Desk Buddy', lastMsg); break;
      case 'M': lastMsg = p.sublist(1).join('|'); _toast('Desk Buddy', lastMsg); break;
      case 'C':
        if (p[1] == 'PP') media('pp');
        if (p[1] == 'MUSIC1') _musicNow();
        break;
      default: break;
    }
    notifyListeners();
  }
  Future<void> _toast(String t, String b) async { try { await native.invokeMethod('notify', {'title': t, 'body': b}); } catch (_) {} }
  Future<void> media(String k) async { try { await native.invokeMethod('media', {'key': k}); } catch (_) {} }
  Future<void> setFwd(bool v) async { fwd = v; await prefs.setBool('fwd', v); notifyListeners(); }

  // ---- phone notifications -> Desk Buddy (and media notifications -> music mode)
  void _onNotif(dynamic ev) {
    if (ev is! Map) return;
    final pkg = (ev['pkg'] ?? '') as String, title = ((ev['title'] ?? '') as String).trim(), text = ((ev['text'] ?? '') as String).trim();
    final removed = ev['removed'] == true;
    if (skipPkgs.contains(pkg)) return;
    if (mediaPkgs.contains(pkg)) {
      if (removed) { if (musicApp == appName(pkg)) { musicTitle = ''; send('MU|2|||'); } }
      else if (title.isNotEmpty) { musicTitle = title; musicApp = appName(pkg); _musicSend(text); }
      notifyListeners();
      return;
    }
    if (!fwd || !connected || removed || (title.isEmpty && text.isEmpty)) return;
    final key = '$pkg|$title|$text';
    final now = DateTime.now().millisecondsSinceEpoch;
    _recent.removeWhere((_, t) => now - t > 8000);
    if (_recent.containsKey(key)) return;
    _recent[key] = now;
    String c(String s, int n) => (s.length > n ? s.substring(0, n) : s).replaceAll('|', '/').replaceAll('\n', ' ');
    _fwdQ.add('N|${c(appName(pkg), 18)}|${c(title, 30)}|${c(text, 160)}');
    if (_fwdQ.length > 6) _fwdQ.removeAt(0);
    _drain();
  }
  Future<void> _drain() async {
    if (_fwdBusy) return;
    _fwdBusy = true;
    while (_fwdQ.isNotEmpty) { send(_fwdQ.removeAt(0)); sentCount++; notifyListeners(); await Future.delayed(const Duration(milliseconds: 700)); }
    _fwdBusy = false;
  }
  void _musicSend(String artist) {
    String c(String s, int n) => (s.length > n ? s.substring(0, n) : s).replaceAll('|', '/').replaceAll('\n', ' ');
    send('MU|1|${c(musicApp, 20)}|${c(musicTitle, 60)}|${c(artist, 36)}');
  }
  void musicSync() { _musicNow(); }
  void _musicNow() { if (musicTitle.isNotEmpty) _musicSend(''); else send('MU|2|||'); }
}

const faceNames = ['Normal','Happy','Wink','Shy','Mustache','Bored','Laser Eyes','Hypnotic','Heartbeat','Pac-Man','Space Helmet','Lava Eyes','Panda','Bunny','Owl','Fox','Frog','Penguin','Unicorn','Octopus','Bat','Spider','Pumpkin','Snowman','Dragon','Bubble Gum','Rainbow Smile','Sound Wave','Wizard','Clown','Smiley Spin','Smirk','Winking Heart','Laughing','Crying','Enraged','Mind Blown','Starry Eyed','Thinking','Yawning','Skeptic','Sweating','In Love','Determined','Boo','Silly','Cool','Ninja','Robot','Cat','Nerd','Vampire','Ghost Panic','Angel','Devil','Money Eyes','Alien','Victorious','Teasing','Exhausted','Loading','Glitch','Pixel Heart','Cyber Shield','Matrix Code','Neon Spiral','Equalizer','Radar','Battery Low','Charging','WiFi Search','Bluetooth','Terminal','Skull','Crosshair','Gamepad','Rocket','Atom','Infinity','Biohazard','Radioactive','Fire','Water Drop','Lightning','Snowflake','Sun Rays','Crescent Moon','Cloud Rain','Wind Gust','Compass','Bullseye','Sleepy','Surprised','Kiss','Dizzy','Party Hat','Pirate','Sick','Coffee','Music Notes','My Face'];

final link = Link();
final accent = ValueNotifier<int>(0xFF1FB5C9);
final dark = ValueNotifier<bool>(true);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  accent.value = p.getInt('accent') ?? 0xFF1FB5C9;
  dark.value = p.getBool('dark') ?? true;
  runApp(const ArnoApp());
}

class ArnoApp extends StatelessWidget {
  const ArnoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([accent, dark]),
      builder: (_, __) {
        final seed = Color(accent.value);
        return MaterialApp(
          title: 'Arno Link', debugShowCheckedModeBanner: false,
          themeMode: dark.value ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light)),
          darkTheme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: const Color(0xFF08121B), colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark, surface: const Color(0xFF0E1D2B))),
          home: const Home(),
        );
      },
    );
  }
}

Widget card(String title, List<Widget> kids) => Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
  if (title.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
  ...kids,
])));

Widget cmdBtn(String label, String cmd, {bool filled = false}) => Padding(
  padding: const EdgeInsets.all(3),
  child: filled ? FilledButton(onPressed: () => link.send(cmd), child: Text(label)) : FilledButton.tonal(onPressed: () => link.send(cmd), child: Text(label)),
);

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  int tab = 0;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); link.init(); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) { if (s == AppLifecycleState.resumed) link.checkListener(); }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[const ControlTab(), const WebTab(), const MusicTab(), const AiTab(), const SettingsTab()];
    return Scaffold(
      appBar: AppBar(title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
        Text('Arno Link', style: TextStyle(fontWeight: FontWeight.w800)), Text('By- Arnod', style: TextStyle(fontSize: 11)),
      ]), actions: [
        ListenableBuilder(listenable: link, builder: (_, __) => Padding(padding: const EdgeInsets.only(right: 12),
          child: Icon(link.connected ? Icons.bluetooth_connected : Icons.bluetooth_searching, color: link.connected ? Colors.green : Colors.orange))),
      ]),
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [
        NavigationDestination(icon: Icon(Icons.tune), label: 'Control'),
        NavigationDestination(icon: Icon(Icons.language), label: 'Setup'),
        NavigationDestination(icon: Icon(Icons.music_note), label: 'Music'),
        NavigationDestination(icon: Icon(Icons.auto_awesome), label: 'AI'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
      ]),
    );
  }
}

// ---------------- Control (everything over Bluetooth) ----------------
class ControlTab extends StatefulWidget {
  const ControlTab({super.key});
  @override
  State<ControlTab> createState() => _ControlTabState();
}
class _ControlTabState extends State<ControlTab> {
  final cd = TextEditingController(text: '5');
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: link, builder: (_, __) {
      final cs = Theme.of(context).colorScheme;
      return ListView(padding: const EdgeInsets.all(14), children: [
        card('', [
          Row(children: [
            Icon(link.connected ? Icons.bluetooth_connected : Icons.bluetooth_searching, color: link.connected ? Colors.green : Colors.orange, size: 30),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(link.connected ? (link.info['dev'] ?? 'Desk Buddy') : 'Desk Buddy', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              Text(link.status, style: TextStyle(color: cs.onSurfaceVariant)),
            ])),
            FilledButton.tonal(onPressed: link.connected ? link.disconnect : link.connect, child: Text(link.connected ? 'Disconnect' : 'Connect')),
          ]),
          if (link.connected) Padding(padding: const EdgeInsets.only(top: 8), child: Text('User: ${link.info['user'] ?? '-'}  FW: ${link.info['fw'] ?? '-'}  WiFi: ${link.info['wifi'] ?? '-'}', style: const TextStyle(fontSize: 12))),
        ]),
        if (link.finding) Card(color: Colors.red.shade700, child: ListTile(leading: const Icon(Icons.notifications_active, color: Colors.white), title: const Text('Your phone is ringing', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)), trailing: FilledButton(onPressed: link.findStop, child: const Text('Stop')))),
        card('Find my phone and My face', [
          Wrap(children: [
            Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton.icon(onPressed: link.finding ? link.findStop : link.findStart, icon: Icon(link.finding ? Icons.stop : Icons.ring_volume), label: Text(link.finding ? 'Stop ringing' : 'Ring this phone'))),
            Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton.tonalIcon(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FaceEditor())), icon: const Icon(Icons.brush), label: const Text('Face editor'))),
          ]),
          const Text('Tap the Desk Buddy pad 7 times (or ask Buddy AI: "find my phone") and this phone rings loudly. No password needed. Tap 7 again to stop.', style: TextStyle(fontSize: 12)),
        ]),
        card('Screens', [Wrap(children: [
          cmdBtn('Time', 'MTIME'), cmdBtn('Weather', 'MWEATHER'), cmdBtn('3-day', 'MFORECAST'), cmdBtn('Info', 'MINFO'),
          cmdBtn('Manual', 'MMAN1'), cmdBtn('Music', 'MMUSIC'), cmdBtn('Flip a coin', 'MCOIN'), cmdBtn('Games', 'MMENU'),
          cmdBtn('Stopwatch', 'MSW'), cmdBtn('Sleep', 'MSLEEP'),
        ])]),
        card('Touch pad', [
          Wrap(children: [for (final n in [1, 2, 3, 4, 5, 6, 7]) cmdBtn('$n tap${n > 1 ? 's' : ''}', 'PAD|R|$n'), cmdBtn('Hold 1s', 'PAD|R|H'), cmdBtn('Hold 3s', 'PAD|R|F'), cmdBtn('Hold 5s', 'PAD|R|L')]),
          const Text('1 next face, 2 weather, 3 time, 4 manual, 5 music, 6 coin, 7 find my phone, hold 3s = games menu (13 games; 2 next, 1 pick, 3 quit)', style: TextStyle(fontSize: 12)),
        ]),
        card('Timer and stopwatch', [
          Row(children: [
            Expanded(child: TextField(controller: cd, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Minutes', isDense: true, border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            FilledButton(onPressed: () { final m = double.tryParse(cd.text) ?? 0; link.send('CD${(m * 60).round()}'); }, child: const Text('Start')),
            const SizedBox(width: 6),
            FilledButton.tonal(onPressed: () => link.send('CD0'), child: const Text('Stop')),
          ]),
          const SizedBox(height: 6),
          Wrap(children: [cmdBtn('Stopwatch start', 'SW1'), cmdBtn('Stop', 'SW0'), cmdBtn('Reset', 'SWR')]),
        ]),
        card('Faces (${faceNames.length})', [Wrap(children: [
          for (var i = 0; i < faceNames.length; i++)
            Padding(padding: const EdgeInsets.all(2), child: ActionChip(label: Text('${i + 1}. ${faceNames[i]}', style: const TextStyle(fontSize: 12)), onPressed: () => link.send('F$i'))),
        ])]),
      ]);
    });
  }
}

// ---------------- Web control (the Desk Buddy page inside the app) ----------------
class WebTab extends StatefulWidget {
  const WebTab({super.key});
  @override
  State<WebTab> createState() => _WebTabState();
}
class _WebTabState extends State<WebTab> {
  WebViewController? wc;
  bool started = false;
  void start() {
    link.bindWifi(true);   // use the Desk Buddy WiFi even though it has no internet
    wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF08121B))
      ..loadRequest(Uri.parse('http://${link.host}/'));
    setState(() => started = true);
  }
  @override
  Widget build(BuildContext context) {
    if (!started) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.language, size: 56),
        const SizedBox(height: 12),
        Text('Join the WiFi "Arno OS-Setup" (password Arnod1702), then open the setup page at http://${link.host}', textAlign: TextAlign.center),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: start, icon: const Icon(Icons.open_in_browser), label: const Text('Open setup page')),
      ])));
    }
    return Column(children: [
      Row(children: [
        IconButton(onPressed: () => wc?.reload(), icon: const Icon(Icons.refresh)),
        IconButton(onPressed: () { link.bindWifi(false); setState(() => started = false); }, icon: const Icon(Icons.close)),
        Expanded(child: Text('http://${link.host}', style: const TextStyle(fontSize: 12))),
      ]),
      Expanded(child: WebViewWidget(controller: wc!)),
    ]);
  }
}

// ---------------- Music ----------------
class MusicTab extends StatelessWidget {
  const MusicTab({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: link, builder: (_, __) => ListView(padding: const EdgeInsets.all(14), children: [
      card('Music control', [
        Text(link.musicTitle.isEmpty ? 'Nothing playing on this phone' : '${link.musicApp}: ${link.musicTitle}', maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton.filledTonal(onPressed: () => link.media('prev'), icon: const Icon(Icons.skip_previous)),
          IconButton.filled(iconSize: 32, onPressed: () => link.media('pp'), icon: const Icon(Icons.play_arrow)),
          IconButton.filledTonal(onPressed: () => link.media('next'), icon: const Icon(Icons.skip_next)),
        ]),
        const SizedBox(height: 8),
        Wrap(children: [
          cmdBtn('Open music mode', 'MMUSIC', filled: true),
          cmdBtn('Play/Pause (2 taps)', 'PAD|R|2'),
          cmdBtn('Exit (1 tap)', 'PAD|R|1'),
          Padding(padding: const EdgeInsets.all(3), child: FilledButton.tonal(onPressed: link.musicSync, child: const Text('Send now playing'))),
        ]),
        const Text('On the Desk Buddy: 5 taps = music mode. 2 taps = play/pause, 1 tap = exit. Works with or without the phone connected.', style: TextStyle(fontSize: 12)),
      ]),
    ]));
  }
}

// ---------------- AI ----------------
class AiTab extends StatefulWidget {
  const AiTab({super.key});
  @override
  State<AiTab> createState() => _AiTabState();
}
class _AiTabState extends State<AiTab> {
  final t = TextEditingController();
  void go() { final q = t.text.trim(); if (q.isEmpty) return; t.clear(); link.ask(q); }
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: link, builder: (_, __) {
      final cs = Theme.of(context).colorScheme;
      return Column(children: [
        Expanded(child: link.aiLog.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Ask Buddy AI anything. The question and answer also appear on the Desk Buddy.\nTry: "show weather", "flip a coin", "show time".\nThe Desk Buddy needs home WiFi and a Gemini key for answers.', textAlign: TextAlign.center)))
          : ListView(padding: const EdgeInsets.all(12), children: [
              for (final qa in link.aiLog) ...[
                Align(alignment: Alignment.centerRight, child: Container(margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(14)), child: Text(qa[0]))),
                Align(alignment: Alignment.centerLeft, child: Container(margin: const EdgeInsets.only(top: 6), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)), child: Text(qa[1]))),
              ],
            ])),
        Padding(padding: const EdgeInsets.all(10), child: Row(children: [
          Expanded(child: TextField(controller: t, onSubmitted: (_) => go(), decoration: InputDecoration(hintText: link.connected ? 'Ask Buddy AI...' : 'Connect Bluetooth first', border: const OutlineInputBorder(), isDense: true))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: go, icon: const Icon(Icons.send)),
        ])),
      ]);
    });
  }
}

// ---------------- Settings (+ OTA + Add More) ----------------
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}
class _SettingsTabState extends State<SettingsTab> {
  final name = TextEditingController(), tz = TextEditingController(), key = TextEditingController(), model = TextEditingController(), host = TextEditingController(text: link.host);
  String otaMsg = '', placeMsg = '';
  final city = TextEditingController();
  bool otaBusy = false;
  List<Map<String, dynamic>> extras = [];
  @override
  void initState() { super.initState(); _loadExtras(); }
  Future<void> _loadExtras() async {
    final p = await SharedPreferences.getInstance();
    try { extras = (jsonDecode(p.getString('extras') ?? '[]') as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(); } catch (_) { extras = []; }
    if (mounted) setState(() {});
  }
  Future<void> _saveExtras() async { final p = await SharedPreferences.getInstance(); await p.setString('extras', jsonEncode(extras)); if (mounted) setState(() {}); }

  Future<void> pickOta() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    if (r == null || r.files.single.path == null) return;
    setState(() { otaBusy = true; otaMsg = 'Starting...'; });
    final m = await link.ota(r.files.single.path!, (s) { if (mounted) setState(() => otaMsg = s); });
    if (mounted) setState(() { otaBusy = false; otaMsg = m; });
  }

  Future<void> addMore() async {
    final n = TextEditingController(), v = TextEditingController();
    String kind = 'code';
    await showDialog(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
      title: const Text('Add More'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Feature name')),
        const SizedBox(height: 8),
        SegmentedButton<String>(segments: const [ButtonSegment(value: 'code', label: Text('Code')), ButtonSegment(value: 'url', label: Text('URL'))], selected: {kind}, onSelectionChanged: (s) => set(() => kind = s.first)),
        const SizedBox(height: 8),
        TextField(controller: v, minLines: 5, maxLines: 10, decoration: InputDecoration(labelText: kind == 'url' ? 'Page address (http://...)' : 'HTML / JavaScript code', border: const OutlineInputBorder(), helperText: kind == 'code' ? 'Use Arno.postMessage("MCOIN") to send a command to the Desk Buddy' : null, helperMaxLines: 2)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        TextButton(onPressed: () {
          if (n.text.trim().isEmpty || v.text.trim().isEmpty) return;
          extras.add({'n': n.text.trim(), 't': kind, 'v': v.text});
          _saveExtras(); Navigator.pop(c);
        }, child: const Text('Save')),
      ],
    )));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: link, builder: (_, __) {
      final cs = Theme.of(context).colorScheme;
      const colors = [0xFF1FB5C9, 0xFF4CAF50, 0xFFFF9800, 0xFFE91E63, 0xFF7C4DFF, 0xFFF44336, 0xFF2196F3];
      Widget row(String label, TextEditingController c, String prefix, {bool obscure = false}) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
        Expanded(child: TextField(controller: c, obscureText: obscure, decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()))),
        const SizedBox(width: 8),
        FilledButton.tonal(onPressed: () { if (c.text.trim().isNotEmpty || prefix == 'GK|') { link.send('$prefix${c.text.trim()}'); } }, child: const Text('Save')),
      ]));
      return ListView(padding: const EdgeInsets.all(14), children: [
        card('Desk Buddy settings (Bluetooth)', [
          row('Your name', name, 'SU|'),
          row('Time zone (minutes, e.g. 330 for India)', tz, 'TZ|'),
          row('Gemini API key', key, 'GK|', obscure: true),
          row('Gemini model (gemini-2.5-flash)', model, 'GM|'),
          Wrap(children: [cmdBtn('Restart', 'RB'), cmdBtn('Erase settings', 'ERASE')]),
        ]),
        card('Update Desk Buddy (OTA)', [
          const Text('Pick ARNO_OS_update.bin. The Desk Buddy opens the WiFi "OTA-UPDATE" (password OTA1234), shows the OTA screen, updates, restarts and the WiFi closes. Keep Bluetooth connected.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: otaBusy ? null : pickOta, icon: const Icon(Icons.system_update), label: Text(otaBusy ? 'Uploading...' : 'Choose update file and send')),
          if (otaMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(otaMsg, style: const TextStyle(fontSize: 12))),
        ]),
        card('Phone notifications on Desk Buddy', [
          SwitchListTile(contentPadding: EdgeInsets.zero, value: link.fwd, onChanged: link.setFwd, title: const Text('Forward notifications'), subtitle: Text('${link.sentCount} sent this session')),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(link.listenerOn ? Icons.check_circle : Icons.error_outline, color: link.listenerOn ? Colors.green : Colors.orange),
            title: Text(link.listenerOn ? 'Notification access is ON' : 'Notification access is OFF'),
            subtitle: Text(link.listenerOn ? 'Also set battery to Unrestricted for Arno Link.' : 'Tap Grant, find "Arno Link" in the list and switch it on.'),
            trailing: FilledButton.tonal(onPressed: link.openListenerSettings, child: Text(link.listenerOn ? 'Open' : 'Grant')),
          ),
        ]),
        card('Weather place', [
          Wrap(children: [cmdBtn('Bhubaneswar', 'WL|20.2961|85.8245|Bhubaneswar'), cmdBtn('Rairangpur', 'WL|22.2594|86.1747|Rairangpur'), cmdBtn('Auto', 'WL|auto')]),
          Row(children: [
            Expanded(child: TextField(controller: city, decoration: const InputDecoration(labelText: 'Search a city (Desk Buddy needs home WiFi)', isDense: true, border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: () { final c = city.text.trim().replaceAll('|', ' '); if (c.isNotEmpty) link.send('WC|$c'); }, child: const Text('Find')),
          ]),
          const SizedBox(height: 6),
          FilledButton.icon(onPressed: () async { final r = await link.usePhoneLocation(); if (mounted) setState(() => placeMsg = r); }, icon: const Icon(Icons.my_location), label: const Text('Use phone location')),
          if (placeMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(placeMsg, style: const TextStyle(fontSize: 12))),
        ]),
        card('Open apps from the Desk Buddy', [
          const Text('Ask Buddy AI "open youtube" (or any app name) and your phone opens it. Android needs "Display over other apps" for this to work while Arno Link is in the background.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          FilledButton.tonal(onPressed: link.openOverlaySettings, child: const Text('Allow opening apps')),
        ]),
        card('Add More', [
          const Text('New feature for the app without rebuilding it: add a name and either a page address or your own HTML/JS code.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          FilledButton.icon(onPressed: addMore, icon: const Icon(Icons.add), label: const Text('Add More')),
          for (var i = 0; i < extras.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero, leading: Icon(extras[i]['t'] == 'url' ? Icons.link : Icons.code),
              title: Text(extras[i]['n'] as String),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExtraPage(extras[i]))),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { extras.removeAt(i); _saveExtras(); }),
            ),
        ]),
        card('Look', [
          SwitchListTile(contentPadding: EdgeInsets.zero, value: dark.value, onChanged: (v) async { dark.value = v; (await SharedPreferences.getInstance()).setBool('dark', v); }, title: const Text('Dark mode')),
          Wrap(spacing: 10, children: [
            for (final c in colors)
              GestureDetector(
                onTap: () async { accent.value = c; (await SharedPreferences.getInstance()).setInt('accent', c); },
                child: CircleAvatar(radius: 17, backgroundColor: Color(c), child: accent.value == c ? const Icon(Icons.check, color: Colors.white, size: 18) : null),
              ),
          ]),
        ]),
        const SizedBox(height: 10),
        Center(child: Text('Arno Link v4 - By- Arnod', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))),
      ]);
    });
  }
}

// a user-added feature: a web page or pasted HTML/JS. Arno.postMessage("CMD") sends a command to the Desk Buddy.
class ExtraPage extends StatefulWidget {
  final Map<String, dynamic> item;
  const ExtraPage(this.item, {super.key});
  @override
  State<ExtraPage> createState() => _ExtraPageState();
}
class _ExtraPageState extends State<ExtraPage> {
  late final WebViewController wc;
  @override
  void initState() {
    super.initState();
    wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF08121B))
      ..addJavaScriptChannel('Arno', onMessageReceived: (m) => link.send(m.message));
    final v = widget.item['v'] as String;
    if (widget.item['t'] == 'url') { wc.loadRequest(Uri.parse(v)); } else { wc.loadHtmlString(v); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(widget.item['n'] as String)), body: WebViewWidget(controller: wc));
}


// ---------------- custom face editor: paint a 64x32 face, send it to the Desk Buddy (face "My Face", the last one) ----------------
class FaceEditor extends StatefulWidget {
  const FaceEditor({super.key});
  @override
  State<FaceEditor> createState() => _FaceEditorState();
}
class _FaceEditorState extends State<FaceEditor> {
  static const gw = 64, gh = 32;
  final List<bool> g = List.filled(gw * gh, false);
  bool erase = false, mirror = true, sending = false;
  int brush = 1;
  @override
  void initState() {
    super.initState();
    final s = link.prefs.getString('cface');
    if (s != null && s.length == gw * gh) { for (var i = 0; i < s.length; i++) { g[i] = s[i] == '1'; } }
  }
  void _store() { link.prefs.setString('cface', g.map((b) => b ? '1' : '0').join()); }
  void _set(int x, int y, bool v) { if (x >= 0 && x < gw && y >= 0 && y < gh) g[y * gw + x] = v; }
  void _dot(int cx, int cy) {
    for (var dy = 0; dy < brush; dy++) {
      for (var dx = 0; dx < brush; dx++) {
        _set(cx + dx, cy + dy, !erase);
        if (mirror) _set(gw - 1 - (cx + dx), cy + dy, !erase);
      }
    }
  }
  void _paint(Offset p, double cell) { setState(() => _dot((p.dx / cell).floor(), (p.dy / cell).floor())); }
  void _ell(int cx, int cy, int rx, int ry, {bool fill = true}) {
    for (var y = -ry; y <= ry; y++) {
      for (var x = -rx; x <= rx; x++) {
        final v = (x * x) / (rx * rx) + (y * y) / (ry * ry);
        if (fill ? v <= 1.0 : (v <= 1.0 && v >= 0.55)) _set(cx + x, cy + y, true);
      }
    }
  }
  void _preset(int n) {
    setState(() {
      g.fillRange(0, g.length, false);
      if (n == 0) { _ell(19, 13, 6, 8); _ell(45, 13, 6, 8); for (var x = 24; x <= 40; x++) { _set(x, 26, true); _set(x, 27, true); } }
      if (n == 1) { _ell(19, 13, 6, 8); _ell(45, 13, 6, 8); for (var x = 20; x <= 44; x++) { final y = 21 + ((x - 32) * (x - 32)) ~/ 40; _set(x, y, true); _set(x, y + 1, true); } }
      if (n == 2) { for (var x = 12; x <= 26; x++) { _set(x, 14, true); _set(x, 15, true); _set(x + 26, 14, true); _set(x + 26, 15, true); } for (var x = 24; x <= 40; x++) { _set(x, 26, true); } }
    });
  }
  String _hex(int chunk) {
    final sb = StringBuffer();
    for (var r = chunk * 4; r < chunk * 4 + 4; r++) {
      for (var b = 0; b < 8; b++) {
        var v = 0;
        for (var k = 0; k < 8; k++) { if (g[r * gw + b * 8 + k]) v |= (0x80 >> k); }
        sb.write(v.toRadixString(16).padLeft(2, '0'));
      }
    }
    return sb.toString();
  }
  Future<void> _send() async {
    if (!link.connected) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connect to the Desk Buddy first'))); return; }
    setState(() => sending = true);
    _store();
    for (var i = 0; i < 8; i++) { link.send('CF|$i|${_hex(i)}'); await Future.delayed(const Duration(milliseconds: 160)); }
    if (!mounted) return;
    setState(() => sending = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent! Your face is the last one (tap the pad to cycle to it)')));
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Face editor')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        LayoutBuilder(builder: (_, c) {
          final cell = c.maxWidth / gw;
          return GestureDetector(
            onPanStart: (d) => _paint(d.localPosition, cell),
            onPanUpdate: (d) => _paint(d.localPosition, cell),
            onTapDown: (d) => _paint(d.localPosition, cell),
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: CustomPaint(size: Size(c.maxWidth, cell * gh), painter: _GridPainter(List.of(g), cell))),
          );
        }),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(label: const Text('Draw'), selected: !erase, onSelected: (_) => setState(() => erase = false)),
          ChoiceChip(label: const Text('Erase'), selected: erase, onSelected: (_) => setState(() => erase = true)),
          FilterChip(label: const Text('Mirror'), selected: mirror, onSelected: (v) => setState(() => mirror = v)),
          for (final b in [1, 2, 3]) ChoiceChip(label: Text('Brush $b'), selected: brush == b, onSelected: (_) => setState(() => brush = b)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: () => setState(() => g.fillRange(0, g.length, false)), child: const Text('Clear')),
          OutlinedButton(onPressed: () => setState(() { for (var i = 0; i < g.length; i++) { g[i] = !g[i]; } }), child: const Text('Invert')),
          OutlinedButton(onPressed: () => _preset(0), child: const Text('Round eyes')),
          OutlinedButton(onPressed: () => _preset(1), child: const Text('Smile')),
          OutlinedButton(onPressed: () => _preset(2), child: const Text('Sleepy')),
        ]),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: sending ? null : _send, icon: const Icon(Icons.send), label: Text(sending ? 'Sending...' : 'Send to Desk Buddy')),
        const SizedBox(height: 8),
        const Text('Draw with your finger. Mirror paints both sides at once. The face is saved on the Desk Buddy and appears as the last face ("My Face").', style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}
class _GridPainter extends CustomPainter {
  final List<bool> g; final double cell;
  _GridPainter(this.g, this.cell);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final on = Paint()..color = const Color(0xFF9CE8F2);
    final line = Paint()..color = const Color(0x22FFFFFF)..strokeWidth = 0.5;
    for (var y = 0; y < 32; y++) { for (var x = 0; x < 64; x++) { if (g[y * 64 + x]) canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), on); } }
    for (var x = 0; x <= 64; x += 8) { canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, size.height), line); }
    for (var y = 0; y <= 32; y += 8) { canvas.drawLine(Offset(0, y * cell), Offset(size.width, y * cell), line); }
  }
  @override
  bool shouldRepaint(covariant _GridPainter o) => true;
}
