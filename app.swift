import SwiftUI
import WebKit
import AVFoundation
import MediaPlayer
import CoreLocation
import UserNotifications

@main
struct ImmortalDLApp: App {
    @StateObject private var manager = DownloadManager.shared
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
                .onAppear {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                    KeepAliveEngine.shared.requestPermissions()
                }
        }
    }
}

// MARK: - 1. NÜKLEER ARKAPLAN MOTORU (SES + DYNAMIC ISLAND MEDYA + GPS KONUM + BG TASK)
final class KeepAliveEngine: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAliveEngine()
    
    private var audioPlayer: AVAudioPlayer?
    private let locationManager = CLLocationManager()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var bgTimer: Timer?
    private(set) var isRunning = false
    
    var playAudibleTick: Bool = false {
        didSet {
            if isRunning {
                restartAudioPlayer()
            }
        }
    }
    
    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        
        setupRemoteTransportControls()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    func requestPermissions() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestAlwaysAuthorization()
    }
    
    private func setupRemoteTransportControls() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            return .success
        }
    }
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        // 1. Ses + Dynamic Island Medya Oturumu
        restartAudioPlayer()
        
        // 2. GPS / Navigasyon Arkaplan Kilidi
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        
        // 3. Background Task Sayacı Yenileyici
        renewBackgroundTask()
        bgTimer?.invalidate()
        bgTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.renewBackgroundTask()
            if let player = self?.audioPlayer, !player.isPlaying {
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
            }
        }
        
        updateNowPlaying(fileName: "İndirme Hazırlanıyor...", percent: 0, speedText: "0 KB/sn", sizeText: "Başlatılıyor")
    }
    
    func restartAudioPlayer() {
        do {
            let session = AVAudioSession.sharedInstance()
            // mixWithOthers KAPALI -> Uygulama doğrudan Dynamic Island ve Kilit Ekranına yerleşir!
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            
            audioPlayer?.stop()
            let wavData = generateKeepAliveWav(audible: playAudibleTick)
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 1.0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("KeepAlive Audio Hatası: \(error)")
        }
    }
    
    func stop() {
        guard isRunning else { return }
        isRunning = false
        
        bgTimer?.invalidate()
        bgTimer = nil
        
        audioPlayer?.stop()
        audioPlayer = nil
        
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBgTask()
    }
    
    func updateNowPlaying(fileName: String, percent: Int, speedText: String, sizeText: String) {
        guard isRunning else { return }
        DispatchQueue.main.async {
            let badgeImage = Self.renderArtwork(percent: percent, speed: speedText)
            let artwork = MPMediaItemArtwork(boundsSize: badgeImage.size) { _ in badgeImage }
            
            var info = [String: Any]()
            info[MPMediaItemPropertyTitle] = "⏬ %\(percent) • \(fileName)"
            info[MPMediaItemPropertyArtist] = "\(speedText) • \(sizeText)"
            info[MPMediaItemPropertyAlbumTitle] = "ImmortalDL Arkaplan Motoru"
            info[MPMediaItemPropertyPlaybackDuration] = 100.0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(percent)
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            info[MPMediaItemPropertyArtwork] = artwork
            
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
    
    // Dynamic Island ve Kilit Ekranı için canlı yüzde (%) kapağı çizer
    private static func renderArtwork(percent: Int, speed: String) -> UIImage {
        let size = CGSize(width: 240, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.06, green: 0.10, blue: 0.20, alpha: 1.0).setFill()
            ctx.fill(rect)
            
            // İlerleme Çemberi
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius: CGFloat = 95
            let bgPath = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            bgPath.lineWidth = 16
            UIColor.darkGray.setStroke()
            bgPath.stroke()
            
            let endAngle = (-CGFloat.pi / 2) + (CGFloat(percent) / 100.0) * (.pi * 2)
            let fgPath = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: endAngle, clockwise: true)
            fgPath.lineWidth = 16
            fgPath.lineCapStyle = .round
            UIColor.systemGreen.setStroke()
            fgPath.stroke()
            
            // Yüzde Yazısı
            let pText = "%\(percent)" as NSString
            let pAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
            let pSize = pText.size(withAttributes: pAttrs)
            pText.draw(at: CGPoint(x: (size.width - pSize.width) / 2, y: (size.height - pSize.height) / 2 - 12), withAttributes: pAttrs)
            
            // Hız Yazısı
            let sText = speed as NSString
            let sAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.systemCyan
            ]
            let sSize = sText.size(withAttributes: sAttrs)
            sText.draw(at: CGPoint(x: (size.width - sSize.width) / 2, y: (size.height / 2) + 28), withAttributes: sAttrs)
        }
    }
    
    private func renewBackgroundTask() {
        let oldTask = bgTask
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ImmortalLoop") { [weak self] in
            self?.endBgTask()
        }
        if oldTask != .invalid {
            UIApplication.shared.endBackgroundTask(oldTask)
        }
    }
    
    private func endBgTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isRunning else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.audioPlayer?.play()
        }
    }
    
    // CoreAudio'nun "sessizlik" filtresini aşan gerçek 20Hz alt-frekans dalgası (veya duyulur tik-tak sesi)
    private func generateKeepAliveWav(audible: Bool) -> Data {
        let sampleRate: Int = 8000
        let durationSeconds: Int = 4
        let totalSamples = sampleRate * durationSeconds
        let dataSize = UInt32(totalSamples * 2)
        let fileSize = UInt32(36 + dataSize)
        
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        var fs = fileSize.littleEndian; data.append(Data(bytes: &fs, count: 4))
        data.append("WAVEfmt ".data(using: .ascii)!)
        var fmtSize: UInt32 = 16; data.append(Data(bytes: &fmtSize, count: 4))
        var audioFmt: UInt16 = 1; data.append(Data(bytes: &audioFmt, count: 2))
        var channels: UInt16 = 1; data.append(Data(bytes: &channels, count: 2))
        var sr = UInt32(sampleRate).littleEndian; data.append(Data(bytes: &sr, count: 4))
        var byteRate = UInt32(sampleRate * 2).littleEndian; data.append(Data(bytes: &byteRate, count: 4))
        var align: UInt16 = 2; data.append(Data(bytes: &align, count: 2))
        var bits: UInt16 = 16; data.append(Data(bytes: &bits, count: 2))
        data.append("data".data(using: .ascii)!)
        var ds = dataSize.littleEndian; data.append(Data(bytes: &ds, count: 4))
        
        var samples = [Int16](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            if audible {
                // Her saniye başında 40ms boyunca yumuşak bir "tik" sesi verir
                if i % sampleRate < 320 {
                    samples[i] = Int16(sin(2.0 * .pi * 600.0 * t) * 3500.0)
                } else {
                    samples[i] = Int16(sin(2.0 * .pi * 20.0 * t) * 80.0)
                }
            } else {
                // İnsan kulağının duyamayacağı ama iOS'un aktif ses gördüğü 18 Hz sinüs dalgası
                samples[i] = Int16(sin(2.0 * .pi * 18.0 * t) * 90.0)
            }
        }
        
        samples.withUnsafeBufferPointer { buffer in
            data.append(buffer)
        }
        return data
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // GPS akışı uygulamayı uyanık tutar
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - 2. İNDİRME MODELİ VE MOTORU
enum DLStatus: String {
    case downloading = "İndiriliyor"
    case paused = "Duraklatıldı"
    case retrying = "Bağlantı Bekleniyor..."
    case completed = "Tamamlandı"
    case failed = "Hata"
}

struct DownloadItem: Identifiable {
    let id: UUID
    let url: URL
    var fileName: String
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSec: Double = 0
    var status: DLStatus = .downloading
    var cookies: String?
    var userAgent: String?
    var referer: String?
    var errorMessage: String?
    
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }
}

final class ActiveTransfer {
    var task: URLSessionDataTask?
    var fileHandle: FileHandle?
    var filePath: URL
    var downloadedBytes: Int64
    var totalBytes: Int64 = 0
    var lastSpeedTime: Date = Date()
    var bytesSinceLastSpeed: Int64 = 0
    var currentSpeed: Double = 0
    
    init(filePath: URL, existingBytes: Int64) {
        self.filePath = filePath
        self.downloadedBytes = existingBytes
    }
}

final class DownloadManager: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = DownloadManager()
    
    @Published var items: [DownloadItem] = []
    @Published var isKeepAliveActive: Bool = false
    @Published var audibleTickEnabled: Bool = false {
        didSet {
            KeepAliveEngine.shared.playAudibleTick = audibleTickEnabled
        }
    }
    @Published var toastMessage: String? = nil
    
    private var session: URLSession!
    private var transfers: [UUID: ActiveTransfer] = [:]
    private var taskToItemID: [Int: UUID] = [:]
    private let queue = DispatchQueue(label: "com.sait.immortaldl.queue")
    
    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400 * 7
        config.waitsForConnectivity = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.networkServiceType = .avStreaming // İndirmeyi medya akışı önceliğinde tutar!
        
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 4
        opQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
    }
    
    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func addDownload(url: URL, cookies: String? = nil, userAgent: String? = nil, referer: String? = nil, suggestedName: String? = nil) {
        let rawName = suggestedName ?? (url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "indirilen_\(Int(Date().timeIntervalSince1970)).bin" : url.lastPathComponent)
        let cleanName = rawName.removingPercentEncoding ?? rawName
        
        let item = DownloadItem(
            id: UUID(),
            url: url,
            fileName: cleanName,
            cookies: cookies,
            userAgent: userAgent,
            referer: referer
        )
        
        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.showToast("İndirme Başlatıldı: \(cleanName)")
            self.startOrResume(id: item.id)
        }
    }
    
    func startOrResume(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]
        items[idx].status = .downloading
        items[idx].errorMessage = nil
        updateKeepAliveState()
        
        queue.async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.documentsDirectory.appendingPathComponent(item.fileName)
            var existingBytes: Int64 = 0
            
            if FileManager.default.fileExists(atPath: fileURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                existingBytes = size
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            
            var request = URLRequest(url: item.url)
            request.httpMethod = "GET"
            request.networkServiceType = .avStreaming
            if existingBytes > 0 {
                request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            }
            if let ua = item.userAgent {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            if let cookies = item.cookies, !cookies.isEmpty {
                request.setValue(cookies, forHTTPHeaderField: "Cookie")
            }
            if let referer = item.referer, !referer.isEmpty {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            
            let transfer = ActiveTransfer(filePath: fileURL, existingBytes: existingBytes)
            transfer.fileHandle = try? FileHandle(forWritingTo: fileURL)
            if existingBytes > 0 {
                try? transfer.fileHandle?.seekToEnd()
            }
            
            let task = self.session.dataTask(with: request)
            transfer.task = task
            self.transfers[id] = transfer
            self.taskToItemID[task.taskIdentifier] = id
            
            DispatchQueue.main.async {
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[i].downloadedBytes = existingBytes
                }
            }
            task.resume()
        }
    }
    
    func pause(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .paused
            items[idx].speedBytesPerSec = 0
        }
        queue.async { [weak self] in
            guard let self = self, let transfer = self.transfers[id] else { return }
            if let tID = transfer.task?.taskIdentifier {
                self.taskToItemID.removeValue(forKey: tID)
            }
            transfer.task?.cancel()
            try? transfer.fileHandle?.close()
            self.transfers.removeValue(forKey: id)
            DispatchQueue.main.async {
                self.updateKeepAliveState()
            }
        }
    }
    
    func delete(id: UUID, deleteFile: Bool) {
        pause(id: id)
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let fileURL = documentsDirectory.appendingPathComponent(items[idx].fileName)
            if deleteFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
            items.remove(at: idx)
        }
        updateKeepAliveState()
    }
    
    private func updateKeepAliveState() {
        let hasActive = items.contains { $0.status == .downloading || $0.status == .retrying }
        if hasActive {
            KeepAliveEngine.shared.start()
            isKeepAliveActive = true
        } else {
            KeepAliveEngine.shared.stop()
            isKeepAliveActive = false
        }
    }
    
    private func refreshLockScreenWidget() {
        let activeItems = items.filter { $0.status == .downloading || $0.status == .retrying }
        guard let first = activeItems.first else { return }
        
        let percent = Int(first.progress * 100)
        let spd = "\(formatByteCount(Int64(first.speedBytesPerSec)))/sn"
        let sz = "\(formatByteCount(first.downloadedBytes)) / \(first.totalBytes > 0 ? formatByteCount(first.totalBytes) : "?")"
        
        KeepAliveEngine.shared.updateNowPlaying(
            fileName: first.fileName,
            percent: percent,
            speedText: spd,
            sizeText: sz
        )
    }
    
    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toastMessage = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.toastMessage == text {
                    self.toastMessage = nil
                }
            }
        }
    }
    
    // MARK: URLSession Delegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let id = taskToItemID[dataTask.taskIdentifier], let transfer = transfers[id] else {
            completionHandler(.cancel)
            return
        }
        
        let httpResp = response as? HTTPURLResponse
        let statusCode = httpResp?.statusCode ?? 200
        
        if statusCode >= 400 {
            completionHandler(.cancel)
            handleFailure(id: id, message: "Sunucu Hatası: HTTP \(statusCode)")
            return
        }
        
        if statusCode == 200 && transfer.downloadedBytes > 0 {
            transfer.downloadedBytes = 0
            try? transfer.fileHandle?.truncate(atOffset: 0)
        }
        
        if transfer.downloadedBytes == 0, let suggested = response.suggestedFilename {
            let cleanSuggested = suggested.removingPercentEncoding ?? suggested
            let newURL = documentsDirectory.appendingPathComponent(cleanSuggested)
            if newURL != transfer.filePath {
                try? transfer.fileHandle?.close()
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try? FileManager.default.removeItem(at: newURL)
                }
                try? FileManager.default.moveItem(at: transfer.filePath, to: newURL)
                transfer.filePath = newURL
                transfer.fileHandle = try? FileHandle(forWritingTo: newURL)
                DispatchQueue.main.async {
                    if let idx = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[idx].fileName = cleanSuggested
                    }
                }
            }
        }
        
        let expected = response.expectedContentLength
        if expected > 0 {
            transfer.totalBytes = transfer.downloadedBytes + expected
        }
        
        let total = transfer.totalBytes
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == id }) {
                self.items[idx].totalBytes = total
                self.refreshLockScreenWidget()
            }
        }
        
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = taskToItemID[dataTask.taskIdentifier], let transfer = transfers[id] else { return }
        
        do {
            try transfer.fileHandle?.write(contentsOf: data)
        } catch {
            transfer.fileHandle?.write(data)
        }
        
        let count = Int64(data.count)
        transfer.downloadedBytes += count
        transfer.bytesSinceLastSpeed += count
        
        let now = Date()
        let elapsed = now.timeIntervalSince(transfer.lastSpeedTime)
        if elapsed >= 0.4 {
            transfer.currentSpeed = Double(transfer.bytesSinceLastSpeed) / elapsed
            transfer.bytesSinceLastSpeed = 0
            transfer.lastSpeedTime = now
            
            let dl = transfer.downloadedBytes
            let total = transfer.totalBytes
            let spd = transfer.currentSpeed
            
            DispatchQueue.main.async {
                if let idx = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[idx].downloadedBytes = dl
                    if total > 0 { self.items[idx].totalBytes = total }
                    self.items[idx].speedBytesPerSec = spd
                    self.refreshLockScreenWidget()
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskToItemID[task.taskIdentifier], let transfer = transfers[id] else { return }
        taskToItemID.removeValue(forKey: task.taskIdentifier)
        try? transfer.fileHandle?.close()
        let finalBytes = transfer.downloadedBytes
        transfers.removeValue(forKey: id)
        
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }
            
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                if self.items[idx].status == .paused { return }
                self.items[idx].status = .retrying
                self.items[idx].speedBytesPerSec = 0
                self.items[idx].errorMessage = "Bağlantı koptu, 3 sn içinde devam edecek..."
                self.refreshLockScreenWidget()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let currentIdx = self.items.firstIndex(where: { $0.id == id }),
                       self.items[currentIdx].status == .retrying {
                        self.startOrResume(id: id)
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                if let idx = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[idx].downloadedBytes = finalBytes
                    self.items[idx].status = .completed
                    self.items[idx].speedBytesPerSec = 0
                    self.sendNotification(fileName: self.items[idx].fileName)
                }
                self.updateKeepAliveState()
            }
        }
    }
    
    private func handleFailure(id: UUID, message: String) {
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == id }) {
                self.items[idx].status = .failed
                self.items[idx].speedBytesPerSec = 0
                self.items[idx].errorMessage = message
            }
            self.updateKeepAliveState()
        }
    }
    
    private func sendNotification(fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "İndirme Tamamlandı ✅"
        content.body = "\(fileName) Dosyalar uygulamasına kaydedildi."
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - 3. MİNİ TARAYICI (WKWEBVIEW & ÇEREZ YAKALAYICI)
final class BrowserViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var urlString: String = "https://www.google.com"
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    
    let webView: WKWebView
    
    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.webView.allowsBackForwardNavigationGestures = true
        loadURL("https://www.google.com")
    }
    
    func loadURL(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var targetURL: URL?
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            targetURL = URL(string: trimmed)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            targetURL = URL(string: "https://\(trimmed)")
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            targetURL = URL(string: "https://www.google.com/search?q=\(query)")
        }
        
        if let url = targetURL {
            webView.load(URLRequest(url: url))
        }
    }
    
    func forceDownloadCurrentURL() {
        guard let url = webView.url else { return }
        interceptAndDownload(url: url, suggestedFilename: nil)
    }
    
    private func interceptAndDownload(url: URL, suggestedFilename: String?) {
        let currentReferer = webView.url?.absoluteString
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            let ua = result as? String
            self?.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var cookiePairs: [String] = []
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                    if let host = url.host, host.hasSuffix(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                        cookiePairs.append("\(cookie.name)=\(cookie.value)")
                    }
                }
                let cookieHeader = cookiePairs.joined(separator: "; ")
                DownloadManager.shared.addDownload(
                    url: url,
                    cookies: cookieHeader,
                    userAgent: ua,
                    referer: currentReferer,
                    suggestedName: suggestedFilename
                )
            }
        }
    }
    
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            let ext = url.pathExtension.lowercased()
            let directExts = ["zip", "rar", "7z", "ipa", "apk", "mkv", "mp4", "avi", "iso", "dmg", "exe", "pdf", "mp3", "flac", "tar", "gz"]
            if navigationAction.shouldPerformDownload || directExts.contains(ext) {
                decisionHandler(.cancel)
                interceptAndDownload(url: url, suggestedFilename: nil)
                return
            }
        }
        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url else {
            decisionHandler(.allow)
            return
        }
        
        var shouldIntercept = !navigationResponse.canShowMIMEType
        let mime = (navigationResponse.response.mimeType ?? "").lowercased()
        
        if let httpResp = navigationResponse.response as? HTTPURLResponse,
           let disposition = httpResp.allHeaderFields["Content-Disposition"] as? String,
           disposition.lowercased().contains("attachment") {
            shouldIntercept = true
        }
        
        if mime.contains("octet-stream") || mime.contains("application/zip") || mime.contains("application/x-rar") || mime.contains("video/") || mime.contains("audio/") {
            shouldIntercept = true
        }
        
        if shouldIntercept {
            decisionHandler(.cancel)
            interceptAndDownload(url: url, suggestedFilename: navigationResponse.response.suggestedFilename)
        } else {
            decisionHandler(.allow)
        }
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        updateState()
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateState()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        updateState()
    }
    
    private func updateState() {
        if let u = webView.url?.absoluteString {
            urlString = u
        }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 4. ARAYÜZ (SWIFTUI)
struct MainView: View {
    @EnvironmentObject var manager: DownloadManager
    @StateObject private var browserVM = BrowserViewModel()
    @State private var selectedTab = 0
    @State private var directLinkInput = ""
    
    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                DownloadsTabView(directLinkInput: $directLinkInput)
                    .tabItem {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("İndirmeler")
                    }
                    .tag(0)
                
                BrowserTabView(vm: browserVM)
                    .tabItem {
                        Image(systemName: "globe")
                        Text("Mini Tarayıcı")
                    }
                    .tag(1)
            }
            
            if let toast = manager.toastMessage {
                Text(toast)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.9))
                    .cornerRadius(20)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(99)
            }
        }
    }
}

struct DownloadsTabView: View {
    @EnvironmentObject var manager: DownloadManager
    @Binding var directLinkInput: String
    
    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                // Durum ve Test Sesi Paneli
                VStack(spacing: 6) {
                    HStack {
                        Circle()
                            .fill(manager.isKeepAliveActive ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(manager.isKeepAliveActive ? "Dynamic Island + GPS + Ses Kilidi AKTİF" : "Arkaplan Motoru Beklemede")
                            .font(.caption.bold())
                            .foregroundColor(manager.isKeepAliveActive ? .green : .secondary)
                        Spacer()
                    }
                    
                    Toggle(isOn: $manager.audibleTickEnabled) {
                        Text("Duyulur Test Sesi (Arkaplanda Tık-Tık Duy)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                
                // Direkt Link Ekleme Kutusu
                HStack {
                    TextField("Direkt indirme linkini yapıştır...", text: $directLinkInput)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    Button(action: {
                        if let clipboard = UIPasteboard.general.string {
                            directLinkInput = clipboard
                        }
                    }) {
                        Image(systemName: "doc.on.clipboard")
                            .padding(8)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(8)
                    }
                    
                    Button(action: {
                        if let url = URL(string: directLinkInput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            manager.addDownload(url: url)
                            directLinkInput = ""
                        }
                    }) {
                        Text("İndir")
                            .bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal)
                
                if manager.items.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.shield.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)
                        Text("Nükleer Arkaplan Hazır")
                            .font(.headline)
                        Text("İndirme başladığında Dynamic Island'a ve Kilit Ekranına canlı yüzde (%) ve hız göstergesi yerleşir.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRowView(item: item)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("ImmortalDL v2")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct DownloadRowView: View {
    @EnvironmentObject var manager: DownloadManager
    let item: DownloadItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.fileName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Text(item.status.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.2))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)
            }
            
            ProgressView(value: item.progress)
                .accentColor(statusColor)
            
            HStack {
                Text("\(formatBytes(item.downloadedBytes)) / \(item.totalBytes > 0 ? formatBytes(item.totalBytes) : "?")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if item.status == .downloading {
                    Text("\(formatBytes(Int64(item.speedBytesPerSec)))/sn • %\(Int(item.progress * 100))")
                        .font(.caption2.bold())
                        .foregroundColor(.blue)
                }
            }
            
            if let err = item.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            
            HStack(spacing: 16) {
                if item.status == .downloading || item.status == .retrying {
                    Button("Duraklat") { manager.pause(id: item.id) }
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                        .buttonStyle(BorderlessButtonStyle())
                } else if item.status == .paused || item.status == .failed {
                    Button("Devam Et") { manager.startOrResume(id: item.id) }
                        .font(.caption.bold())
                        .foregroundColor(.green)
                        .buttonStyle(BorderlessButtonStyle())
                }
                
                Spacer()
                
                Button("Sil") { manager.delete(id: item.id, deleteFile: true) }
                    .font(.caption.bold())
                    .foregroundColor(.red)
                    .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        switch item.status {
        case .downloading: return .blue
        case .paused: return .orange
        case .retrying: return .yellow
        case .completed: return .green
        case .failed: return .red
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct BrowserTabView: View {
    @ObservedObject var vm: BrowserViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { vm.webView.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!vm.canGoBack)
                
                Button(action: { vm.webView.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!vm.canGoForward)
                
                TextField("Site adresi veya arama...", text: $vm.urlString, onCommit: {
                    vm.loadURL(vm.urlString)
                })
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
                
                Button(action: { vm.webView.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                
                Button(action: { vm.forceDownloadCurrentURL() }) {
                    Image(systemName: "arrow.down.doc.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding(8)
            .background(Color(UIColor.secondarySystemBackground))
            
            if vm.isLoading {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle())
            }
            
            WebViewContainer(webView: vm.webView)
                .edgesIgnoringSafeArea(.bottom)
        }
    }
}
