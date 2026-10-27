import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'transfer_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PrzesylApp());
}

const _seed = Color(0xFF0E7C66);

class PrzesylApp extends StatelessWidget {
  const PrzesylApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Przesył',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
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
  final service = TransferService();

  @override
  void initState() {
    super.initState();
    service.onOffer = _askAccept;
    service.start();
  }

  @override
  void dispose() {
    service.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ actions

  Future<bool> _askAccept(IncomingOffer offer) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.download_rounded),
        title: Text('${offer.senderName} chce przesłać'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${offer.files.length} ${plikiPlural(offer.files.length)} · '
                  '${formatBytes(offer.totalSize)}'),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in offer.files)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(iconFor(f.name)),
                        title: Text(f.name, overflow: TextOverflow.ellipsis),
                        trailing: Text(formatBytes(f.size)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Odrzuć'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Przyjmij'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _sendTo(Peer peer) async {
    if (service.sending != null) return;
    final files = await openFiles();
    if (files.isEmpty) return;
    try {
      await service.sendFiles(peer, files);
      _snack('Wysłano ${files.length} ${plikiPlural(files.length)} do ${peer.name} ✓');
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  Future<void> _addByIp() async {
    final ctrl = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dodaj po adresie IP'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: 'np. 192.168.1.23',
            helperText: 'Adres IP widać na górze ekranu drugiego urządzenia',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Dodaj'),
          ),
        ],
      ),
    );
    if (ip == null || ip.trim().isEmpty) return;
    try {
      final ok = await service.addByIp(ip);
      _snack(ok ? 'Dodano urządzenie' : 'Nie znaleziono Przesyłu pod adresem $ip', error: !ok);
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: service.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nazwa tego urządzenia'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
    if (name != null) service.rename(name);
  }

  Future<void> _reveal(String path, {bool select = false}) async {
    if (!Platform.isMacOS) return;
    try {
      await Process.run('open', [if (select) '-R', path]);
    } catch (_) {}
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: error ? cs.error : null,
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ----------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final peers = service.peers;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Przesył'),
            actions: [
              IconButton(
                tooltip: 'Dodaj po adresie IP',
                icon: const Icon(Icons.add_link),
                onPressed: _addByIp,
              ),
            ],
          ),
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _selfCard(context),
                    if (service.startError != null) _errorCard(context, service.startError!),
                    if (service.sending != null) _progressCard(context, service.sending!, true),
                    if (service.receiving != null)
                      _progressCard(context, service.receiving!, false),
                    const SizedBox(height: 20),
                    _sectionTitle(context, 'Urządzenia w sieci'),
                    if (peers.isEmpty) _searchingCard(context) else ...peers.map(_peerTile),
                    if (service.received.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _sectionTitle(context, 'Odebrane'),
                      ...service.received.take(30).map(_receivedTile),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
        ),
      );

  Widget _selfCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ips = service.localIps.isEmpty ? 'brak sieci' : service.localIps.join(', ');
    return Card(
      color: cs.primaryContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              child: Icon(Platform.isAndroid ? Icons.phone_android : Icons.laptop_mac),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: _rename,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            service.deviceName,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: cs.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.edit, size: 16, color: cs.onPrimaryContainer),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('IP: $ips', style: TextStyle(color: cs.onPrimaryContainer)),
                  if (service.saveLabel.isNotEmpty)
                    Text(
                      'Zapis: ${service.saveLabel}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onPrimaryContainer.withValues(alpha: 0.75),
                          ),
                    ),
                ],
              ),
            ),
            if (Platform.isMacOS && service.saveDir != null)
              IconButton(
                tooltip: 'Otwórz folder',
                icon: Icon(Icons.folder_open, color: cs.onPrimaryContainer),
                onPressed: () => _reveal(service.saveDir!.path),
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(BuildContext context, String msg) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      elevation: 0,
      child: ListTile(
        leading: Icon(Icons.error_outline, color: cs.onErrorContainer),
        title: Text(msg, style: TextStyle(color: cs.onErrorContainer)),
      ),
    );
  }

  Widget _progressCard(BuildContext context, TransferProgress p, bool isSending) {
    final pct = (p.fraction * 100).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isSending ? Icons.upload_rounded : Icons.download_rounded),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isSending ? 'Wysyłanie do ${p.label}' : 'Odbieranie od ${p.label}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!p.waiting) Text('$pct%'),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              p.waiting ? p.fileName : '${p.fileName}  (${p.fileIndex + 1}/${p.fileCount})',
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: p.waiting ? null : p.fraction),
            const SizedBox(height: 6),
            Text(
              '${formatBytes(p.done)} / ${formatBytes(p.total)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchingCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Szukam urządzeń…', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Uruchom Przesył na drugim urządzeniu. Oba muszą być w tej samej sieci Wi-Fi.',
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addByIp,
                icon: const Icon(Icons.add_link),
                label: const Text('Nie widać? Dodaj po adresie IP'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _peerTile(Peer p) {
    final busy = service.sending != null;
    final icon = switch (p.os) {
      'android' => Icons.phone_android,
      'macos' => Icons.laptop_mac,
      _ => Icons.devices,
    };
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(p.name, overflow: TextOverflow.ellipsis),
        subtitle: Text('${p.address.address}${p.manual ? ' · dodane ręcznie' : ''}'),
        onTap: busy ? null : () => _sendTo(p),
        onLongPress: p.manual ? () => service.forget(p) : null,
        trailing: FilledButton.tonalIcon(
          onPressed: busy ? null : () => _sendTo(p),
          icon: const Icon(Icons.send_rounded, size: 18),
          label: const Text('Wyślij'),
        ),
      ),
    );
  }

  Widget _receivedTile(ReceivedFile f) {
    final t = f.time;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return Card(
      elevation: 0,
      child: ListTile(
        leading: Icon(iconFor(f.name)),
        title: Text(f.name, overflow: TextOverflow.ellipsis),
        subtitle: Text('od ${f.from} · ${formatBytes(f.size)} · $hh:$mm'),
        trailing: Platform.isMacOS ? const Icon(Icons.chevron_right) : null,
        onTap: Platform.isMacOS ? () => _reveal(f.path, select: true) : null,
      ),
    );
  }
}

// ------------------------------------------------------------------- helpers

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String plikiPlural(int n) {
  if (n == 1) return 'plik';
  final d = n % 10;
  final dd = n % 100;
  if (d >= 2 && d <= 4 && (dd < 12 || dd > 14)) return 'pliki';
  return 'plików';
}

IconData iconFor(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const images = {'jpg', 'jpeg', 'png', 'gif', 'heic', 'webp', 'bmp', 'tiff'};
  const videos = {'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'};
  const audio = {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'};
  const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'dmg'};
  if (images.contains(ext)) return Icons.image_outlined;
  if (videos.contains(ext)) return Icons.movie_outlined;
  if (audio.contains(ext)) return Icons.music_note_outlined;
  if (archives.contains(ext)) return Icons.folder_zip_outlined;
  if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
  if (ext == 'apk') return Icons.android;
  return Icons.insert_drive_file_outlined;
}
