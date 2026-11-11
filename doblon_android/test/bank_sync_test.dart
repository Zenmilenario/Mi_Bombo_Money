import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doblon/banking.dart';
import 'package:doblon/bank_sync.dart';
import 'package:doblon/data.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteAccount account(String id) => RemoteAccount(id: id, currency: 'EUR', lastFour: '0000');
RemoteConnection connection(String bank, List<RemoteAccount> accounts) => RemoteConnection(id: bank, bank: bank, validUntil: '2027-01-01', accounts: accounts);
AccountFeed feed(RemoteConnection connection, RemoteAccount account) => AccountFeed(connection: connection, account: account, balances: [], movements: []);

class FakeBank extends BankingClient {
  FakeBank(this.download) : super('fictitious');
  final Future<AccountFeed> Function(RemoteConnection, RemoteAccount) download;
  final List<String> requests = [];
  final List<bool> userInitiatedRequests = [];
  @override
  Future<AccountFeed> feed(RemoteConnection connection, RemoteAccount account, DateTime asOf, {bool userInitiated = true}) async {
    requests.add(account.id);
    userInitiatedRequests.add(userInitiated);
    return download(connection, account);
  }
}

void main() {
  final banks = [
    connection('Banco A', [account('a1'), account('a2')]),
    connection('Banco B', [account('b')]),
    connection('Banco C', [account('c')])
  ];
  final start = DateTime.utc(2026, 11, 11, 12);

  test('rate-limit responses preserve both numeric and HTTP-date Retry-After', () async {
    for (final header in ['7200', HttpDate.format(DateTime.now().toUtc().add(const Duration(hours: 2)))]) {
      final client = BankingClient('fictitious',
          client: MockClient((request) async => http.Response('{"error":"bank_rate_limited"}', 429, headers: {'retry-after': header})));
      addTearDown(client.close);
      try {
        await client.connections();
        fail('A throttle must not appear as a successful empty connection list');
      } on BankingError catch (error) {
        expect(error.code, 'bank_rate_limited');
        expect(error.retryAfter!.inSeconds, inInclusiveRange(7190, 7200));
      }
    }
  });

  test('a failure in the first bank or its cloud commit leaves every other account eligible', () async {
    for (final failCommit in [false, true]) {
      final client = FakeBank((bank, account) async {
        if (!failCommit && account.id == 'a1') throw BankingError('bank_unavailable');
        return feed(bank, account);
      });
      addTearDown(client.close);
      final saved = <String>[];
      final result = await BankSynchronizer(BankSyncSchedule()).run(
          client: client,
          connections: banks,
          isLinked: (_) => true,
          incorporate: (feed, _) async {
            if (failCommit && feed.account.id == 'a1') throw StateError('fictitious save failure');
            saved.add(feed.account.id);
            return ImportResult(inserted: 1);
          },
          persist: () async {},
          isCurrent: () => true,
          clock: () => start);
      expect(saved, ['a2', 'b', 'c']);
      expect(result.downloaded, 3);
      expect(result.errors.keys, ['Banco A']);
      expect(client.userInitiatedRequests, everyElement(isFalse));
    }
  });

  test('a middle-bank throttle stops that bank only and survives reopening, including manual retries', () async {
    var now = start;
    final schedule = BankSyncSchedule();
    final client = FakeBank((bank, account) async {
      if (bank.bank == 'Banco A') throw BankingError('bank_rate_limited', retryAfter: const Duration(hours: 8));
      return feed(bank, account);
    });
    addTearDown(client.close);
    final order = [banks[1], banks[0], banks[2]];
    Future<BankSyncResult> run(BankSyncSchedule state, {bool manual = false}) => BankSynchronizer(state).run(
        client: client,
        connections: order,
        isLinked: (_) => true,
        incorporate: (_, __) async => ImportResult(),
        persist: () async {},
        isCurrent: () => true,
        clock: () => now,
        manual: manual);
    await run(schedule);
    expect(client.requests, ['b', 'a1', 'c']);
    final reopened = BankSyncSchedule()..load(jsonDecode(jsonEncode(schedule.toJson())) as Map<String, dynamic>);
    now = now.add(const Duration(hours: 1));
    client.requests.clear();
    await run(reopened, manual: true);
    expect(client.requests, ['b', 'c']);
    now = start.add(const Duration(hours: 8));
    client.requests.clear();
    await run(reopened);
    expect(client.requests, contains('a1'));
  });

  test('success waits six hours; manual refresh waits at least one minute; unlinked accounts are never queried', () async {
    var now = start;
    final client = FakeBank((bank, account) async => feed(bank, account));
    addTearDown(client.close);
    final sync = BankSynchronizer(BankSyncSchedule());
    Future<void> run({bool manual = false}) => sync.run(
        client: client,
        connections: banks,
        isLinked: (a) => a.id == 'b',
        incorporate: (_, __) async => ImportResult(),
        persist: () async {},
        isCurrent: () => true,
        clock: () => now,
        manual: manual);
    await run();
    await run(manual: true);
    expect(client.requests, ['b']);
    now = now.add(const Duration(minutes: 1));
    await run();
    expect(client.requests, ['b']);
    await run(manual: true);
    expect(client.requests, ['b', 'b']);
    expect(client.userInitiatedRequests.last, isTrue);
    now = now.add(const Duration(hours: 6));
    await run();
    expect(client.requests.length, 3);
  });

  test('simultaneous openings issue a single request and a profile change stops further accounts', () async {
    final gate = Completer<void>();
    var current = true;
    final client = FakeBank((bank, account) async {
      await gate.future;
      return feed(bank, account);
    });
    addTearDown(client.close);
    final sync = BankSynchronizer(BankSyncSchedule());
    Future<BankSyncResult> run() => sync.run(
        client: client,
        connections: banks,
        isLinked: (_) => true,
        incorporate: (_, __) async => ImportResult(),
        persist: () async {},
        isCurrent: () => current,
        clock: () => start);
    final first = run();
    await Future<void>.delayed(Duration.zero);
    await run();
    expect(client.requests, ['a1']);
    current = false;
    gate.complete();
    expect((await first).downloaded, 0);
    expect(client.requests, ['a1']);
  });

  test('bank schedules and complete review feeds survive disk writes and stay isolated by profile', () async {
    final folder = await Directory.systemTemp.createTemp('doblon-bank-sync');
    addTearDown(() => folder.delete(recursive: true));
    final store = LocalStore(folder);
    final savedFeed = feed(banks.first, banks.first.accounts.first);
    await Future.wait([
      store.saveBankState('one', {
        'next': {'a': 1}
      }),
      store.saveBankState('one', {
        'next': {'a': 2},
        'feed': savedFeed.toJson()
      }),
    ]);
    final reopened = await LocalStore(folder).loadBankState('one');
    expect((reopened['next'] as Map)['a'], 2);
    expect(AccountFeed.fromJson(reopened['feed'] as Map<String, dynamic>).account.id, 'a1');
    expect(await store.loadBankState('two'), isEmpty);
    await store.clear('one');
    expect(await store.loadBankState('one'), isEmpty);
  });
}
