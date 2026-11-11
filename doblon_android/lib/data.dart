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
import 'edits.dart';
import 'contributions.dart';
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

  Future<void> clear(String user) async {
    for (final name in ['cloud', 'pending', 'bank-sync']) {
      final file = _file(user, name);
      await _diskWrites[file.path];
      if (await file.exists()) await file.delete();
    }
  }
}

/// Downloads and saves the person's finances with the same functions the iPhone uses to sync.
class FinanceRepository extends ChangeNotifier {
  FinanceRepository({LocalStore? store, SupabaseClient? cloudClient})
      : _store = store,
        _cloud = cloudClient;

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

  Future<LocalStore> _local() async => _store ??= LocalStore(await getApplicationSupportDirectory());

  CloudPrivacy? _privacySession;
  Future<CloudPrivacy> _privacy() async {
    final active = CloudPrivacy.sessions[_user];
    if (active != null) return active;
    final value = _privacySession ??= CloudPrivacy(_client);
    if (!await value.prepare()) throw StateError('Desbloquea tus datos con el código de recuperación.');
    return value;
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
        final bankState = await store.loadBankState(user);
        if (_disposed || generation != _generation || user != _user) return;
        bankSchedule.load(bankState);
        if (bankState['reviews'] is Map) {
          for (final entry in (bankState['reviews'] as Map).entries) {
            _bankReviews['${entry.key}'] = Map<String, dynamic>.from(entry.value as Map);
          }
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
    } on AuthException {
      error = 'Tu sesión ha caducado. Vuelve a entrar.';
    } catch (_) {
      error = copy == null
          ? 'No se han podido cargar tus finanzas. Comprueba la conexión y vuelve a intentarlo.'
          : 'Sin conexión: ves la última copia de este dispositivo.';
    } finally {
      loading = false;
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
    final task = _writes.then((_) => _update(change, user, generation));
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
        pending = pending.sublist(sending.length);
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

  /// Saved previews remain reviewable after reopening, without another request to the bank.
  List<BankProposal> get bankProposals {
    final doc = document;
    if (doc == null) return [];
    final proposals = <BankProposal>[];
    for (final entry in _bankReviews.values) {
      final feed = AccountFeed.fromJson(entry['feed'] as Map<String, dynamic>);
      if (linked(feed.account)) proposals.addAll(importFeeds(doc, [feed], DateTime.fromMillisecondsSinceEpoch(entry['at'] as int)).$2.proposals);
    }
    return proposals;
  }

  Future<ImportResult> _incorporateFeed(AccountFeed feed, DateTime date, String user, {Map<String, String> decisions = const {}}) async {
    final generation = _generation;
    void checkProfile() {
      if (_disposed || generation != _generation || _user != user) throw BankingError('unauthorized');
    }

    checkProfile();
    final key = accountIdentity(feed.account.id);
    _bankReviews[key] = {'feed': feed.toJson(), 'at': date.millisecondsSinceEpoch, 'committed': false};
    await _saveBankState(user);
    checkProfile();
    final result = await update((doc) => importFeeds(withPending(doc, pending), [feed], date, decisions: decisions));
    checkProfile();
    await recordBankActivity([feed], date);
    checkProfile();
    if (result.proposals.isEmpty) {
      _bankReviews.remove(key);
    } else {
      _bankReviews[key]!['committed'] = true;
    }
    bankSchedule.failures.remove(key);
    await _saveBankState(user);
    return result;
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
      await learning?.rememberEdit(before[row.id], row, updated, explicitlyReviewed: true);
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

  Future<BankSyncResult?> synchronizeBanks({bool manual = false, String? bank, BankingClient? client}) async {
    final user = _user, generation = _generation;
    if (user == null || finances == null || _synchronizingBanks) return bankResult;
    _synchronizingBanks = true;
    bool current() => !_disposed && generation == _generation && user == _user;
    final api = client ?? BankingClient(_client.auth.currentSession!.accessToken);
    try {
      if (manual || _connectionsReadAt == null || DateTime.now().difference(_connectionsReadAt!) >= const Duration(minutes: 1)) {
        bankConnections = await api.connections();
        _connectionsReadAt = DateTime.now();
      }
      if (!current()) return null;
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
      final result = await _bankSync.run(
          client: api,
          connections: bankConnections,
          isLinked: linked,
          incorporate: (feed, date) => _incorporateFeed(feed, date, user),
          persist: () => _saveBankState(user),
          isCurrent: current,
          manual: manual,
          onlyBank: bank);
      if (!current()) return null;
      bankResult = result;
      await applyLearnedCorrections();
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

  /// Repeats the corrections the person taught on new bank movements, when the model has proved itself.
  Future<int> applyLearnedCorrections({Set<String>? only}) async {
    final data = finances;
    if (_correcting || data == null || learning == null || pending.isNotEmpty) return 0;
    _correcting = true;
    try {
      final protected = contributionProposals(data, DateTime.now()).expand((p) => p.candidates).map((t) => t.id).toSet();
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

  Future<void> signOut() async {
    _generation++;
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
    bankSchedule.load({});
    _learningTimer?.cancel();
    learning = null;
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
    super.dispose();
  }
}
