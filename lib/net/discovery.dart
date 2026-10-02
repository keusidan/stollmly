import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'host_client.dart';

/// LAN 上の stollmly-host を探す。
///
/// 1. UDP ブロードキャスト (速い。iOS ではマルチキャスト entitlement 無しだと送れないことがある)
/// 2. 自分の IPv4 /24 サブネットへの HTTP スキャン (確実。iOS でも動く)
///
/// 両方を並行で走らせ、見つかった順に [onFound] を呼ぶ。
class HostDiscovery {
  static Future<List<HostInfo>> scan({
    void Function(HostInfo host)? onFound,
    void Function(double progress)? onProgress,
    Duration udpWindow = const Duration(milliseconds: 1500),
  }) async {
    final found = <String, HostInfo>{};
    void add(HostInfo info) {
      if (found.containsKey(info.id)) return;
      found[info.id] = info;
      onFound?.call(info);
    }

    final locals = await _localIPv4s();
    await Future.wait([_udpBroadcast(locals, udpWindow, add), _subnetSweep(locals, add, onProgress)]);
    return found.values.toList();
  }

  static Future<List<InternetAddress>> _localIPv4s() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback && _isPrivate(a)) a,
      ];
    } catch (_) {
      return const [];
    }
  }

  static bool _isPrivate(InternetAddress a) {
    final b = a.rawAddress;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
  }

  static Future<void> _udpBroadcast(List<InternetAddress> locals, Duration window, void Function(HostInfo) add) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final payload = utf8.encode('$discoveryMagic $hostProtocolVersion');
      final targets = {
        InternetAddress('255.255.255.255'),
        for (final a in locals) InternetAddress('${a.address.substring(0, a.address.lastIndexOf('.'))}.255'),
      };
      final s = socket;
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = s.receive();
        if (datagram == null) return;
        try {
          final info = HostInfo.tryParse(jsonDecode(utf8.decode(datagram.data)), datagram.address.address);
          if (info != null) add(info);
        } catch (_) {}
      });
      // 取りこぼし対策で 3 回送る
      for (var i = 0; i < 3; i++) {
        for (final t in targets) {
          try {
            s.send(payload, t, discoveryPort);
          } catch (_) {}
        }
        await Future<void>.delayed(window ~/ 3);
      }
    } catch (_) {
      // UDP が使えない環境では HTTP スキャンに任せる
    } finally {
      socket?.close();
    }
  }

  static Future<void> _subnetSweep(
    List<InternetAddress> locals,
    void Function(HostInfo) add,
    void Function(double)? onProgress,
  ) async {
    final self = locals.map((a) => a.address).toSet();
    final targets = <String>{
      for (final a in locals)
        for (var i = 1; i < 255; i++) '${a.address.substring(0, a.address.lastIndexOf('.'))}.$i',
    }..removeAll(self);
    if (targets.isEmpty) {
      onProgress?.call(1);
      return;
    }

    final queue = targets.toList();
    var done = 0;
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final ip = queue.removeLast();
        final info = await HostClient.probe(ip, defaultHostPort, timeout: const Duration(milliseconds: 900));
        if (info != null) add(info);
        done++;
        onProgress?.call(done / targets.length);
      }
    }

    await Future.wait(List.generate(48, (_) => worker()));
  }
}
