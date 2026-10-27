// Rdzeń aplikacji Przesył:
//  * wykrywanie urządzeń w sieci lokalnej (UDP broadcast, port 53318)
//  * odbiór plików (serwer HTTP, port 53317)
//  * wysyłanie plików (oferta -> akceptacja -> przesył)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const int kHttpPort = 53317;
const int kDiscoveryPort = 53318;
const String kTag = 'przesyl-v1';

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.os,
    required this.address,
    required this.port,
    required this.lastSeen,
    this.manual = false,
  });

  final String id;
  String name;
  String os;
  InternetAddress address;
  int port;
  DateTime lastSeen;
  bool manual;
}

class OfferedFile {
  const OfferedFile(this.name, this.size);
  final String name;
  final int size;
}

class IncomingOffer {
  IncomingOffer({required this.senderName, required this.files});
  final String senderName;
  final List<OfferedFile> files;
  int get totalSize => files.fold<int>(0, (a, f) => a + f.size);
}

class ReceivedFile {
  ReceivedFile(this.path, this.size, this.from, this.time);
  final String path;
  final int size;
  final String from;
  final DateTime time;
  String get name => path.split(Platform.pathSeparator).last;
}

class TransferProgress {
  const TransferProgress({
    required this.label,
    required this.fileName,
    required this.done,
    required this.total,
    required this.fileIndex,
    required this.fileCount,
    this.waiting = false,
  });

  final String label;
  final String fileName;
  final int done;
  final int total;
  final int fileIndex;
  final int fileCount;
  final bool waiting;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);

  TransferProgress copyWith({String? fileName, int? done, int? fileIndex, bool? waiting}) {
    return TransferProgress(
      label: label,
      fileName: fileName ?? this.fileName,
      done: done ?? this.done,
      total: total,
      fileIndex: fileIndex ?? this.fileIndex,
      fileCount: fileCount,
      waiting: waiting ?? this.waiting,
    );
  }
}

class TransferException implements Exception {
  TransferException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef OfferHandler = Future<bool> Function(IncomingOffer offer);

class _Session {
  _Session(this.offer) : lastActivity = DateTime.now();
  final IncomingOffer offer;
  final Set<int> done = {};
  int bytesDone = 0;
  DateTime lastActivity;
}

class TransferService extends ChangeNotifier {
  final String id = _randomId();
  String deviceName = 'Urządzenie';
  Directory? saveDir;
  List<String> localIps = [];
  final List<ReceivedFile> received = [];
  TransferProgress? sending;
  TransferProgress? receiving;
  OfferHandler? onOffer;
  String? startError;

  HttpServer? _server;
  RawDatagramSocket? _udp;
  final Map<String, Peer> _peers = {};
  final Map<String, _Session> _sessions = {};
  final List<Timer> _timers = [];
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  List<Peer> get peers => _peers.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  int get httpPort => _server?.port ?? 0;

  static String get osName {
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    return Platform.operatingSystem;
  }

  // ---------------------------------------------------------------- start/stop

  Future<void> start() async {
    deviceName = _defaultName();
    try {
      saveDir = await _resolveSaveDir();

      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, kHttpPort);
      } on SocketException {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      _server!.listen(_handleRequest, onError: (_) {});

      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onUdpEvent, onError: (_) {});

      await refreshIps();
      _timers.add(Timer.periodic(const Duration(seconds: 2), (_) => announce()));
      _timers.add(Timer.periodic(const Duration(seconds: 2), (_) => _housekeeping()));
      _timers.add(Timer.periodic(const Duration(seconds: 15), (_) => refreshIps()));
      announce();
    } catch (e) {
      startError = 'Nie udało się uruchomić sieci: $e';
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers) {
      t.cancel();
    }
    _udp?.close();
    _server?.close(force: true);
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _progressNotify({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastNotify).inMilliseconds > 120) {
      _lastNotify = now;
      _notify();
    }
  }

  void rename(String newName) {
    final n = newName.trim();
    if (n.isEmpty) return;
    deviceName = n.length > 40 ? n.substring(0, 40) : n;
    announce();
    _notify();
  }

  String _defaultName() {
    if (Platform.isAndroid) return 'Android ${id.substring(0, 4).toUpperCase()}';
    var h = Platform.localHostname;
    if (h.endsWith('.local')) h = h.substring(0, h.length - 6);
    return h.isEmpty ? 'Mac' : h;
  }

  Future<Directory> _resolveSaveDir() async {
    if (Platform.isAndroid) {
      // Publiczny folder Pobrane/Przesyl (Android 11+). Jeśli się nie da,
      // zapisujemy w folderze aplikacji.
      final pub = Directory('/storage/emulated/0/Download/Przesyl');
      try {
        await pub.create(recursive: true);
        final test = File('${pub.path}/.przesyl_test');
        await test.writeAsString('ok');
        await test.delete();
        return pub;
      } catch (_) {}
      final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}/Przesyl');
      await d.create(recursive: true);
      return d;
    }
    final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/Przesyl');
    await d.create(recursive: true);
    return d;
  }

  Future<void> refreshIps() async {
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final ips = <String>[
        for (final i in ifs)
          for (final a in i.addresses)
            if (!a.isLinkLocal) a.address,
      ];
      if (!listEquals(ips, localIps)) {
        localIps = ips;
        _notify();
      }
    } catch (_) {}
  }

  // ----------------------------------------------------------------- discovery

  Map<String, dynamic> _hello(String type) => {
        't': kTag,
        'type': type,
        'id': id,
        'name': deviceName,
        'os': osName,
        'port': httpPort,
      };

  void _sendUdp(Map<String, dynamic> msg, InternetAddress to) {
    final udp = _udp;
    if (udp == null) return;
    try {
      udp.send(utf8.encode(jsonEncode(msg)), to, kDiscoveryPort);
    } catch (_) {}
  }

  void announce() {
    if (httpPort == 0) return;
    final msg = _hello('announce');
    final targets = <String>{
      '255.255.255.255',
      for (final ip in localIps) _subnetBroadcast(ip),
    };
    for (final t in targets) {
      _sendUdp(msg, InternetAddress(t));
    }
  }

  void _onUdpEvent(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final dg = _udp?.receive();
    if (dg == null) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (m['t'] != kTag || m['id'] == id) return;
    _upsert(m, dg.address);
    // Odpowiadamy bezpośrednio – pomaga, gdy telefon gubi broadcasty.
    if (m['type'] == 'announce') _sendUdp(_hello('reply'), dg.address);
  }

  void _upsert(Map<String, dynamic> m, InternetAddress addr, {bool manual = false}) {
    final pid = m['id'];
    final port = m['port'];
    if (pid is! String || port is! int || port <= 0) return;
    final name = '${m['name'] ?? 'Urządzenie'}';
    final os = '${m['os'] ?? ''}';
    final now = DateTime.now();
    final p = _peers[pid];
    if (p == null) {
      _peers[pid] = Peer(
        id: pid,
        name: name,
        os: os,
        address: addr,
        port: port,
        lastSeen: now,
        manual: manual,
      );
      _notify();
      return;
    }
    final changed = p.name != name || p.address.address != addr.address || p.port != port;
    p
      ..name = name
      ..os = os
      ..address = addr
      ..port = port
      ..lastSeen = now
      ..manual = p.manual || manual;
    if (changed) _notify();
  }

  void forget(Peer peer) {
    _peers.remove(peer.id);
    _notify();
  }

  /// Ręczne dodanie urządzenia, gdy automatyczne wykrywanie nie działa
  /// (np. sieć firmowa / hotelowa blokuje broadcast).
  Future<bool> addByIp(String ip) async {
    final addr = InternetAddress.tryParse(ip.trim());
    if (addr == null || addr.type != InternetAddressType.IPv4) {
      throw TransferException('Nieprawidłowy adres IP');
    }
    _sendUdp(_hello('announce'), addr);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(
        Uri(scheme: 'http', host: addr.address, port: kHttpPort, path: '/info'),
      );
      final res = await req.close().timeout(const Duration(seconds: 4));
      final data = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      if (data['t'] == kTag && data['id'] != id) {
        _upsert(data, addr, manual: true);
        return true;
      }
    } catch (_) {
      // spróbujemy jeszcze poczekać na odpowiedź UDP
    } finally {
      client.close(force: true);
    }

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    for (final p in _peers.values) {
      if (p.address.address == addr.address) {
        p.manual = true;
        _notify();
        return true;
      }
    }
    return false;
  }

  void _housekeeping() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere(
      (_, p) => !p.manual && now.difference(p.lastSeen) > const Duration(seconds: 8),
    );
    var changed = before != _peers.length;

    final staleSessions = _sessions.entries
        .where((e) => now.difference(e.value.lastActivity) > const Duration(seconds: 60))
        .map((e) => e.key)
        .toList();
    if (staleSessions.isNotEmpty) {
      staleSessions.forEach(_sessions.remove);
      if (_sessions.isEmpty) receiving = null;
      changed = true;
    }
    if (changed) _notify();
  }

  // ------------------------------------------------------------------ receiving

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/info') {
        await _json(req.response, 200, _hello('info'));
      } else if (req.method == 'POST' && path == '/offer') {
        await _handleOffer(req);
      } else if (req.method == 'POST' && path == '/upload') {
        await _handleUpload(req);
      } else {
        await _json(req.response, 404, {'error': 'not found'});
      }
    } catch (e) {
      try {
        await _json(req.response, 500, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse res, int code, Object body) async {
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> _handleOffer(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final m = jsonDecode(body) as Map<String, dynamic>;
    final rawFiles = (m['files'] as List?) ?? const [];
    final files = <OfferedFile>[
      for (final f in rawFiles)
        if (f is Map)
          OfferedFile(_safeName('${f['name']}'), (f['size'] as num?)?.toInt() ?? 0),
    ];
    if (files.isEmpty || files.any((f) => f.size < 0)) {
      await _json(req.response, 400, {'error': 'no files'});
      return;
    }
    final from = '${m['from'] ?? req.connectionInfo?.remoteAddress.address ?? 'Nieznane'}';
    final offer = IncomingOffer(senderName: from, files: files);

    final handler = onOffer;
    final accepted = handler != null && await handler(offer);
    if (!accepted) {
      await _json(req.response, 403, {'error': 'rejected'});
      return;
    }

    final token = _randomId(24);
    _sessions[token] = _Session(offer);
    receiving = TransferProgress(
      label: offer.senderName,
      fileName: files.first.name,
      done: 0,
      total: offer.totalSize,
      fileIndex: 0,
      fileCount: files.length,
    );
    _notify();
    await _json(req.response, 200, {'token': token});
  }

  void _endSession(String token) {
    _sessions.remove(token);
    if (_sessions.isEmpty) receiving = null;
    _notify();
  }

  Future<void> _handleUpload(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final token = q['token'] ?? '';
    final s = _sessions[token];
    if (s == null) {
      await _json(req.response, 403, {'error': 'bad token'});
      return;
    }
    final index = int.tryParse(q['i'] ?? '') ?? -1;
    if (index < 0 || index >= s.offer.files.length || s.done.contains(index)) {
      await _json(req.response, 400, {'error': 'bad index'});
      return;
    }
    final meta = s.offer.files[index];
    final file = await _uniqueFile(saveDir!, meta.name);
    final sink = file.openWrite();
    var got = 0;

    try {
      await for (final chunk in req) {
        got += chunk.length;
        if (got > meta.size) throw TransferException('Plik większy niż zapowiedziano');
        sink.add(chunk);
        s.lastActivity = DateTime.now();
        receiving = TransferProgress(
          label: s.offer.senderName,
          fileName: meta.name,
          done: s.bytesDone + got,
          total: s.offer.totalSize,
          fileIndex: index,
          fileCount: s.offer.files.length,
        );
        _progressNotify();
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await file.delete();
      } catch (_) {}
      _endSession(token);
      rethrow;
    }

    if (got != meta.size) {
      try {
        await file.delete();
      } catch (_) {}
      _endSession(token);
      await _json(req.response, 400, {'error': 'incomplete'});
      return;
    }

    s.done.add(index);
    s.bytesDone += got;
    received.insert(0, ReceivedFile(file.path, got, s.offer.senderName, DateTime.now()));
    if (s.done.length == s.offer.files.length) {
      _endSession(token);
    } else {
      _progressNotify(force: true);
    }
    await _json(req.response, 200, {'ok': true});
  }

  // -------------------------------------------------------------------- sending

  Future<void> sendFiles(Peer peer, List<XFile> files) async {
    if (sending != null) throw TransferException('Trwa już inne wysyłanie');
    if (files.isEmpty) return;

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    Uri u(String path, [Map<String, String>? q]) => Uri(
          scheme: 'http',
          host: peer.address.address,
          port: peer.port,
          path: path,
          queryParameters: q,
        );

    try {
      final sizes = <int>[];
      for (final f in files) {
        sizes.add(await f.length());
      }
      final total = sizes.fold<int>(0, (a, b) => a + b);

      sending = TransferProgress(
        label: peer.name,
        fileName: 'Czekam na akceptację…',
        done: 0,
        total: total,
        fileIndex: 0,
        fileCount: files.length,
        waiting: true,
      );
      _progressNotify(force: true);

      // 1. Oferta – odbiorca widzi okienko „Przyjmij / Odrzuć”.
      final offerReq = await client.postUrl(u('/offer'));
      offerReq.headers.contentType = ContentType.json;
      offerReq.write(jsonEncode({
        'from': deviceName,
        'files': [
          for (var i = 0; i < files.length; i++) {'name': files[i].name, 'size': sizes[i]},
        ],
      }));
      final offerRes = await offerReq.close().timeout(
            const Duration(minutes: 2),
            onTimeout: () => throw TransferException('${peer.name} nie odpowiedział(a)'),
          );
      final offerBody = await utf8.decodeStream(offerRes);
      if (offerRes.statusCode == 403) {
        throw TransferException('${peer.name} odrzucił(a) przesyłanie');
      }
      if (offerRes.statusCode != 200) {
        throw TransferException('Błąd odbiorcy (${offerRes.statusCode})');
      }
      final token = (jsonDecode(offerBody) as Map<String, dynamic>)['token'] as String;

      // 2. Pliki, jeden po drugim.
      var before = 0;
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final base = before;
        sending = sending!.copyWith(fileName: f.name, done: base, fileIndex: i, waiting: false);
        _progressNotify(force: true);

        final req = await client.postUrl(u('/upload', {'token': token, 'i': '$i'}));
        req.contentLength = sizes[i];
        req.headers.contentType = ContentType.binary;
        var sent = 0;
        await req.addStream(f.openRead().map((chunk) {
          sent += chunk.length;
          sending = sending!.copyWith(done: base + sent);
          _progressNotify();
          return chunk;
        }));
        final res = await req.close().timeout(
              const Duration(minutes: 2),
              onTimeout: () => throw TransferException('Przekroczono czas przy ${f.name}'),
            );
        await res.drain<void>();
        if (res.statusCode != 200) {
          throw TransferException('Nie udało się wysłać ${f.name} (${res.statusCode})');
        }
        before += sizes[i];
      }
    } on SocketException catch (e) {
      throw TransferException(
        'Brak połączenia z ${peer.name} (${e.osError?.message ?? e.message})',
      );
    } on HttpException catch (e) {
      throw TransferException('Połączenie przerwane: ${e.message}');
    } finally {
      client.close(force: true);
      sending = null;
      _notify();
    }
  }
}

// ---------------------------------------------------------------------- helpers

String _randomId([int len = 12]) {
  final r = Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
}

String _subnetBroadcast(String ip) {
  final p = ip.split('.');
  return p.length == 4 ? '${p[0]}.${p[1]}.${p[2]}.255' : '255.255.255.255';
}

/// Nazwa pliku bez ścieżek i znaków niedozwolonych.
String _safeName(String raw) {
  var n = raw.replaceAll('\\', '/').split('/').last;
  n = n.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
  while (n.startsWith('.')) {
    n = n.substring(1);
  }
  if (n.isEmpty) n = 'plik';
  if (n.length > 180) n = n.substring(n.length - 180);
  return n;
}

Future<File> _uniqueFile(Directory dir, String name) async {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  var f = File('${dir.path}/$name');
  var i = 1;
  while (await f.exists()) {
    f = File('${dir.path}/$base ($i)$ext');
    i++;
  }
  return f;
}
