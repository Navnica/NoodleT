// Checks of a proxy against a local SOCKS5 server. A real one is tried too
// when NOODLET_TEST_PROXY is set to "socks5://user:password@host:port";
// without it that test is skipped.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noodlet/proxy_check.dart';
import 'package:noodlet/settings.dart';
import 'package:socks5_proxy/socks_server.dart';

void main() {
  late HttpServer site;
  late Uri page;

  setUp(() async {
    // The page fetched through the proxies.
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen(
      (request) => request.response
        ..write('hello')
        ..close(),
    );
    page = Uri.parse('http://127.0.0.1:${site.port}/');
  });

  tearDown(() => site.close(force: true));

  group('SOCKS5', () {
    late SocksServer server;
    late int port;

    setUp(() async {
      server = SocksServer(
        authHandler: (user, password) => user == 'me' && password == 'pass',
      );
      server.connections.listen((connection) => connection.forward());
      // The server keeps its sockets by port, so it gets a free one.
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = free.port;
      await free.close();
      await server.bind(InternetAddress.loopbackIPv4, port);
    });

    tearDown(() => server.closeAll());

    ProxyConfig proxy({String user = 'me', String password = 'pass'}) =>
        ProxyConfig(
          kind: ProxyKind.socks5,
          host: 'localhost',
          port: port,
          username: user,
          password: password,
        );

    test('works with the right login', () async {
      expect(await checkProxy(proxy(), target: page), ProxyCheckResult.works);
    });

    // This server just hangs up on a wrong login; most others say so,
    // which comes out as authFailed.
    test('turns a wrong login down', () async {
      expect(
        await checkProxy(proxy(password: 'wrong'), target: page),
        isNot(ProxyCheckResult.works),
      );
    });
  });

  test('a proxy that is not there fails', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    String? detail;
    final result = await checkProxy(
      ProxyConfig(kind: ProxyKind.socks5, host: '127.0.0.1', port: port),
      target: page,
      detail: (text) => detail = text,
    );
    expect(result, ProxyCheckResult.failed);
    expect(detail, isNotEmpty);
  });

  final real = Platform.environment['NOODLET_TEST_PROXY'] ?? '';
  test(
    'works through the real proxy',
    () async {
      final uri = Uri.parse(real);
      final login = uri.userInfo.split(':');
      final proxy = ProxyConfig(
        kind: ProxyKind.socks5,
        host: uri.host,
        port: uri.port,
        username: Uri.decodeComponent(login.first),
        password: login.length > 1
            ? Uri.decodeComponent(login.skip(1).join(':'))
            : '',
      );
      expect(await checkProxy(proxy), ProxyCheckResult.works);
      final wrong = ProxyConfig(
        kind: proxy.kind,
        host: proxy.host,
        port: proxy.port,
        username: proxy.username,
        password: '${proxy.password}-wrong',
      );
      expect(await checkProxy(wrong), ProxyCheckResult.authFailed);
    },
    skip: real.isEmpty ? 'NOODLET_TEST_PROXY is not set' : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
