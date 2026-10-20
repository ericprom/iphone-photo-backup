#!/bin/bash
# Builds the "iPhone Photo Backup" Mac app and puts it in your Applications folder.
#
# Run it once in Terminal:
#     bash ~/Downloads/build_iphone_backup_app.sh
#
# After that, open "iPhone Photo Backup" from Applications or Launchpad like any app.
set -euo pipefail

APP_NAME="iPhone Photo Backup"
EXEC_NAME="iPhonePhotoBackup"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Building $APP_NAME… (this takes about a minute)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's free developer tools are needed. A window will open to install them."
  xcode-select --install 2>/dev/null || true
  echo "When that install finishes, run this script again."
  exit 1
fi

cat > "$WORK/App.swift" << 'SWIFT_SOURCE_END'
import SwiftUI
import ImageCaptureCore
import AppKit

// MARK: - App

@main
struct BackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup("iPhone Photo Backup") {
            ContentView().frame(minWidth: 560, minHeight: 540)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Backup engine

struct Job {
    let file: ICCameraFile
    let folder: URL
    let name: String
}

enum Step { case idle, waitPhone, opening, listing, copying, waitUnplug }

final class Backup: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    // Settings (remembered between launches)
    @Published var destination: URL? {
        didSet { UserDefaults.standard.set(destination?.path, forKey: "destination") }
    }
    @Published var sortByDate: Bool {
        didSet { UserDefaults.standard.set(sortByDate, forKey: "sortByDate") }
    }
    @Published var includeVideos: Bool {
        didSet { UserDefaults.standard.set(includeVideos, forKey: "includeVideos") }
    }
    @Published var includeLive: Bool {
        didSet { UserDefaults.standard.set(includeLive, forKey: "includeLive") }
    }

    // Display state
    @Published var phoneName: String?
    @Published var running = false
    @Published var finished = false
    @Published var status = "Plug in your iPhone, choose a folder, and click Start Backup."
    @Published var total = 0
    @Published var position = 0
    @Published var copied = 0
    @Published var skipped = 0
    @Published var failures: [String] = []

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var step: Step = .idle
    private var stepStarted = Date()
    private var timer: Timer?
    private var generation = 0
    private var activity: NSObjectProtocol?

    private var openTries = 0
    private var sessionError: String?
    private var lastCount = -1
    private var countChangedAt = Date()
    private var interrupted = false

    private var jobs: [Job] = []
    private var index = 0
    private var attempts = 0
    private var currentTarget: URL?

    private var imageCapture: NSRunningApplication?
    private var triedImageCapture = false

    private let reserve: Int64 = 2 * 1024 * 1024 * 1024  // always leave 2 GB free
    private static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "3gp"]
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)  // Gregorian years even on Thai-calendar Macs
        c.timeZone = .current
        return c
    }()
    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    override init() {
        let d = UserDefaults.standard
        destination = d.string(forKey: "destination").map { URL(fileURLWithPath: $0) }
        sortByDate = d.bool(forKey: "sortByDate")
        includeVideos = d.object(forKey: "includeVideos") as? Bool ?? true
        includeLive = d.object(forKey: "includeLive") as? Bool ?? true
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.quitImageCapture() }
    }

    // MARK: Helpers

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func ext(_ name: String?) -> String {
        ((name ?? "") as NSString).pathExtension.lowercased()
    }

    private func clean(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }

    private var name: String { camera?.name ?? phoneName ?? "your iPhone" }

    var summary: String {
        "\(copied) copied, \(skipped) already backed up, \(failures.count) failed."
    }

    private func go(_ s: Step) {
        step = s
        stepStarted = Date()
    }

    private func freeSpace() -> Int64 {
        guard let dest = destination else { return 0 }
        let important = (try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64((try? dest.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity ?? 0)
        let best = max(important, plain)
        return best > 0 ? best : Int64.max
    }

    // MARK: Controls

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where to save your iPhone photos. An external drive is best for large libraries."
        if panel.runModal() == .OK { destination = panel.url }
    }

    func start() {
        guard let dest = destination, !running else { return }
        guard FileManager.default.fileExists(atPath: dest.path) else {
            status = "The folder isn't available. If it's on an external drive, connect it, or choose another folder."
            return
        }
        running = true
        finished = false
        copied = 0; skipped = 0; failures = []; position = 0; total = 0
        interrupted = false
        triedImageCapture = false
        generation += 1
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Backing up iPhone photos")
        go(.waitPhone)
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func cancel() {
        finish("Stopped. \(summary) Click Start Backup to continue later.")
    }

    private func finish(_ message: String) {
        running = false
        generation += 1
        timer?.invalidate(); timer = nil
        go(.idle)
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if camera?.hasOpenSession == true { camera?.requestCloseSession() }
        quitImageCapture()
        status = message
        finished = true
        NSSound(named: "Glass")?.play()
        _ = NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: Image Capture wake-up

    // The iPhone often only shares its photo list after Apple's Image Capture asks for it.
    private func wakeImageCapture() {
        guard !triedImageCapture else { return }
        triedImageCapture = true
        let id = "com.apple.Image_Capture"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            DispatchQueue.main.async { self.imageCapture = app }
        }
    }

    private func quitImageCapture() {
        imageCapture?.terminate()
        imageCapture = nil
    }

    // MARK: State machine (runs every half second while backing up)

    private func tick() {
        guard running else { return }
        switch step {
        case .idle, .copying:
            break

        case .waitPhone:
            if camera == nil {
                camera = (browser.devices ?? []).compactMap { $0 as? ICCameraDevice }.first
                camera?.delegate = self
            }
            guard let cam = camera else {
                status = interrupted
                    ? "iPhone disconnected. Plug it back in and the backup will continue where it left off."
                    : "Plug in your iPhone with a cable and unlock it."
                return
            }
            phoneName = cam.name ?? "iPhone"
            status = "Connecting to \(name)…"
            openTries = 0
            openSession(cam)

        case .opening:
            guard let cam = camera else { go(.waitPhone); return }
            if cam.hasOpenSession {
                lastCount = -1
                countChangedAt = Date()
                go(.listing)
                status = "Reading the photo list from \(name)…"
                return
            }
            if cam.isAccessRestrictedAppleDevice {
                status = "Unlock \(name) to continue. Tap Trust if it asks."
                return
            }
            if sessionError != nil || Date().timeIntervalSince(stepStarted) > 30 {
                openTries += 1
                if openTries >= 5 {
                    status = "Couldn't connect. Unplug \(name) and plug it back in. The backup continues automatically."
                    go(.waitUnplug)
                } else {
                    openSession(cam)
                }
            }

        case .listing:
            guard let cam = camera else { go(.waitPhone); return }
            if cam.isAccessRestrictedAppleDevice {
                // A locked phone pauses the listing, so don't count this time.
                status = "Unlock \(name) to continue."
                countChangedAt = Date()
                stepStarted = Date()
                return
            }
            let n = (cam.mediaFiles ?? []).count
            if n != lastCount {
                lastCount = n
                countChangedAt = Date()
            }
            status = n > 0 ? "Reading the photo list… \(n) found so far" : "Reading the photo list from \(name)…"
            let stable = Date().timeIntervalSince(countChangedAt)
            let elapsed = Date().timeIntervalSince(stepStarted)
            let complete = cam.contentCatalogPercentCompleted >= 100
            if n > 0 && ((complete && stable > 10) || stable > 45) {
                beginCopying(cam)
            } else if n == 0 && elapsed > 200 {
                status = "\(name) isn't sharing any photos. Unplug it, unlock it, and plug it back in to try again."
                go(.waitUnplug)
            } else if n == 0 && elapsed > 15 {
                wakeImageCapture()
            }

        case .waitUnplug:
            if camera == nil { go(.waitPhone) }
        }
    }

    private func openSession(_ cam: ICCameraDevice) {
        sessionError = nil
        go(.opening)
        if !cam.hasOpenSession { cam.requestOpenSession() }
    }

    // MARK: Copying

    private func beginCopying(_ cam: ICCameraDevice) {
        guard let dest = destination else { return }
        var files = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter { ext($0.name) != "aae" }
        if !includeVideos { files = files.filter { !Self.videoExts.contains(ext($0.name)) } }

        jobs = []
        for file in files {
            let date = file.creationDate ?? Date(timeIntervalSince1970: 0)
            let prefix = stamp.string(from: date)
            var folder = dest
            if sortByDate {
                let parts = calendar.dateComponents([.year, .month], from: date)
                folder = dest
                    .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
                    .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
            }
            jobs.append(Job(file: file, folder: folder, name: "\(prefix) \(clean(file.name ?? "Untitled"))"))
            if includeLive {
                // Live Photo video clips; edit files (.AAE) are never copied.
                for item in file.sidecarFiles ?? [] {
                    guard let sidecar = item as? ICCameraFile else { continue }
                    let n = sidecar.name ?? ""
                    if n.isEmpty || ext(n) == "aae" { continue }
                    jobs.append(Job(file: sidecar, folder: folder, name: "\(prefix) \(clean(n))"))
                }
            }
        }
        total = jobs.count
        index = 0
        position = 0
        skipped = 0
        attempts = 0
        go(.copying)
        status = "Copying… keep \(name) unlocked."
        next()
    }

    private func scheduleNext(after seconds: Double = 0) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, g == self.generation else { return }
            self.next()
        }
    }

    private func next() {
        guard running, step == .copying, let cam = camera else { return }
        if index >= jobs.count {
            finish("Backup finished. \(summary)")
            return
        }
        let job = jobs[index]
        position = index + 1
        let fm = FileManager.default
        let target = job.folder.appendingPathComponent(job.name)
        let expected = Int64(job.file.fileSize)

        // Skip complete copies; remove partial ones from an interrupted backup.
        if let size = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber {
            if expected <= 0 || size.int64Value == expected {
                skipped += 1
                index += 1
                scheduleNext()
                return
            }
            try? fm.removeItem(at: target)
        }

        let free = freeSpace()
        if free != Int64.max && free - expected < reserve {
            let gb = String(format: "%.1f", Double(free) / 1_073_741_824)
            finish("Stopped: only \(gb) GB free on this drive. \(summary) Free up space or choose a folder on another drive, then click Start Backup to continue.")
            return
        }

        if cam.isAccessRestrictedAppleDevice {
            status = "Unlock \(name) to continue."
            scheduleNext(after: 1)
            return
        }
        status = "Copying… keep \(name) unlocked."

        try? fm.createDirectory(at: job.folder, withIntermediateDirectories: true)
        currentTarget = target
        let g = generation
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: job.folder,
            .saveAsFilename: job.name,
            .overwrite: false,
            .downloadSidecarFiles: false,
        ]
        _ = job.file.requestDownload(options: options) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                self.currentTarget = nil
                if let error {
                    try? FileManager.default.removeItem(at: target)
                    if self.camera?.isAccessRestrictedAppleDevice == true && self.attempts < 3 {
                        self.attempts += 1  // phone locked mid-copy: retry this file after unlock
                    } else {
                        self.failures.append("\(job.name): \(error.localizedDescription)")
                        self.index += 1
                        self.attempts = 0
                    }
                } else {
                    self.copied += 1
                    self.index += 1
                    self.attempts = 0
                }
                self.next()
            }
        }
    }

    // MARK: Device events

    private func handleRemoval(_ device: ICDevice) {
        onMain {
            guard device is ICCameraDevice else { return }
            self.phoneName = nil
            guard let current = self.camera, current === device else { return }
            self.camera = nil
            if self.running {
                self.generation += 1  // ignore callbacks from the interrupted copy
                if let partial = self.currentTarget { try? FileManager.default.removeItem(at: partial) }
                self.currentTarget = nil
                self.interrupted = true
                self.go(.waitPhone)
                self.tick()
            }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        onMain {
            guard let cam = device as? ICCameraDevice else { return }
            self.phoneName = cam.name ?? "iPhone"
            if self.running, self.camera == nil {
                self.camera = cam
                cam.delegate = self
            }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        handleRemoval(device)
    }

    func didRemove(_ device: ICDevice) {
        handleRemoval(device)
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        onMain { if let error { self.sessionError = error.localizedDescription } }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - Window

struct ContentView: View {
    @StateObject private var b = Backup()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Back up your iPhone photos").font(.title2.weight(.semibold))
                Text("Copies every photo and video stored on your iPhone to a folder on this Mac, over the cable. Each backup only copies what's new.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("iPhone") {
                HStack(spacing: 10) {
                    Image(systemName: b.phoneName == nil ? "iphone.slash" : "iphone")
                        .font(.title2)
                        .foregroundStyle(b.phoneName == nil ? .secondary : .primary)
                    Text(b.phoneName.map { "\($0) is connected." } ?? "No iPhone connected. Plug one in with a cable.")
                    Spacer(minLength: 0)
                }
                .padding(4)
            }

            GroupBox("Save to") {
                HStack {
                    Text(b.destination?.path ?? "No folder chosen")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(b.destination == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose Folder…") { b.chooseFolder() }
                }
                .padding(4)
            }
            .disabled(b.running)

            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Sort into Year / Month folders", isOn: $b.sortByDate)
                    Toggle("Include videos", isOn: $b.includeVideos)
                    Toggle("Include the video part of Live Photos", isOn: $b.includeLive)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .disabled(b.running)

            VStack(alignment: .leading, spacing: 6) {
                if b.total > 0 {
                    ProgressView(value: Double(b.position), total: Double(b.total))
                } else if b.running {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(b.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                if b.total > 0 {
                    Text("\(b.position) of \(b.total) files: \(b.copied) copied, \(b.skipped) already backed up, \(b.failures.count) failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !b.failures.isEmpty {
                ScrollView {
                    Text(b.failures.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }

            Spacer(minLength: 0)

            HStack {
                Text("Keep your iPhone unlocked while backing up. Setting Auto-Lock to Never helps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if b.finished, let dest = b.destination {
                    Button("Show in Finder") { NSWorkspace.shared.open(dest) }
                }
                if b.running {
                    Button("Stop") { b.cancel() }
                } else {
                    Button("Start Backup") { b.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(b.destination == nil)
                }
            }
        }
        .padding(20)
    }
}
SWIFT_SOURCE_END

cat > "$WORK/Icon.swift" << 'ICON_SOURCE_END'
import AppKit
// Draws the app icon: a rounded tile with a camera symbol.
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.75, alpha: 1))?.draw(in: path, angle: -90)
if let symbol = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 420, weight: .medium)) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()
    let s = tinted.size
    tinted.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
ICON_SOURCE_END

APP="$WORK/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" << 'PLIST_END'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>iPhonePhotoBackup</string>
    <key>CFBundleIdentifier</key><string>local.surasak.iphonephotobackup</string>
    <key>CFBundleName</key><string>iPhone Photo Backup</string>
    <key>CFBundleDisplayName</key><string>iPhone Photo Backup</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key>
    <string>iPhone Photo Backup reads photos from your connected iPhone so it can copy them to the folder you choose.</string>
</dict>
</plist>
PLIST_END

echo "Compiling…"
swiftc -O -parse-as-library "$WORK/App.swift" -o "$APP/Contents/MacOS/$EXEC_NAME"

make_icon() {
  swiftc "$WORK/Icon.swift" -o "$WORK/icon" 2>/dev/null
  "$WORK/icon" "$WORK/icon.png"
  local set="$WORK/AppIcon.iconset"
  mkdir -p "$set"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$WORK/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$APP/Contents/Resources/AppIcon.icns"
}
echo "Making the icon…"
make_icon || echo "(Icon skipped; the app still works.)"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Install into Applications (falls back to ~/Applications if needed)
DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
rm -rf "$DEST_DIR/$APP_NAME.app"
cp -R "$APP" "$DEST_DIR/"

echo
echo "Done! Installed: $DEST_DIR/$APP_NAME.app"
echo "Opening it now. Next time, open it from Applications or Launchpad."
open "$DEST_DIR/$APP_NAME.app"
