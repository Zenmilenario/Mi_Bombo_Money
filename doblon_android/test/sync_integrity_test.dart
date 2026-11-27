// Fictitious data only. Integrity and sync (27 November 2026):
//  1. an instalment is paid once whatever happens (repeated confirmation, retry, two devices, other amounts); if two
//     payments ever end up linked to one instalment, balance, paid and pending count the same payments;
//  2. finance documents are sealed in a newer format the server can protect (older clients cannot write over it);
//  3. the local queue: a damaged queue is kept and recovered, never taken as empty; each kind of failure is told
//     apart; what needs the person is not retried in a loop; a refused change is set aside without losing the rest;
//     an upload accepted whose answer was lost is retried without duplicating anything.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/banking.dart' show BankingError;
import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/installments.dart';
import 'package:doblon/models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final now = DateTime(2026, 11, 27, 10);

InstallmentPlan plan({bool recorded = false}) => InstallmentPlan(
      id: 'plan-ficticio',
      name: 'Sofá ficticio',
      kind: InstallmentKind.purchase,
      totalMinor: 120000,
      schedule: buildSchedule(120000, 12, DateTime(2026, 11, 5, 12))!,
      accountId: 'cuenta',
      alreadyRecorded: recorded,
      costsMinor: recorded ? 6000 : 0,
    );

Map<String, dynamic> document(InstallmentPlan p, [List<Map<String, dynamic>> rows = const []]) => {
      'formatVersion': 2,
      'accounts': [
        {'id': 'cuenta', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'openingBalanceMinor': 0}
      ],
      'installmentPlans': [
        {
          'id': p.id,
          'name': p.name,
          'kindRaw': p.kind.name,
          'totalMinor': p.totalMinor,
          'installmentCount': p.count,
          'firstDueDate': 0,
          'accountID': p.accountId,
          'alreadyRecorded': p.alreadyRecorded,
          'costsMinor': p.costsMinor,
          'paidBeforeCount': 0,
          'paidBeforeMinor': 0,
          'schedule': scheduleJson(p.schedule),
          'isArchived': false,
          'notes': '',
        }
      ],
      'transactions': rows,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  group('1. an instalment is identified by its plan and number, never by its amount', () {
    test('confirming twice or retrying records it once', () {
      final p = plan();
      final doc = document(p);
      final op = paymentOperation(p, 1, 10000, DateTime(2026, 11, 5), now, Finances.fromDocument(doc))!;
      expect(applyOperation(doc, op), isTrue);
      expect(applyOperation(doc, op), isFalse, reason: 'A retry of the same upload is not applied twice');
      expect(paymentOperation(p, 1, 10000, DateTime(2026, 11, 5), now, Finances.fromDocument(doc)), isNull, reason: 'A second confirmation is refused');
      expect((doc['transactions'] as List), hasLength(1));
    });

    test('two devices paying the same instalment, with different amounts: one payment, the same in balance and plan', () {
      final p = plan();
      final stale = Finances.fromDocument(document(p)); // both devices see it unpaid
      final phone = paymentOperation(p, 1, 10000, DateTime(2026, 11, 5), now, stale)!;
      final tablet = paymentOperation(p, 1, 12000, DateTime(2026, 11, 6), now, stale)!;
      expect(phone.data['record']['id'], tablet.data['record']['id'], reason: 'The same id on every device');
      final doc = document(p);
      applyOperation(doc, phone);
      expect(applyOperation(doc, tablet), isFalse, reason: 'The second upload finds it already recorded');
      final d = Finances.fromDocument(doc);
      final progress = installmentProgress(p, d, now);
      expect(progress.paidCount, 1);
      expect(progress.paidMinor, 10000);
      expect(FinanceCalculator(d).balance(d.accounts.single, now), -10000, reason: 'The balance moved by the same payment the plan shows');
    });

    test('a bank charge and a payment by hand on another device: both count everywhere, shown for review, nothing deleted', () {
      final p = plan();
      final stale = Finances.fromDocument(document(p, [
        {'id': 'banco', 'date': 0, 'typeRaw': 'expense', 'amountMinor': 10500, 'descriptionText': 'CARGO FICTICIO', 'sourceAccountID': 'cuenta', 'bankEntryKey': 'enable-entry:b'}
      ]));
      final charge = stale.transactions.single;
      final link = linkOperation(p, 1, charge, now, stale)!;
      final manual = paymentOperation(p, 1, 10000, DateTime(2026, 11, 5), now, stale)!;
      final doc = document(p, [
        {'id': 'banco', 'date': 0, 'typeRaw': 'expense', 'amountMinor': 10500, 'descriptionText': 'CARGO FICTICIO', 'sourceAccountID': 'cuenta', 'bankEntryKey': 'enable-entry:b'}
      ]);
      applyOperation(doc, link);
      applyOperation(doc, manual);
      final d = Finances.fromDocument(doc);
      final progress = installmentProgress(p, d, now);
      expect(progress.paidTwice.single.number, 1);
      expect(progress.paidMinor, 20500, reason: 'Paid counts both, as the balance does');
      expect(FinanceCalculator(d).balance(d.accounts.single, now), -20500);
      expect(installmentNotes(d, now).where((n) => n.id.contains(':twice:')), hasLength(1), reason: 'Shown for review');
      expect(linkOperation(p, 1, charge, now, d), isNull, reason: 'Not linked again while the instalment has another payment');
      expect(paymentOperation(p, 1, 10000, now, now, d), isNull);
      expect(d.transactions, hasLength(2), reason: 'Nothing deleted on its own');
    });

    test('editing the amount of a payment keeps its instalment and updates the share that is spending', () {
      final p = plan(recorded: true);
      final doc = document(p);
      applyOperation(doc, paymentOperation(p, 1, 10000, DateTime(2026, 11, 5), now, Finances.fromDocument(doc))!);
      final d = Finances.fromDocument(doc);
      final payment = d.transactions.single;
      final draft = TransactionDraft(
          date: payment.date, type: payment.type, amountMinor: 12000, description: payment.descriptionText, sourceAccountId: payment.sourceAccountId);
      final edit = saveOperation(draft, d, now, editing: payment);
      expect(edit.data['fields']['externalID'], installmentLink(p, 1, 12000));
      applyOperation(doc, edit);
      expect(installmentProgress(p, Finances.fromDocument(doc), now).states.first.payment!.amountMinor, 12000);
    });
  });

  group('2. finance documents carry a format the server can protect', () {
    test('finance is sealed as version 2 and read in both versions; learning stays version 1; newer formats are refused', () async {
      final cipher = CloudCipher(List.generate(32, (i) => i), '00000000-0000-4000-8000-000000000099');
      final finance = await cipher.seal({'formatVersion': 2}, 'owner', 'workspace', 'finance', 3);
      final learning = await cipher.seal({'version': 1}, 'owner', 'workspace', 'learning', 3);
      expect((finance['v'], learning['v']), (2, 1));
      expect(await cipher.open(finance, 'owner', 'workspace', 'finance', 3), {'formatVersion': 2});
      final older = await cipher.seal({'formatVersion': 2}, 'owner', 'workspace', 'learning', 3); // a v1 envelope
      expect(await cipher.open(older, 'owner', 'workspace', 'learning', 3), {'formatVersion': 2});
      await expectLater(cipher.open({...finance, 'v': 3}, 'owner', 'workspace', 'finance', 3), throwsFormatException);
      await expectLater(cipher.open({...learning, 'v': 2}, 'owner', 'workspace', 'learning', 3), throwsFormatException);
    });
  });

  group('3. the local queue and sync failures', () {
    test('each failure is told apart, without exposing data', () {
      expect(classifySyncError(const AuthException('expired')), SyncProblem.sessionExpired);
      expect(classifySyncError(const PostgrestException(message: 'cloud_revision_conflict', code: '40001')), SyncProblem.conflict);
      expect(classifySyncError(const PostgrestException(message: 'client_outdated', code: '22023')), SyncProblem.outdatedClient);
      expect(classifySyncError(const PostgrestException(message: 'Missing entity array: installmentPlans', code: '22023')), SyncProblem.outdatedClient);
      expect(classifySyncError(const PostgrestException(message: 'Invalid record', code: '22023')), SyncProblem.rejected);
      expect(classifySyncError(const PostgrestException(message: 'Key mismatch', code: '42501')), SyncProblem.permission);
      expect(classifySyncError(http.ClientException('fictitious offline')), SyncProblem.offline);
      expect(classifySyncError(BankingError('cloud_conflict')), SyncProblem.conflict);
      expect([for (final p in SyncProblem.values) if (p.retriedAlone) p], [SyncProblem.offline, SyncProblem.conflict]);
    });

    test('a damaged queue is kept privately and what can be read in order is recovered; never taken as empty', () async {
      final dir = await Directory.systemTemp.createTemp('doblon-queue');
      addTearDown(() => dir.delete(recursive: true));
      final store = LocalStore(dir);
      final first = upsertOperation('accounts', {'id': 'cuenta', 'notes': 'Primero'}, create: false);
      final second = upsertOperation('accounts', {'id': 'cuenta', 'notes': 'Segundo'}, create: false);
      final whole = jsonEncode([first.toJson(), second.toJson(), first.toJson()]);
      final damaged = whole.substring(0, whole.length - 25); // a crash cut the third change
      await File('${dir.path}/pending-usuario.json').writeAsString(damaged);
      final (ops, damage) = await store.readPending('usuario');
      expect(ops.map((o) => o.data['record']['notes']), ['Primero', 'Segundo'], reason: 'In order, up to the first unreadable change');
      expect((damage!.recovered, damage.reason), (2, 'corrupt'));
      expect(await File(damage.copyPath).readAsString(), damaged, reason: 'The damaged queue is kept as it was');
      // A queue that is fine is read as before; no queue is an empty one, without damage.
      await store.savePending('usuario', [first]);
      expect((await store.readPending('usuario')).$2, isNull);
      final (none, noDamage) = await store.readPending('otro');
      expect(none, isEmpty);
      expect(noDamage, isNull);
    });

    group('with a cloud that refuses one change or loses an answer', () {
      late Directory dir;
      late Map<String, dynamic> cloudDoc;
      late int revision, saves;
      var loseNextAnswer = false;
      var online = true;
      setUp(() async {
        dir = await Directory.systemTemp.createTemp('doblon-sync');
        cloudDoc = document(plan());
        revision = 1;
        saves = 0;
        loseNextAnswer = false;
        online = true;
      });
      tearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      Future<FinanceRepository> device() async {
        http.Response json(Object value, http.Request r, [int status = 200]) =>
            http.Response(jsonEncode(value), status, request: r, headers: {'content-type': 'application/json'});
        final transport = MockClient((r) async {
          if (!online) throw http.ClientException('fictitious offline');
          final name = r.url.pathSegments.last;
          if (name == 'finance_privacy_profile') return json({'encryption_required': false, 'workspace_id': 'ws', 'key_check': null}, r);
          if (name == 'finance_snapshot') return json({'workspace_id': 'ws', 'revision': revision, 'document': cloudDoc}, r);
          if (name == 'finance_save_snapshot') {
            final body = jsonDecode(r.body) as Map;
            if (body['p_expected_revision'] != revision) return json({'message': 'cloud_revision_conflict', 'code': '40001'}, r, 409);
            final next = Map<String, dynamic>.from(body['p_document'] as Map);
            // The server's validation: a fictitious record it refuses.
            if ((next['transactions'] as List).any((t) => (t as Map)['descriptionText'] == 'RECHAZADO')) {
              return json({'message': 'Invalid record', 'code': '22023'}, r, 400);
            }
            cloudDoc = next;
            revision++;
            saves++;
            if (loseNextAnswer) {
              loseNextAnswer = false;
              throw http.ClientException('fictitious: saved, answer lost');
            }
            return json({'workspace_id': 'ws', 'revision': revision, 'document': cloudDoc}, r);
          }
          return json({'message': 'unavailable', 'code': '42883'}, r, 404);
        });
        final client = SupabaseClient('https://fictitious.invalid', 'key', httpClient: transport, authOptions: const AuthClientOptions(autoRefreshToken: false));
        addTearDown(client.dispose);
        await client.auth.setInitialSession(jsonEncode({
          'access_token': 'fictitious',
          'token_type': 'bearer',
          'user': {'id': 'usuario', 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z', 'app_metadata': {}, 'user_metadata': {}}
        }));
        final repo = FinanceRepository(store: LocalStore(dir), cloudClient: client);
        addTearDown(repo.dispose);
        await repo.refresh();
        return repo;
      }

      Operation income(String id, String text) => Operation('insert', {
            'record': {'id': id, 'date': 0, 'typeRaw': 'income', 'amountMinor': 1500, 'descriptionText': text, 'sourceAccountID': 'cuenta'}
          });

      test('a refused change: the ones before it are saved, it is not retried in a loop, and it can be set aside', () async {
        final repo = await device();
        online = false;
        await repo.apply(income('a', 'ABONO FICTICIO A'));
        await repo.apply(income('b', 'RECHAZADO'));
        await repo.apply(income('c', 'ABONO FICTICIO C'));
        online = true;
        await repo.refresh();
        expect(repo.syncProblem, SyncProblem.rejected);
        expect([for (final t in cloudDoc['transactions'] as List) (t as Map)['id']], ['a'], reason: 'Saved up to the refused change, in order');
        expect(repo.pending.map((o) => o.data['record']['id']), ['b', 'c']);
        expect(repo.rejectedAt, 0);
        expect(repo.finances!.transactions.map((t) => t.id), containsAll(['a', 'b', 'c']), reason: 'Still shown on this device');
        final before = saves;
        await repo.refresh();
        await repo.apply(income('d', 'ABONO FICTICIO D'));
        expect(saves, before, reason: 'Not retried on its own, and later changes wait in order behind it');
        expect(repo.error, SyncProblem.rejected.message);
        await repo.setAsideRejected();
        expect([for (final t in cloudDoc['transactions'] as List) (t as Map)['id']], ['a', 'c', 'd']);
        expect(repo.pending, isEmpty);
        expect(repo.syncProblem, isNull);
        final kept = jsonDecode(await File('${dir.path}/rejected-usuario.json').readAsString()) as List;
        expect((kept.single as Map)['data']['record']['id'], 'b', reason: 'Set aside, not deleted');
      });

      test('an upload accepted whose answer was lost, then retried: nothing is duplicated', () async {
        final repo = await device();
        loseNextAnswer = true;
        await repo.apply(income('ingreso-25', 'ABONO FICTICIO'));
        expect(repo.syncProblem, SyncProblem.offline);
        expect(repo.pending, hasLength(1), reason: 'Kept: the device cannot know it was saved');
        await repo.refresh();
        expect(repo.pending, isEmpty);
        expect((cloudDoc['transactions'] as List).where((t) => (t as Map)['id'] == 'ingreso-25'), hasLength(1));
      });

      test('an income received while offline survives a restart and is uploaded once', () async {
        final repo = await device();
        online = false;
        await repo.apply(income('ingreso-25', 'ABONO FICTICIO'));
        expect(repo.pending, hasLength(1));
        online = true;
        final again = await device(); // the app opened again on the same device
        expect(again.pending, isEmpty);
        expect(again.finances!.transactions.where((t) => t.id == 'ingreso-25'), hasLength(1));
        expect((cloudDoc['transactions'] as List).where((t) => (t as Map)['id'] == 'ingreso-25'), hasLength(1));
      });
    });
  });
}
