import AppIntents
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // With the lock on, a native cover hides the app as soon as it stops being active, before iOS takes the picture
    // for the app switcher; Flutter's own cover may not be painted in time. lib/main.dart keeps the content hidden
    // until it is unlocked.
    NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      PrivacyCover.show()
    }
    NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      PrivacyCover.hide()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The card payments recorded by the Shortcuts action, read and cleared by lib/card_payments.dart.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DoblonCardPayments") {
      let channel = FlutterMethodChannel(name: "doblon/card_payments", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "pending": result(CardPaymentInbox.pending())
        case "remove":
          CardPaymentInbox.remove(call.arguments as? [String] ?? [])
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}

/// Payments recorded outside the app, one file per payment, so two automations finishing at the same moment
/// cannot overwrite each other (the same as the Swift app's `CardPaymentInbox`).
enum CardPaymentInbox {
  private static var inbox: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("CardPayments/inbox", isDirectory: true)
  }

  static func add(amountMinor: Int64, merchant: String, card: String) throws {
    guard let inbox else { throw CocoaError(.fileNoSuchFile) }
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    let payment: [String: Any] = [
      "id": id, "date": ISO8601DateFormatter().string(from: Date()), "amountMinor": amountMinor,
      "merchant": merchant, "card": card,
    ]
    try JSONSerialization.data(withJSONObject: payment)
      .write(to: inbox.appendingPathComponent(id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  static func pending() -> [String] {
    guard let inbox, let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return [] }
    return files.filter { $0.pathExtension == "json" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
  }

  static func remove(_ ids: [String]) {
    guard let inbox else { return }
    for id in ids where UUID(uuidString: id) != nil {
      try? FileManager.default.removeItem(at: inbox.appendingPathComponent(id.lowercased() + ".json"))
    }
  }

  /// Reads what Shortcuts passes as the amount ("4,50 €", "€4.50", "1.234,56"). Only positive amounts.
  static func amount(from raw: String) -> Int64? {
    var text = raw.filter { ("0"..."9").contains($0) || $0 == "," || $0 == "." }
    guard text.contains(where: { ("0"..."9").contains($0) }) else { return nil }
    let comma = text.lastIndex(of: ","), dot = text.lastIndex(of: ".")
    if let comma, let dot {
      // Both separators: the later one marks the decimals, the other groups thousands.
      let decimal: Character = comma > dot ? "," : "."
      text = String(text.compactMap { character -> Character? in
        character == decimal ? "." : (character == "," || character == "." ? nil : character)
      })
    } else if let separator = comma ?? dot {
      // One kind of separator: decimal when at most two digits follow its last use, grouping otherwise.
      let symbol = text[separator]
      let isDecimal = text.distance(from: separator, to: text.endIndex) - 1 <= 2 && text.filter({ $0 == symbol }).count == 1
      text = String(text.compactMap { character -> Character? in
        guard character == symbol else { return character }
        return isDecimal ? "." : nil
      })
    }
    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
    var cents = value * 100, rounded = Decimal()
    NSDecimalRound(&rounded, &cents, 0, .plain)
    let minor = NSDecimalNumber(decimal: rounded).int64Value
    return minor > 0 ? minor : nil
  }
}

/// Shortcuts and Siri action. In the «Transacción» automation of Shortcuts (it runs after each Apple Pay payment)
/// it receives the amount, merchant and card. It only writes to this device's inbox; the app files the payment as
/// an expense waiting for the bank the next time it opens.
@available(iOS 16.0, *)
struct RecordCardPaymentIntent: AppIntent {
  static let title: LocalizedStringResource = "Apuntar pago con tarjeta"
  static let description = IntentDescription(
    "Apunta en Doblón un pago con tarjeta, pendiente del banco hasta que el banco lo envíe. En la automatización «Transacción» de Atajos, apunta cada pago con Apple Pay al momento.")
  static let openAppWhenRun = false

  @Parameter(title: "Importe", description: "El importe pagado, por ejemplo 4,50 €.")
  var amount: String

  @Parameter(title: "Comercio")
  var merchant: String?

  @Parameter(title: "Tarjeta", description: "El nombre de la tarjeta en Wallet. Sirve para elegir la cuenta.")
  var card: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Apuntar \(\.$amount) en \(\.$merchant)") {
      \.$card
    }
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let minor = CardPaymentInbox.amount(from: amount) else {
      throw $amount.needsValueError("¿Cuánto has pagado?")
    }
    try CardPaymentInbox.add(
      amountMinor: minor,
      merchant: (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
      card: (card ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    let formatted = (Decimal(minor) / 100).formatted(.currency(code: "EUR"))
    return .result(dialog: "Apuntado en Doblón: \(formatted). Queda pendiente del banco.")
  }
}

@available(iOS 16.0, *)
struct DoblonShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RecordCardPaymentIntent(),
      phrases: [
        "Apuntar un pago en \(.applicationName)",
        "Apunta un pago con tarjeta en \(.applicationName)",
      ],
      shortTitle: "Apuntar pago",
      systemImageName: "creditcard"
    )
  }
}

/// An opaque cover in the app's page colour with a lock, over every window. Only with the lock on (the
/// preference that shared_preferences keeps as `flutter.lockEnabled`).
enum PrivacyCover {
  private static let tag = 0xD0B10

  static func show() {
    guard UserDefaults.standard.bool(forKey: "flutter.lockEnabled") else { return }
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows where window.viewWithTag(tag) == nil {
        let cover = UIView(frame: window.bounds)
        cover.tag = tag
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = UIColor { traits in
          traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x0D / 255, green: 0x16 / 255, blue: 0x20 / 255, alpha: 1)
            : UIColor(red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xED / 255, alpha: 1)
        }
        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = UIColor(red: 0x0F / 255, green: 0x76 / 255, blue: 0x6E / 255, alpha: 1)
        lock.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(lock)
        NSLayoutConstraint.activate([
          lock.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
          lock.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
          lock.widthAnchor.constraint(equalToConstant: 44),
          lock.heightAnchor.constraint(equalToConstant: 44),
        ])
        lock.contentMode = .scaleAspectFit
        window.addSubview(cover)
      }
    }
  }

  static func hide() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows {
        window.viewWithTag(tag)?.removeFromSuperview()
      }
    }
  }
}
