import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' hide Category;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'bank_activity.dart';
import 'banking.dart';
import 'bank_sync.dart';
import 'forecast_store.dart';
import 'edits.dart';
import 'contributions.dart';
import 'assistant.dart' show AssistantIntent, RemoteInterpretation;
import 'auto_category.dart';
import 'reconcile.dart' show ReconcileStore, joinOperation, unequivocalRepeat;
import 'learning.dart';
import 'models.dart';
import 'cloud_privacy.dart';

/// Same cloud project and public key as the iPhone app (`CloudConfiguration.json`). The publishable key
/// is public by design: every table is protected per user by row-level security.
const supabaseUrl = 'https://coeicjffmpclqowsqeys.supabase.co';
const supabasePublishableKey = 'sb_publishable_ybkbyweHXrOHRUugSwpBgw_J4Wcfq5U';

/// The cloud copy as `finance_snapshot` returns it: the raw document is kept so that saving back never
/// drops a field the iPhone stores.
class CloudCopy {
  CloudCopy(this.workspaceId, this.revision, this.document);
  final String workspaceId;
  final int revision;
  final Map<String, dynamic> document;

  static CloudCopy parse(dynamic response) {
    final map = Map<String, dynamic>.from(response as Map);
    return CloudCopy('${map['workspace_id']}', (map['revision'] as num).toInt(), Map<String, dynamic>.from(map['document'] as Map));
  }

  Map<String, dynamic> toJson() => {'workspace_id': workspaceId, 'revision': revision, 'document': document};
}

/// Keeps the last cloud copy and the changes not yet uploaded on this device, per user, in the app's private
/// storage. With it the app opens and works without connection; changes are uploaded when it returns.
class LocalStore {
  LocalStore(this.directory);
  final Directory directory;
  final Map<String, Future<void>> _diskWrites = {};

  File _file(String user, String name) => File('${directory.path}${Platform.pathSeparator}$name-$user.json');

  Future<CloudCopy?> loadCopy(String user) async {
    try {
      return CloudCopy.parse(jsonDecode(await _file(user, 'cloud').readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<List<Operation>> loadPending(String user) async {
    try {
      final list = jsonDecode(await _file(user, 'pending').readAsString()) as List;
      return [for (final item in list) Operation.fromJson(Map<String, dynamic>.from(item as Map))];
    } catch (_) {
      return [];
    }
  }

  /// Written to a temporary file and renamed, so a crash never leaves half a file.
  Future<void> _write(File file, Object value) {
    final text = jsonEncode(value);
    final task = (_diskWrites[file.path] ?? Future<void>.value()).then((_) async {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
    _diskWrites[file.path] = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<void> saveCopy(String user, CloudCopy copy) => _write(_file(user, 'cloud'), copy.toJson());
  Future<void> savePending(String user, List<Operation> pending) => _write(_file(user, 'pending'), [for (final op in pending) op.toJson()]);

  Future<Map<String, dynamic>> loadBankState(String user) async {
    final file = _file(user, 'bank-sync');
    if (!await file.exists()) return {};
    return Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
  }

  Future<void> saveBankState(String user, Map<String, dynamic> value) => _write(_file(user, 'bank-sync'), value);

  /// The portfolios taken out of the investment summary on this device by version 0.35.2, before the choice was saved
  /// in the cloud with each account. Only read to move it there once.
  Future<Set<String>> loadHiddenPortfolios(String user) async {
    try {
      return {for (final id in jsonDecode(await _file(user, 'portfolios').readAsString()) as List) '$id'};
    } catch (_) {
      return {};
    }
  }

  Future<void> saveHiddenPortfolios(String user, Set<String> ids) => _write(_file(user, 'portfolios'), ids.toList()..sort());

  Future<void> clear(String user) async {
    for (final name in ['cloud', 'pending', 'bank-sync', 'forecast', 'portfolios']) {
      final file = _file(user, name);
      await _diskWrites[file.path];
      if (await file.exists()) await file.delete();
    }
  }
}

/// Downloads and saves the person's finances with the same functions the iPhone uses to sync.
/// What Don Bigotes is doing, taken only from real work: asking the banks, saving to the cloud, reading the cloud
/// copy, and how the last bank refresh ended (a short moment, then back to idle).
enum CompanionMood { idle, thinking, saving, reading, happy, worried }

class FinanceRepository extends ChangeNotifier {
  FinanceRepository({LocalStore? store, SupabaseClient? cloudClient})
      : _store = store,
        _cloud = cloudClient {
    bankProgress.addListener(_updateMood);
  }

  final companionMood = ValueNotifier(CompanionMood.idle);
  int _saving = 0;
  CompanionMood? _moment;
  Timer? _momentTimer;

  void _updateMood() {
    if (_disposed) return;
    companionMood.value = bankProgress.value != null
        ? CompanionMood.thinking
        : _saving > 0
            ? CompanionMood.saving
            : loading
                ? CompanionMood.reading
                : _moment ?? CompanionMood.idle;
  }

  /// How a bank refresh ended, shown for a moment: pleased when it worked, ears back when a bank failed.
  void _showOutcome(BankSyncResult? result) {
    final mood = switch (result?.outcome) {
      BankSyncOutcome.updated || BankSyncOutcome.noChanges => CompanionMood.happy,
      BankSyncOutcome.partial || BankSyncOutcome.failed || BankSyncOutcome.waiting => CompanionMood.worried,
      _ => null,
    };
    if (mood == null || _disposed) return;
    _moment = mood;
    _momentTimer?.cancel();
    _momentTimer = Timer(Duration(milliseconds: mood == CompanionMood.happy ? 1500 : 4000), () {
      _moment = null;
      _updateMood();
    });
    _updateMood();
  }

  LocalStore? _store;
  final SupabaseClient? _cloud;
  SupabaseClient get _client => _cloud ?? Supabase.instance.client;
  Finances? finances;
  CloudCopy? copy;
  List<Operation> pending = [];
  String? error;
  bool loading = false;
  DateTime? loadedAt;
  bool _opened = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void> _writes = Future.value();
  final bankSchedule = BankSyncSchedule();
  late final _bankSync = BankSynchronizer(bankSchedule);
  List<RemoteConnection> bankConnections = [];
  BankSyncResult? bankResult;
  final Map<String, Map<String, dynamic>> _bankReviews = {};

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  String? get _user => _client.auth.currentUser?.id;

  /// The signed-in person (for choices kept per person on this device, such as the assistant's interpreter).
  String? get userId => _user;

  /// Don Bigotes' interpreter on the server, with this person's session. Never throws: an error is returned so the
  /// conversation goes on with its own rules.
  Future<RemoteInterpretation> interpretRemotely(Map<String, Object?> context, {BankingClient? client}) async {
    final token = client == null ? _client.auth.currentSession?.accessToken : null;
    if (client == null && token == null) return (intent: null, error: 'unauthorized');
    final api = client ?? BankingClient(token!);
    try {
      final answer = await api.interpret(context);
      final intent = AssistantIntent.fromJson(answer['intent']);
      return (intent: intent, error: intent == null ? 'assistant_invalid' : null);
    } on BankingError catch (error) {
      return (intent: null, error: error.code);
    } catch (_) {
      return (intent: null, error: 'assistant_unavailable');
    } finally {
      if (client == null) api.close();
    }
  }

  Future<LocalStore> _local() async => _store ??= LocalStore(await getApplicationSupportDirectory());

  /// The developer's account, the only one exempt from encrypting (`finance_private.developer_plaintext_users`), sees
  /// the administrator tools; guests always encrypt. It only hides what a guest does not need: what each person may
  /// do is limited by the server and the database.
  bool isAdministrator = false;

  CloudPrivacy? _privacySession;
  Future<CloudPrivacy> _privacy() async {
    var session = CloudPrivacy.sessions[_user];
    if (session == null) {
      session = _privacySession ??= CloudPrivacy(_client);
      if (!await session.prepare()) throw StateError('Desbloquea tus datos con el código de recuperación.');
    }
    isAdministrator = !session.encrypted;
    return session;
  }
  Future<CloudCopy> _fetch() async => CloudCopy.parse(await (await _privacy()).fetch('finance'));

  /// Shows the device copy at once, then uploads pending changes and downloads the latest cloud copy.
  Future<void> refresh() async {
    if (loading) return;
    final user = _user;
    if (user == null) return;
    final generation = _generation;
    loading = true;
    error = null;
    _updateMood();
    notifyListeners();
    try {
      if (!_opened) {
        final store = await _local();
        final savedPending = await store.loadPending(user);
        final saved = await store.loadCopy(user);
        if (_disposed || generation != _generation || user != _user) return;
        pending = savedPending;
        if (saved != null) _show(saved);
        learning = await Learning.open(store.directory, user)
          // What is taught here reaches the person's other devices a moment later.
          ..onChange = _scheduleLearningSync;
        bankActivity = await BankActivityStore(store.directory).load(user);
        await AutoCategoryStore.instance.load(user).catchError((_) {});
        _hiddenOnDevice = await store.loadHiddenPortfolios(user);
        forecast = await ForecastStore.open(store.directory, user)
          ..addListener(notifyListeners);
        final bankState = await store.loadBankState(user);
        if (_disposed || generation != _generation || user != _user) return;
        bankSchedule.load(bankState);
        if (bankState['reviews'] is Map) {
          for (final entry in (bankState['reviews'] as Map).entries) {
            _bankReviews['${entry.key}'] = Map<String, dynamic>.from(entry.value as Map);
          }
          _reviewsVersion++;
        }
        _opened = true;
      }
      if (pending.isNotEmpty) {
        await _upload();
      } else {
        final fetched = await _fetch();
        if (_disposed || generation != _generation || user != _user) return;
        await _adopt(fetched);
      }
      unawaited(syncLearning());
      unawaited(_moveDeviceChoiceToCloud());
      unawaited(applyAutoCategories());
    } on AuthException {
      error = 'Tu sesión ha caducado. Vuelve a entrar.';
    } catch (_) {
      error = copy == null
          ? 'No se han podido cargar tus finanzas. Comprueba la conexión y vuelve a intentarlo.'
          : 'Sin conexión: ves la última copia de este dispositivo.';
    } finally {
      loading = false;
      _updateMood();
      notifyListeners();
    }
  }

  /// The cloud document with the pending changes applied: what the screens show and the forms edit.
  Map<String, dynamic>? document;

  void _show(CloudCopy value) {
    copy = value;
    document = withPending(value.document, pending);
    finances = Finances.fromDocument(document!);
  }

  Future<void> _adopt(CloudCopy value) async {
    _show(value);
    loadedAt = DateTime.now();
    final user = _user;
    if (user != null) await (await _local()).saveCopy(user, value);
  }

  /// Applies `change` to the latest cloud document and saves it with the expected revision. If another
  /// device saved in between, the cloud refuses (revision conflict): the change is applied again on the
  /// new document, up to three times, so nothing saved elsewhere is overwritten.
  Future<T> update<T>((Map<String, dynamic>, T) Function(Map<String, dynamic> document) change) {
    final user = _user, generation = _generation;
    final task = _writes.then((_) async {
      _saving++;
      _updateMood();
      try {
        return await _update(change, user, generation);
      } finally {
        _saving--;
        _updateMood();
      }
    });
    _writes = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<T> _update<T>((Map<String, dynamic>, T) Function(Map<String, dynamic>) change, String? user, int generation) async {
    void checkProfile() {
      if (_disposed || generation != _generation || user == null || user != _user) throw BankingError('unauthorized');
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      checkProfile();
      final current = await _fetch();
      checkProfile();
      final (document, result) = change(current.document);
      try {
        final saved = await (await _privacy()).save('finance', current.workspaceId, current.revision, document);
        checkProfile();
        await _adopt(CloudCopy.parse(saved));
        notifyListeners();
        return result;
      } on PostgrestException catch (error) {
        if (error.code == '40001' || error.message.contains('cloud_revision_conflict')) continue;
        rethrow;
      }
    }
    throw BankingError('cloud_conflict');
  }

  /// Records a change: it shows at once, is kept on the device and is uploaded as soon as possible.
  Future<void> apply(Operation op) async {
    final user = _user;
    if (user == null) return;
    pending = [...pending, op];
    await (await _local()).savePending(user, pending);
    if (copy != null) _show(copy!);
    notifyListeners();
    try {
      await _upload();
    } catch (_) {
      error = 'Guardado en este dispositivo. Se subirá a tu nube cuando haya conexión.';
      notifyListeners();
    }
  }

  bool _uploading = false;
  bool _again = false;

  /// One upload at a time; a change made during an upload is sent right after it.
  Future<void> _upload() async {
    final user = _user;
    if (user == null || pending.isEmpty) return;
    if (_uploading) {
      _again = true;
      return;
    }
    _uploading = true;
    try {
      do {
        _again = false;
        final sending = List<Operation>.from(pending);
        await update((document) => (withPending(document, sending), null));
        // Only what was sent is cleared: a change made meanwhile stays queued.
        pending = [for (final op in pending) if (!sending.any((sent) => identical(sent, op))) op];
        await (await _local()).savePending(user, pending);
        if (copy != null) _show(copy!);
        error = null;
        notifyListeners();
      } while (_again && pending.isNotEmpty);
    } finally {
      _uploading = false;
    }
  }

  String newId() => const Uuid().v4();

  /// What the person has taught the models on this device and profile (null until the first load).
  Learning? learning;

  /// Forecast assumptions and simulations, kept on this device apart from the finances (null until the first load).
  ForecastStore? forecast;

  /// A choice made on this device by version 0.35.2, waiting to be moved to the cloud.
  Set<String> _hiddenOnDevice = {};

  /// Shows a portfolio in the investment summary or takes it out. Saved with the account in the cloud, so every
  /// device of the person shows the same summary; net worth is decided apart and does not change.
  Future<void> setPortfolioInSummary(String accountId, bool shown) =>
      apply(upsertOperation('accounts', {'id': accountId, 'inInvestmentSummary': shown, 'updatedAt': referenceSeconds(DateTime.now())}, create: false));

  /// Moves once the choice kept on this device by 0.35.2 to the accounts in the cloud, for the portfolios that do not
  /// have one there yet, and then forgets the local copy.
  Future<void> _moveDeviceChoiceToCloud() async {
    final user = _user, data = finances;
    if (_hiddenOnDevice.isEmpty || user == null || data == null) return;
    final now = referenceSeconds(DateTime.now());
    final ops = [
      for (final a in data.accounts)
        if (_hiddenOnDevice.contains(a.id) && a.type == AccountType.investment && a.inInvestmentSummary == null)
          upsertOperation('accounts', {'id': a.id, 'inInvestmentSummary': false, 'updatedAt': now}, create: false)
    ];
    _hiddenOnDevice = {};
    await (await _local()).saveHiddenPortfolios(user, {});
    if (ops.isNotEmpty) await apply(ops.length == 1 ? ops.single : batchOperation(ops));
  }

  /// The last bank report of each linked account (holds, balances, what it sent), by bank identity.
  Map<String, BankActivity> bankActivity = {};

  /// Keeps what each downloaded account reported, replacing that account's previous report.
  Future<void> recordBankActivity(List<AccountFeed> feeds, DateTime observedAt) async {
    final user = _user;
    if (user == null || feeds.isEmpty) return;
    bankActivity = {
      ...bankActivity,
      for (final feed in feeds) accountIdentity(feed.account.id): feed.activity(observedAt),
    };
    await BankActivityStore((await _local()).directory).save(user, bankActivity);
    notifyListeners();
  }

  /// Categorises movements and teaches the choice to the models (Swift `TransactionLearning.confirm`).
  Future<void> categorize(List<Transaction> rows, Category category) async {
    final op = categorizeOperation(rows, category, DateTime.now());
    final ids = {for (final id in op.data['ids'] as List) '$id'};
    await apply(op);
    final data = finances;
    if (data == null || learning == null) return;
    await learning!.confirmCategories(data.transactions.where((t) => ids.contains(t.id)).toList(), data);
    notifyListeners();
  }

  Timer? _learningTimer;
  bool _syncingLearning = false;
  bool _learningAgain = false;

  void _scheduleLearningSync() {
    _learningTimer?.cancel();
    _learningTimer = Timer(const Duration(seconds: 2), () => unawaited(syncLearning()));
  }

  /// Combines what was taught on this device with what the other devices taught (CloudBackend/learning-contract.md)
  /// and saves the result in both places. Without connection it waits for the next opening or change.
  Future<void> syncLearning() async {
    final learning = this.learning;
    final user = _user, generation = _generation;
    bool current() => !_disposed && user == _user && generation == _generation;
    if (learning == null || user == null || !current()) return;
    if (_syncingLearning) {
      _learningAgain = true;
      return;
    }
    _syncingLearning = true;
    try {
      do {
        _learningAgain = false;
        for (var attempt = 0; attempt < 3; attempt++) {
          final remote = await (await _privacy()).fetch('learning');
          if (!current()) return;
          final cloud = Map<String, dynamic>.from(remote['document'] as Map);
          final merged = mergeLearning(learning.toShared(), cloud);
          await learning.store(merged);
          if (!current()) return;
          if (canonicalLearningJson(merged) == canonicalLearningJson(cloud)) break;
          try {
            await (await _privacy()).save('learning', remote['workspace_id'] as String, remote['revision'] as int, merged);
            break;
          } on PostgrestException catch (error) {
            if (error.code == '40001' || error.message.contains('cloud_revision_conflict')) continue;
            rethrow;
          }
        }
      } while (_learningAgain);
      notifyListeners();
    } catch (_) {
      // Kept on this device; it is shared on the next attempt.
    } finally {
      _syncingLearning = false;
    }
  }

  /// Tells the screens that something kept outside the document changed (what was learnt, bank reports).
  void changed() => notifyListeners();

  bool _correcting = false;

  bool linked(RemoteAccount account) => finances?.accounts.any((a) => !a.isArchived && a.bankIdentityKey == accountIdentity(account.id)) ?? false;

  Future<void> _saveBankState(String user) async => (await _local()).saveBankState(user, {
        ...bankSchedule.toJson(),
        'reviews': _bankReviews,
      });

  int _reviewsVersion = 0;
  Object? _proposalsFrom;
  int _proposalsVersion = -1;
  List<BankProposal> _proposals = const [];

  /// Saved previews remain reviewable after reopening, without another request to the bank. Computed once
  /// per change of the document or of the saved reviews (the screens read it several times per frame).
  List<BankProposal> get bankProposals {
    final doc = document;
    if (doc == null) return [];
    if (identical(doc, _proposalsFrom) && _proposalsVersion == _reviewsVersion) return _proposals;
    final proposals = <BankProposal>[];
    for (final entry in _bankReviews.values) {
      final feed = AccountFeed.fromJson(entry['feed'] as Map<String, dynamic>);
      if (linked(feed.account)) proposals.addAll(importFeeds(doc, [feed], DateTime.fromMillisecondsSinceEpoch(entry['at'] as int)).$2.proposals);
    }
    _proposalsFrom = doc;
    _proposalsVersion = _reviewsVersion;
    return _proposals = proposals;
  }

  Object? _contributionsFrom;
  DateTime? _contributionsDay;
  List<ContributionProposal> _contributions = const [];

  /// Contribution proposals, computed once per version of the finances and per day.
  List<ContributionProposal> get contributions {
    final data = finances;
    if (data == null) return const [];
    final now = DateTime.now(), day = DateTime(now.year, now.month, now.day);
    if (identical(data, _contributionsFrom) && day == _contributionsDay) return _contributions;
    _contributionsFrom = data;
    _contributionsDay = day;
    return _contributions = contributionProposals(data, now);
  }

  Future<ImportResult> _incorporateFeed(AccountFeed feed, DateTime date, String user, {Map<String, String> decisions = const {}}) async {
    final generation = _generation;
    void checkProfile() {
      if (_disposed || generation != _generation || _user != user) throw BankingError('unauthorized');
    }

    checkProfile();
    final key = accountIdentity(feed.account.id);
    _bankReviews[key] = {'feed': feed.toJson(), 'at': date.millisecondsSinceEpoch, 'committed': false};
    _reviewsVersion++;
    await _saveBankState(user);
    checkProfile();
    // Changes still queued here are saved with the import; they then leave the queue so they are not applied twice.
    var included = const <Operation>[];
    final result = await update((doc) {
      included = List<Operation>.from(pending);
      return importFeeds(withPending(doc, included), [feed], date, decisions: decisions);
    });
    checkProfile();
    if (included.isNotEmpty) {
      pending = [for (final op in pending) if (!included.any((saved) => identical(saved, op))) op];
      await (await _local()).savePending(user, pending);
      if (copy != null) _show(copy!);
    }
    await recordBankActivity([feed], date);
    checkProfile();
    if (result.proposals.isEmpty) {
      _bankReviews.remove(key);
    } else {
      _bankReviews[key]!['committed'] = true;
    }
    _reviewsVersion++;
    bankSchedule.failures.remove(key);
    await _saveBankState(user);
    return result;
  }

  /// Everything downloaded in one refresh, incorporated with a single read and save of the cloud copy (one per
  /// account before). Each account stays isolated: one that cannot be imported gets its error and the rest go on.
  Future<List<Object>> _incorporateFeeds(List<(AccountFeed, DateTime)> feeds, String user) async {
    final generation = _generation;
    void checkProfile() {
      if (_disposed || generation != _generation || _user != user) throw BankingError('unauthorized');
    }

    checkProfile();
    for (final (feed, date) in feeds) {
      _bankReviews[accountIdentity(feed.account.id)] = {'feed': feed.toJson(), 'at': date.millisecondsSinceEpoch, 'committed': false};
    }
    _reviewsVersion++;
    await _saveBankState(user);
    checkProfile();
    var included = const <Operation>[];
    final outcomes = await update((doc) {
      included = List<Operation>.from(pending);
      var next = withPending(doc, included);
      final results = <Object>[];
      for (final (feed, date) in feeds) {
        try {
          final (imported, result) = importFeeds(next, [feed], date);
          next = imported;
          results.add(result);
        } catch (error) {
          results.add(error);
        }
      }
      return (next, results);
    });
    checkProfile();
    if (included.isNotEmpty) {
      pending = [for (final op in pending) if (!included.any((saved) => identical(saved, op))) op];
      await (await _local()).savePending(user, pending);
      if (copy != null) _show(copy!);
    }
    bankActivity = {
      ...bankActivity,
      for (final (i, (feed, date)) in feeds.indexed)
        if (outcomes[i] is ImportResult) accountIdentity(feed.account.id): feed.activity(date),
    };
    await BankActivityStore((await _local()).directory).save(user, bankActivity);
    checkProfile();
    for (final (i, (feed, _)) in feeds.indexed) {
      final key = accountIdentity(feed.account.id);
      final outcome = outcomes[i];
      if (outcome is ImportResult && outcome.proposals.isEmpty) {
        _bankReviews.remove(key);
      } else if (outcome is ImportResult) {
        _bankReviews[key]!['committed'] = true;
      }
      if (outcome is ImportResult) bankSchedule.failures.remove(key);
    }
    _reviewsVersion++;
    await _saveBankState(user);
    notifyListeners();
    return outcomes;
  }

  Future<void> reconcileContribution(ContributionProposal proposal, Set<String> selected) async {
    await _upload();
    if (pending.isNotEmpty) throw BankingError('network');
    final data = finances!;
    final before = {for (final row in data.transactions.where((t) => selected.contains(t.id))) row.id: learning?.captureEdit(row, data)};
    await update((document) {
      final operation = confirmContribution(proposal, selected, Finances.fromDocument(document), DateTime.now());
      return (withPending(document, [operation]), null);
    });
    final updated = finances!;
    for (final row in updated.transactions.where((t) => selected.contains(t.id))) {
      await learning?.rememberEdit(before[row.id], row, updated, explicitlyReviewed: true, contribution: true);
      await learning?.confirmKind(OperationKind.investment, row, updated);
    }
    notifyListeners();
  }

  Future<void> reviewBankDownloads(Map<String, String> decisions) async {
    final user = _user;
    if (user == null) return;
    for (final entry in List<Map<String, dynamic>>.from(_bankReviews.values)) {
      final feed = AccountFeed.fromJson(entry['feed'] as Map<String, dynamic>);
      if (!linked(feed.account)) continue;
      await _incorporateFeed(feed, DateTime.fromMillisecondsSinceEpoch(entry['at'] as int), user, decisions: decisions);
    }
    notifyListeners();
  }

  bool _synchronizingBanks = false;
  DateTime? _connectionsReadAt;

  /// What the bank refresh is doing now (null when idle): Don Bigotes shows it, also after closing and reopening him.
  final bankProgress = ValueNotifier<BankSyncProgress?>(null);
  Future<BankSyncResult?>? _bankRun;
  bool _bankRunManual = false;

  /// One refresh at a time. Pressing again joins the one in progress instead of starting another; a manual refresh
  /// asked during an automatic one runs right after it (the automatic one may skip accounts updated recently).
  Future<BankSyncResult?> synchronizeBanks({bool manual = false, String? bank, BankingClient? client}) {
    final running = _bankRun;
    if (running != null && (!manual || _bankRunManual)) return running;
    final next = (running ?? Future<BankSyncResult?>.value()).then((_) => _synchronizeBanks(manual: manual, bank: bank, client: client));
    _bankRun = next;
    _bankRunManual = manual;
    bankProgress.value = const BankSyncProgress('Consultando tus bancos…');
    next.then(_showOutcome, onError: (Object _) {});
    next.whenComplete(() {
      if (identical(_bankRun, next)) {
        _bankRun = null;
        bankProgress.value = null;
      }
    });
    return next;
  }

  Future<BankSyncResult?> _synchronizeBanks({bool manual = false, String? bank, BankingClient? client}) async {
    final user = _user, generation = _generation;
    final token = _client.auth.currentSession?.accessToken;
    if (user == null || finances == null || _synchronizingBanks || (client == null && token == null)) return bankResult;
    bool current() => !_disposed && generation == _generation && user == _user;
    // Set only once nothing can fail before the try: the flag is always released in finally.
    _synchronizingBanks = true;
    final api = client ?? BankingClient(token!);
    final watch = Stopwatch()..start();
    try {
      bankProgress.value = const BankSyncProgress('Consultando tus bancos…');
      if (manual || _connectionsReadAt == null || DateTime.now().difference(_connectionsReadAt!) >= const Duration(minutes: 1)) {
        bankConnections = await api.connections();
        _connectionsReadAt = DateTime.now();
        final replaced = supersededConnections(bankConnections);
        for (final old in replaced) {
          try {
            await api.disconnect(old.id);
          } catch (_) {/* It expires on its own; tried again on the next reading. */}
        }
        if (replaced.isNotEmpty) bankConnections = await api.connections();
      }
      if (!current()) return null;
      // A person with no account of their own gets the bank's accounts created instead of being asked to link them.
      final choices = document == null ? const <String, String>{} : automaticAccountChoices(document!, bankConnections);
      if (choices.isNotEmpty) {
        await update((document) => importFeeds(document, [
              for (final connection in bankConnections)
                for (final account in connection.accounts)
                  if (choices.containsKey(account.id)) AccountFeed(connection: connection, account: account, balances: [], movements: []),
            ], DateTime.now(), accountChoices: choices));
        if (!current()) return null;
      }
      // Retry saved previews against the latest cloud copy before asking the bank for them again.
      for (final entry in List<Map<String, dynamic>>.from(_bankReviews.values)) {
        if (entry['committed'] == true) continue;
        final feed = AccountFeed.fromJson(entry['feed'] as Map<String, dynamic>);
        if (linked(feed.account) && (bank == null || feed.connection.bank == bank)) {
          try {
            await _incorporateFeed(feed, DateTime.fromMillisecondsSinceEpoch(entry['at'] as int), user);
          } catch (_) {/* Each bank retries independently. */}
        }
      }
      final connectionsTime = watch.elapsedMilliseconds;
      final result = await _bankSync.run(
          client: api,
          connections: bankConnections,
          isLinked: linked,
          incorporateAll: (feeds) => _incorporateFeeds(feeds, user),
          persist: () => _saveBankState(user),
          isCurrent: current,
          manual: manual,
          onlyBank: bank,
          onProgress: (progress) => bankProgress.value = progress);
      if (!current()) return null;
      result.timings['Conexiones'] = connectionsTime;
      bankProgress.value = const BankSyncProgress('Revisando lo aprendido…');
      final learned = watch.elapsedMilliseconds;
      await applyLearnedCorrections();
      // An unequivocal repeat is joined on its own; then the categories the person's own evidence gives.
      await autoJoinRepeats({for (final r in result.imports) ...r.reportedKeys});
      await applyAutoCategories();
      result.timings['Correcciones aprendidas'] = watch.elapsedMilliseconds - learned;
      result.timings['Total'] = watch.elapsedMilliseconds;
      debugPrint('Doblón · tiempos de la actualización bancaria (ms): ${result.timings}');
      bankResult = result;
      notifyListeners();
      return result;
    } catch (error) {
      if (!current()) return null;
      final result = BankSyncResult()..errors['Conexión'] = error is BankingError ? error.message : 'No se ha podido consultar la conexión bancaria.';
      bankResult = result;
      notifyListeners();
      return result;
    } finally {
      _synchronizingBanks = false;
      if (client == null) api.close();
    }
  }

  /// Assigns the categories the person's own evidence gives (`lib/auto_category.dart`: their rules, then their own
  /// history), remembering where each one came from so it can be explained and taken back.
  Future<int> applyAutoCategories() async {
    final data = finances;
    if (data == null || _user == null || pending.isNotEmpty) return 0;
    final store = AutoCategoryStore.instance;
    if (!store.loaded) return 0;
    final found = autoCategories(data, automatic: store.entries.keys.toSet(), rejected: store.rejected);
    if (found.isEmpty) return 0;
    final now = DateTime.now();
    try {
      await apply(batchOperation([
        for (final a in found)
          Operation('patch', {
            'id': a.transactionId,
            'fields': {'categoryID': a.categoryId, 'updatedAt': referenceSeconds(now)}
          }),
      ]));
      await store.remember(found, now);
      return found.length;
    } catch (_) {
      return 0;
    }
  }

  /// Takes back an automatic category: the movement is left without one and it is not assigned again.
  Future<void> rejectAutoCategory(Transaction t) async {
    await apply(Operation('patch', {
      'id': t.id,
      'fields': {'categoryID': null, 'updatedAt': referenceSeconds(DateTime.now())}
    }));
    await AutoCategoryStore.instance.reject(t.id);
  }

  /// Joins on its own only an unequivocal repeat: the same bank entry stored twice with two references
  /// (`rereported`) when the latest download still reports one and no longer the other. Pairs the person kept
  /// apart are respected; each join is remembered and can be undone in «Revisar y unir». Ambiguous pairs (both or
  /// neither still reported) stay as a proposal.
  Future<int> autoJoinRepeats(Set<String> reported) async {
    if (reported.isEmpty || pending.isNotEmpty) return 0;
    final store = ReconcileStore.instance;
    try {
      await store.load();
    } catch (_) {
      return 0; // without the pairs kept apart, nothing is joined on its own
    }
    var joined = 0;
    for (var round = 0; round < 20; round++) {
      final data = finances, doc = document;
      if (data == null || doc == null) break;
      final match = unequivocalRepeat(data, reported, keptApart: store.keptApart);
      if (match == null) break;
      final planned = joinOperation(match, data, doc, DateTime.now());
      if (planned == null) break;
      await store.remember(planned.trace);
      await apply(planned.op);
      joined++;
    }
    return joined;
  }

  /// Repeats the corrections the person taught on new bank movements, when the model has proved itself.
  Future<int> applyLearnedCorrections({Set<String>? only}) async {
    final data = finances;
    if (_correcting || data == null || learning == null || pending.isNotEmpty) return 0;
    _correcting = true;
    try {
      final protected = contributions.expand((p) => p.candidates).map((t) => t.id).toSet();
      final eligible = data.transactions.where((t) => !protected.contains(t.id) && (only == null || only.contains(t.id))).map((t) => t.id).toSet();
      final op = await learning!.learnedCorrections(data, DateTime.now(), only: eligible);
      if (op == null) return 0;
      await apply(op);
      return (op.data['ops'] as List).length;
    } catch (_) {
      return 0;
    } finally {
      _correcting = false;
    }
  }

  /// Deletes the account and all its data (`finance_delete_account`). The bank permissions are revoked first:
  /// if that fails nothing is deleted, so no bank connection is left behind without its owner.
  Future<void> deleteAccount() async {
    final token = _client.auth.currentSession?.accessToken;
    if (token == null) throw BankingError('unauthorized');
    // The cloud must be able to delete before anything is revoked: without the word it only answers that it exists.
    try {
      await _client.rpc('finance_delete_account', params: {'confirmation': ''});
    } on PostgrestException catch (error) {
      if (error.code != '22023') rethrow;
    }
    final api = BankingClient(token);
    try {
      for (final connection in await api.connections()) {
        await api.disconnect(connection.id);
      }
    } finally {
      api.close();
    }
    await _client.rpc('finance_delete_account', params: {'confirmation': 'ELIMINAR'});
    await signOut();
    await _client.auth.signOut();
  }

  Future<void> signOut() async {
    _generation++;
    CloudPrivacy.forgetAll();
    _privacySession = null;
    isAdministrator = false;
    final user = _user;
    if (user != null) {
      final store = await _local();
      await store.clear(user);
      // Bank reports are not kept after signing out; what was taught to the models stays for this profile.
      await BankActivityStore(store.directory).clear(user);
    }
    bankActivity = {};
    bankConnections = [];
    _connectionsReadAt = null;
    bankResult = null;
    _bankReviews.clear();
    _reviewsVersion++;
    bankSchedule.load({});
    _learningTimer?.cancel();
    learning = null;
    forecast = null;
    _hiddenOnDevice = {};
    finances = null;
    copy = null;
    document = null;
    pending = [];
    error = null;
    loadedAt = null;
    _opened = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _learningTimer?.cancel();
    _momentTimer?.cancel();
    bankProgress.removeListener(_updateMood);
    super.dispose();
  }
}
