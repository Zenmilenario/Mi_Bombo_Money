// Simulated latencies, fictitious data (23 November 2026). Three banks, four accounts, five pages of 600 ms and a cloud
// save of 500 ms: the old order (each account downloaded and saved in turn) took about 5,3 s; banks at the same time
// and one save take about 2,6 s. A real bank adds its own time, which this does not measure.
import 'dart:convert';

import 'package:doblon/bank_sync.dart';
import 'package:doblon/banking.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const page = Duration(milliseconds: 600), cloud = Duration(milliseconds: 500), connectionsDelay = Duration(milliseconds: 300);

RemoteConnection conn(String bank, List<String> accounts) => RemoteConnection(
    id: '00000000-0000-4000-8000-00000000000${bank.length}',
    bank: bank,
    validUntil: '2027-01-01',
    accounts: [for (final a in accounts) RemoteAccount(id: a, currency: 'EUR', lastFour: '0000')]);

void main() {
  test('banks are asked at the same time and saved once (simulated latencies)', () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(page);
      final second = request.url.queryParameters['continuation'] != null;
      return http.Response(
          jsonEncode({
            'balances': [],
            'transactions': [],
            'continuation': second || request.url.path.endsWith('-1') ? null : 'p2',
          }),
          200);
    });
    final api = BankingClient('token-ficticio', client: client);
    final connections = [
      conn('Banco A', ['a-1', 'a-2']),
      conn('Banco BB', ['b-1']),
      conn('Banco CCC', ['c-1']),
    ];
    final watch = Stopwatch()..start();
    await Future<void>.delayed(connectionsDelay);
    final result = await BankSynchronizer(BankSyncSchedule()).run(
        client: api,
        connections: connections,
        isLinked: (_) => true,
        incorporateAll: (feeds) async {
          await Future<void>.delayed(cloud);
          return [for (final _ in feeds) ImportResult()];
        },
        persist: () async {},
        isCurrent: () => true,
        manual: true);
    watch.stop();
    expect(result.downloaded, 4);
    expect(watch.elapsedMilliseconds, lessThan(4000), reason: 'In turn it took about 5.300 ms');
  });
}
