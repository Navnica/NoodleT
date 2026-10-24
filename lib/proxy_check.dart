import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:socks5_proxy/exceptions.dart' as socks;
import 'package:socks5_proxy/socks_client.dart' as socks;

import 'settings.dart';

/// How a check of the proxy went.
enum ProxyCheckResult {
  /// A page came back through it.
  works,

  /// The proxy turned the login down.
  authFailed,

  /// Nothing came back: the proxy is unreachable, refuses or is too slow.
  failed,
}

/// Fetches [target] through [proxy], as the torrent traffic would go; the
/// socks5_proxy package speaks SOCKS5 for Dart's HttpClient. [detail] gets
/// the error when there is one.
Future<ProxyCheckResult> checkProxy(
  ProxyConfig proxy, {
  Uri? target,
  Duration timeout = const Duration(seconds: 15),
  void Function(String detail)? detail,
  @visibleForTesting
  Future<List<InternetAddress>> Function(String host) lookup =
      InternetAddress.lookup,
}) async {
  if (!proxy.enabled || !proxy.isValid) return ProxyCheckResult.failed;
  final host = proxy.host.trim();
  final login = proxy.username.isNotEmpty || proxy.password.isNotEmpty;
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    switch (proxy.kind) {
      case ProxyKind.socks5:
        final address = await _reachable(
          await lookup(host),
          proxy.port,
          timeout,
        );
        socks.SocksTCPClient.assignToHttpClient(client, [
          socks.ProxySettings(
            address,
            proxy.port,
            username: login ? proxy.username : null,
            password: login ? proxy.password : null,
          ),
        ]);
      case ProxyKind.none:
        return ProxyCheckResult.failed;
    }
    final request = await client
        .getUrl(target ?? Uri.parse('https://github.com/'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>();
    return ProxyCheckResult.works;
  } on Object catch (e) {
    // The SOCKS5 client says so in words only.
    if ('$e'.contains('Authentication failed')) {
      return ProxyCheckResult.authFailed;
    }
    detail?.call(_describe(e));
    return ProxyCheckResult.failed;
  } finally {
    client.close(force: true);
  }
}

/// The first of the [addresses] of a name that takes a connection on
/// [port]. A name can stand for both an IPv6 and an IPv4 address, and the
/// proxy may listen on one only: Windows, for one, gives "localhost" as ::1
/// first.
Future<InternetAddress> _reachable(
  List<InternetAddress> addresses,
  int port,
  Duration timeout,
) async {
  for (final address in addresses) {
    try {
      final socket = await Socket.connect(address, port, timeout: timeout);
      socket.destroy();
      return address;
    } on SocketException {
      // The next one may answer.
    }
  }
  // None did: the check fails on the first, with its error.
  return addresses.first;
}

String _describe(Object error) => switch (error) {
  TimeoutException() => 'timeout',
  SocketException(:final osError?) => osError.message,
  SocketException(:final message) => message,
  HttpException(:final message) => message,
  socks.SocksClientException(:final message) => message,
  _ => '$error',
};
