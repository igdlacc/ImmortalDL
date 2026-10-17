import SwiftUI
import WebKit
import AVFoundation
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
                }
        }
    }
}

// MARK: - 1. ÖLÜMSÜZ ARKAPLAN MOTORU (SESSİZ SES HİLESİ)
final class KeepAliveEngine {
    static let shared = KeepAliveEngine()
    private var audioPlayer: AVAudioPlayer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var isRunning = false
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            let wavData = generateSilentWav()
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.numberOfLoops = -1 // Sonsuz döngü
            audioPlayer?.volume = 1.0 // Veri zaten 0 (dijital sessizlik) olduğu için ses çıkmaz ama iOS uyutmaz
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("KeepAlive Audio Hatası: \(error)")
        }
        
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "ImmortalDLTask") { [weak self] in
                self?.endBgTask()
            }
        }
    }
    
    func stop() {
        guard isRunning else { return }
        isRunning = false
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBgTask()
    }
    
    private func endBgTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer?.play()
    }
    
    // Harici dosyaya ihtiyaç duymadan bellekte 1 saniyelik 0 dB WAV üretir
    private func generateSilentWav() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        let fileSize: UInt32 = 36 + dataSize
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        var fs = fileSize.littleEndian; data.append(Data(bytes: &fs, count: 4))
        data.append("WAVEfmt ".data(using: .ascii)!)
        var fmtSize: UInt32 = 16; data.append(Data(bytes: &fmtSize, count: 4))
        var audioFmt: UInt16 = 1; data.append(Data(bytes: &audioFmt, count: 2))
        var channels: UInt16 = 1; data.append(Data(bytes: &channels, count: 2))
        var sr = sampleRate.littleEndian; data.append(Data(bytes: &sr, count: 4))
        var byteRate = (sampleRate * 2).littleEndian; data.append(Data(bytes: &byteRate, count: 4))
        var align: UInt16 = 2; data.append(Data(bytes: &align, count: 2))
        var bits: UInt16 = 16; data.append(Data(bytes: &bits, count: 2))
        data.append("data".data(using: .ascii)!)
        var ds = dataSize.littleEndian; data.append(Data(bytes: &ds, count: 4))
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

// MARK: - 2. İNDİRME MODELİ VE MOTORU (RANGE DESTEKLİ & OTO-DEVAM)
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
        
        // Sunucu Range desteklemiyorsa (200 döndüyse) dosyayı sıfırdan yaz
        if statusCode == 200 && transfer.downloadedBytes > 0 {
            transfer.downloadedBytes = 0
            try? transfer.fileHandle?.truncate(atOffset: 0)
        }
        
        // Sunucudan gelen gerçek dosya adını yakala
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
        if elapsed >= 0.3 {
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
            
            // Otomatik Yeniden Bağlanma (3 saniye sonra kaldığı byte'tan devam eder)
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                if self.items[idx].status == .paused { return }
                self.items[idx].status = .retrying
                self.items[idx].speedBytesPerSec = 0
                self.items[idx].errorMessage = "Bağlantı koptu, 3 sn içinde devam edecek..."
                
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
        content.title = "İndirme Tamamlandı"
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
    
    // Pop-up / Yeni Sekme (_blank) Koruması
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
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
            VStack(spacing: 12) {
                // Arkaplan Durum Göstergesi
                HStack {
                    Circle()
                        .fill(manager.isKeepAliveActive ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(manager.isKeepAliveActive ? "Ölümsüz Arkaplan Aktif (Uygulama Kapanmaz)" : "Arkaplan Motoru Beklemede")
                        .font(.caption.bold())
                        .foregroundColor(manager.isKeepAliveActive ? .green : .secondary)
                    Spacer()
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
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Henüz indirme yok")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("İndirilen her şey iPhone'un 'Dosyalar -> ImmortalDL' klasörüne kaydedilir.")
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
            .navigationTitle("ImmortalDL")
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
