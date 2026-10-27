import Cocoa
import OptiStatsCore

// Suporte da aba Debloat: carga do catálogo (embutido ou atualizado), detecção do que existe neste Mac e
// download manual do catálogo do autor. Catálogo: mac-os-debloat, https://github.com/OleksandrKrupko/mac-os-debloat (MIT).

/// Um item do catálogo + o que foi detectado neste Mac.
struct DebloatEntry {
    let item: UpstreamItem
    /// nil = o plist não existe neste Mac ("não presente").
    let domain: ServiceDomain?
    /// .enabled = ativo, .disabled = desativado, .unknown = não presente ou tabela ilegível.
    let state: ServiceState
}

enum DebloatCatalogSource: Equatable {
    case embedded
    case updated(Date)
}

enum DebloatCatalogStore {
    static var userURL: URL { MaintenancePaths.supportDir.appendingPathComponent("debloat-catalog.txt") }

    static func embeddedText() -> String? {
        guard let url = Bundle.main.url(forResource: "debloat-catalog", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func embedded() -> UpstreamCatalog? {
        guard let t = embeddedText() else { return nil }
        let c = UpstreamCatalog.parse(t)
        return c.items.isEmpty ? nil : c
    }

    /// O arquivo atualizado (se válido) tem prioridade sobre o embutido.
    static func load() -> (catalog: UpstreamCatalog, source: DebloatCatalogSource)? {
        let fm = FileManager.default
        if let text = try? String(contentsOf: userURL, encoding: .utf8) {
            let c = UpstreamCatalog.parse(text)
            if !c.items.isEmpty {
                let date = (try? fm.attributesOfItem(atPath: userURL.path)[.modificationDate] as? Date) ?? Date()
                return (c, .updated(date))
            }
        }
        guard let e = embedded() else { return nil }
        return (e, .embedded)
    }

    static func save(block: String) throws {
        let header = "# Catálogo atualizado manualmente de https://github.com/OleksandrKrupko/mac-os-debloat (MIT, (c) 2026 Oleksandr Krupko).\n\n"
        try FileManager.default.createDirectory(at: MaintenancePaths.supportDir, withIntermediateDirectories: true)
        try (header + block).write(to: userURL, atomically: true, encoding: .utf8)
    }

    static func reset() { try? FileManager.default.removeItem(at: userURL) }
}

enum DebloatScanner {
    private static var agentDirs: [String] {
        ["/System/Library/LaunchAgents", "/System/Cryptexes/App/System/Library/LaunchAgents", "/Library/LaunchAgents",
         "/Library/Apple/System/Library/LaunchAgents", NSHomeDirectory() + "/Library/LaunchAgents"]
    }
    private static var daemonDirs: [String] {
        ["/System/Library/LaunchDaemons", "/System/Cryptexes/App/System/Library/LaunchDaemons", "/Library/LaunchDaemons",
         "/Library/Apple/System/Library/LaunchDaemons"]
    }

    /// label → domínio, decidido pela pasta onde o plist está (agentes antes de daemons). Lê só os nomes das pastas.
    static func presence() -> [String: ServiceDomain] {
        var out: [String: ServiceDomain] = [:]
        let fm = FileManager.default
        for dir in agentDirs + daemonDirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".plist") {
                let label = String(n.dropLast(6))
                guard out[label] == nil, let d = ServiceDomain.forPlist(atPath: dir + "/" + n) else { continue }
                out[label] = d
            }
        }
        return out
    }

    /// Estado por item. Ausente da tabela do launchctl = ativo.
    static func entries(catalog: UpstreamCatalog, presence: [String: ServiceDomain],
                        user: [String: Bool]?, system: [String: Bool]?) -> [String: DebloatEntry] {
        var out: [String: DebloatEntry] = [:]
        for item in catalog.items {
            guard let d = presence[item.label] else {
                out[item.label] = DebloatEntry(item: item, domain: nil, state: .unknown)
                continue
            }
            guard let table = (d == .user ? user : system) else {
                out[item.label] = DebloatEntry(item: item, domain: d, state: .unknown)
                continue
            }
            out[item.label] = DebloatEntry(item: item, domain: d, state: table[item.label] == true ? .disabled : .enabled)
        }
        return out
    }
}

enum DebloatSections {
    /// Título de seção do catálogo upstream (sem tags) → id da chave `debloat.sec.<id>`.
    static let sectionIDs: [String: String] = [
        "Spotlight / app launcher": "spotlightLauncher",
        "Siri / voice assistant": "siri",
        "Apple Intelligence (Tahoe)": "appleIntelligence",
        "Telemetry / analytics": "telemetry",
        "AirDrop / Continuity (no iPhone)": "continuity",
        "Diagnostics / crash reports": "crashReports",
        "Apple ads": "ads",
        "Proactive / predictive": "proactive",
        "Game Center / AirPlay receiver": "gameCenter",
        "Photos analysis": "photosAnalysis",
        "News / Stocks / Weather": "newsWeather",
        "Apple ID nags / Family": "appleIdNags",
        "Misc": "misc",
        "iMessage / FaceTime / phone relay (no iPhone)": "imessage",
        "HomeKit": "homekit",
        "Apple Mail/Calendar/Contacts/Reminders (use Gmail/web instead)": "mailCalendar",
        "Speech / dictation": "speech",
        "Wallpaper / thumbnails": "thumbnails",
        "App Store + update nags (keeps softwareupdated for security)": "updateNags",
        "Misc dead weight": "deadWeight",
        "iCloud (no iCloud use)": "icloud",
        "Location/prediction extras (Find My still intact)": "locationExtras",
        "Time Machine": "timeMachine",
        "Focus / DND / Screen Time": "focus",
        "Apple Media Services / iPhone telephony / contacts": "mediaTelephony",
        "More AI/ML stragglers": "aiStragglers",
        "Cosmetic / app daemons": "cosmetic",
        "Safari (no Safari use)": "safari",
        "More AI / Apple Intelligence": "moreAi",
        "Spotlight KeepAlive daemons (mdutil -d leaves these resident)": "spotlightIndexer",
        "Apple Music / iTunes / Media streaming": "music",
        "Apple ID / Apple Pay / SSO": "appleIdPay",
        "App Store full kill (re-enable when needed)": "appStore",
        "iCloud user-facing notifications": "icloudNotifications",
        "Apple Books (no Books use)": "books",
        "Telemetry extras": "telemetryExtras",
        "Contacts/Photos extras": "contactsPhotosExtras",
        "Filesystem / cosmetic": "filesystemCosmetic",
        "Contacts / AddressBook (no Mac Contacts use)": "addressBook",
        "Audio route suggestions": "audioRoutes",
        "Maps (Google Maps user)": "maps",
        "Beta program enrollment (not on macOS beta)": "betaEnrollment",
        "Game controllers (no gamepad attached)": "gameControllers",
        "Sidecar / iPad second display (no iPad)": "sidecar",
        "Continuity Capture (no iPhone webcam)": "continuityCapture",
        "Avatar / Memoji / Stickers (no iMessage)": "memoji",
        "Safari extras (no Safari + no iCloud Keychain)": "safariExtras",
        "Family / Parental controls (no family setup)": "parental",
        "Proactive / Siri-adjacent (no Siri)": "siriAdjacent",
        "AirPlay sender UI": "airplaySender",
        "Sports / News extras": "sportsNews",
        "Apple FairPlay DRM (no DRM-protected Apple content)": "fairplay",
        "Diagnostics extras (all telemetry to Apple)": "diagnosticsExtras",
        "Software update extras (keep softwareupdated + swcd)": "updateExtras",
        "Misc Apple legacy / unused": "legacy",
        "Apple ID auth (kill — re-enable when needed for App Store)": "appleIdAuth",
        "Apple Translate / Notes / VoiceOver / accessibility extras": "translateNotes",
        "iCloud settings / language assets": "icloudSettings",
        "Apple TV watchlist / social / WiFi telemetry": "tvWifi",
        "T2 / bridgeOS": "t2",
        "Battery / power logging (charge limiting needs these)": "batteryLogging",
        "Print (no printer)": "print",
        "Xcode / iOS dev stack (FE/BE dev, no mobile)": "devStack",
        "Apple Music Player (AMP) suite — no Apple Music": "amp",
        "Apple TV+ / video subscriptions": "tvPlus",
        "Touch Bar (M4 has none)": "touchBar",
        "Safari Web Inspector / WebKit push (no Safari)": "webInspector",
        "iCloud Drive / Keychain Circle / SyncedDefaults / CloudDocs": "icloudDrive",
        "MDM / Managed apps (no MDM enrollment)": "mdm",
        "Paired-device sync (Replicator)": "replicator"
    ]

    static func hint(for title: String) -> String? {
        sectionIDs[title].map { L("debloat.sec.\($0)") }
    }
}

/// Download manual (nunca automático) do script do autor. Só https, só raw.githubusercontent.com, 15 s, máx. 2 MB.
final class DebloatDownload: NSObject, URLSessionDataDelegate {
    static let url = URL(string: "https://raw.githubusercontent.com/OleksandrKrupko/mac-os-debloat/main/debloat")!
    static let host = "raw.githubusercontent.com"
    static let maxBytes = 2 * 1024 * 1024

    enum Failure: Error { case http, tooBig, redirect, network(String), invalid }

    private var data = Data()
    private var failure: Failure?
    private var finished = false
    private let completion: (Result<Data, Failure>) -> Void

    private init(_ completion: @escaping (Result<Data, Failure>) -> Void) { self.completion = completion }

    static func start(_ completion: @escaping (Result<Data, Failure>) -> Void) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 15
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: cfg, delegate: DebloatDownload(completion), delegateQueue: queue)
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        session.dataTask(with: req).resume()
        session.finishTasksAndInvalidate()
    }

    private static func allowed(_ u: URL?) -> Bool { u?.scheme == "https" && u?.host == host }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if Self.allowed(request.url) { completionHandler(request) } else { failure = .redirect; completionHandler(nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, Self.allowed(http.url) else {
            failure = .http; completionHandler(.cancel); return
        }
        if response.expectedContentLength > Int64(Self.maxBytes) { failure = .tooBig; completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        if data.count > Self.maxBytes { failure = .tooBig; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        if let f = failure { completion(.failure(f)) }
        else if let e = error { completion(.failure(.network(e.localizedDescription))) }
        else { completion(.success(data)) }
    }
}

enum DebloatReport {
    /// Alerta com resumo e lista rolável (item a item).
    static func show(window: NSWindow?, title: String, summary: String, details: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = summary
        let frame = NSRect(x: 0, y: 0, width: 460, height: 220)
        let tv = NSTextView(frame: frame)
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = details
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let sv = NSScrollView(frame: frame)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        a.accessoryView = sv
        a.addButton(withTitle: L("prefs.ok"))
        if let w = window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
    }
}
