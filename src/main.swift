import Carbon
import Cocoa
import Foundation

// UserDefaults for Dock preferences
let dockUserDefaults = UserDefaults(suiteName: "com.apple.dock")!
let dockPrefKey = "persistent-apps"

// Default hotkey mappings
let hotkeyMappings: [Hotkey: Int] = [
  // Option+E (key code 14) for position 0 (always Finder).
  Hotkey(keyCode: 14, modifiers: .maskAlternate): 0,

  // Option+1 through Option+0 for the rest.
  Hotkey(keyCode: 18, modifiers: .maskAlternate): 1,  // Option+1 -> position 1
  Hotkey(keyCode: 19, modifiers: .maskAlternate): 2,  // Option+2 -> position 2
  Hotkey(keyCode: 20, modifiers: .maskAlternate): 3,  // Option+3 -> position 3
  Hotkey(keyCode: 21, modifiers: .maskAlternate): 4,  // Option+4 -> position 4
  Hotkey(keyCode: 23, modifiers: .maskAlternate): 5,  // Option+5 -> position 5
  Hotkey(keyCode: 22, modifiers: .maskAlternate): 6,  // Option+6 -> position 6
  Hotkey(keyCode: 26, modifiers: .maskAlternate): 7,  // Option+7 -> position 7
  Hotkey(keyCode: 28, modifiers: .maskAlternate): 8,  // Option+8 -> position 8
  Hotkey(keyCode: 25, modifiers: .maskAlternate): 9,  // Option+9 -> position 9
  Hotkey(keyCode: 29, modifiers: .maskAlternate): 10,  // Option+0 -> position 10
]

// Observer class for UserDefaults changes
class PrefObs: NSObject {
  weak var manager: HotKeyManager?

  init(manager: HotKeyManager) {
    self.manager = manager
    super.init()
    dockUserDefaults.addObserver(self, forKeyPath: dockPrefKey, options: .new, context: nil)
  }

  deinit {
    dockUserDefaults.removeObserver(self, forKeyPath: dockPrefKey)
  }

  override func observeValue(
    forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    guard keyPath == dockPrefKey else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }

    manager?.refreshDockAppURLs()
  }
}

struct Hotkey: Hashable {
  let keyCode: Int
  let modifiers: CGEventFlags

  func hash(into hasher: inout Hasher) {
    hasher.combine(keyCode)
    hasher.combine(modifiers.rawValue)
  }
}

class HotKeyManager {
  private let verbose: Bool
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  // Track permission status to avoid unnecessary re-registration
  private var permissionsGranted = false
  private var hotkeysRegistered = false

  // Observers for app activation
  private var workspaceObserver: NSObjectProtocol?
  private var distributedObserver: NSObjectProtocol?

  // Observer for UserDefaults changes
  private var prefObserver: PrefObs?

  // Mapping of Dock positions to app URLs
  private var dockAppURLs: [Int: URL] = [:]

  init(verbose: Bool = false) {
    self.verbose = verbose
    self.dockAppURLs = loadDockAppURLs()
  }

  deinit {
    unregisterHotkeys()
    if let observer = workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    if let observer = distributedObserver {
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    stopWatchingDockPlist()
  }

  // Method to refresh dock app URLs when preferences change
  func refreshDockAppURLs() {
    log("Dock preferences changed, updating app URLs")
    dockAppURLs = loadDockAppURLs()
  }

  // Logging method that respects verbose setting
  private func log(_ message: String) {
    if verbose {
      print(message)
    }
  }

  func requestAccessibilityPermissions() -> Bool {
    let options =
      [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true] as CFDictionary
    permissionsGranted = AXIsProcessTrustedWithOptions(options)
    return permissionsGranted
  }

  func setupPermissionMonitoring() {
    // Only set up if permissions aren't granted yet.
    if !permissionsGranted {
      log("Setting up permission change monitoring")

      // Set up distributed notification for TCC database changes.
      let distributedCenter = DistributedNotificationCenter.default()

      // Add multiple observers to catch different possible notifications.
      distributedObserver = distributedCenter.addObserver(
        forName: NSNotification.Name("com.apple.accessibility.api"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.checkAndUpdatePermissions()
      }

      // Also monitor app activation as backup.
      workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.checkAndUpdatePermissions()
      }
    }
  }

  func checkAndUpdatePermissions() {
    if !permissionsGranted && AXIsProcessTrusted() {
      log("Detected accessibility permission change!")

      // First, completely unregister existing hotkeys and clean up resources
      unregisterHotkeys()

      // Mark as granted but reset registration flag to force recreation
      permissionsGranted = true
      hotkeysRegistered = false

      // Register hotkeys from scratch to create new resources
      registerHotkeys()

      log("Successfully initialized hotkeys after permission change")
    }
  }

  func registerHotkeys() {
    // Avoid re-registering if already done
    if hotkeysRegistered {
      return
    }

    // Ensure we're starting clean
    unregisterHotkeys()

    // Check accessibility permissions first.
    let currentPermissions = AXIsProcessTrusted()
    permissionsGranted = currentPermissions

    if !currentPermissions {
      print("Warning: Accessibility permissions not granted. Hotkeys may not work.")
      print("Please enable in System Settings → Privacy & Security → Accessibility.")
      // Continue registration attempt, but it likely won't work without permissions
    }

    if registerWithEventTap() {
      log("Successfully registered hotkeys using CGEventTap")
      hotkeysRegistered = true
    }
  }

  private func loadDockAppURLs() -> [Int: URL] {
    guard
      let persistentApps = dockUserDefaults.array(forKey: dockPrefKey) as? [[String: Any]]
    else {
      print("Error loading Dock preferences")
      return [:]
    }

    var appURLs: [Int: URL] = [:]

    // Add Finder at position 0 (it's always the first item in the Dock)
    if let finderURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.Finder")
    {
      appURLs[0] = finderURL
    }

    // Map persistent apps, adding 1 to index to account for Finder being at position 0
    for (ind, app) in persistentApps.enumerated() {
      if let val = app["tile-data"] as? [String: Any],
        let val = val["bundle-identifier"] as? String,
        let val = NSWorkspace.shared.urlForApplication(withBundleIdentifier: val)
      {
        // Add 1 to index: position 0 is Finder, persistent apps start at position 1
        appURLs[ind + 1] = val
      }
    }

    return appURLs
  }

  private func registerWithEventTap() -> Bool {
    // Create an event tap to monitor key combinations.
    let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
          if type == .keyDown {
            let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            let modifiers = event.flags.intersection([
              .maskControl, .maskCommand, .maskAlternate, .maskShift,
            ])
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let hotkey = Hotkey(keyCode: Int(keyCode), modifiers: modifiers)

            if let val = hotkeyMappings[hotkey],
              let val = manager.dockAppURLs[val]
            {
              // Dispatch to main thread to avoid blocking event tap
              DispatchQueue.main.async {
                manager.activateDockApp(appURL: val)
              }

              // Consume the event
              return nil
            }
          }

          // Pass through all other events.
          return Unmanaged.passUnretained(event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      print("Failed to create event tap")
      return false
    }

    // Create a run loop source and add it to the current run loop.
    self.eventTap = tap
    self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    startWatchingDockPlist()
    return true
  }

  func unregisterHotkeys() {
    if hotkeysRegistered {
      log("Unregistering previous hotkeys...")
    }

    // Clean up event tap
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
      eventTap = nil
    }

    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
      runLoopSource = nil
    }

    // Clean up observers
    if let observer = distributedObserver {
      DistributedNotificationCenter.default().removeObserver(observer)
      distributedObserver = nil
    }

    // Stop file watching if active
    stopWatchingDockPlist()

    // Reset registered flag to allow re-registration
    hotkeysRegistered = false
  }

  private func activateDockApp(appURL: URL) {
    log("Activating app at \(appURL.path)")

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
      if let error = error {
        print("Error opening application: \(error)")
      }
    }
  }

  private func startWatchingDockPlist() {
    stopWatchingDockPlist()
    log("Setting up UserDefaults observation for com.apple.dock")
    // Start the observer which notifies us about changes in Dock preferences.
    prefObserver = PrefObs(manager: self)
  }

  private func stopWatchingDockPlist() {
    // Stop the preference observer.
    prefObserver = nil
  }

  func stop() {
    unregisterHotkeys()
    CFRunLoopStop(CFRunLoopGetCurrent())
  }
}

// Convert key code to human-readable string
func keyCodeToString(keyCode: Int) -> String {
  // Create a CGEvent to simulate a key press
  if let val = CGEventSource(stateID: .hidSystemState),
    let val = CGEvent(keyboardEventSource: val, virtualKey: CGKeyCode(keyCode), keyDown: true),
    let val = NSEvent(cgEvent: val),
    let val = val.charactersIgnoringModifiers,
    !val.isEmpty
  {
    return val
  }
  // Fallback if event creation fails
  return "[\(keyCode)]"
}

@main
struct DockHotkeysApp {
  static func main() {
    // Parse command line arguments
    let arguments = CommandLine.arguments
    let verbose = arguments.contains("-v")

    // Create manager instance
    let hotKeyManager = HotKeyManager(verbose: verbose)

    if verbose {
      print("dock_hotkeys CLI")
      print("Available hotkeys:")

      // Dynamically generate hotkey list from global mappings, sorted by Dock position
      let sortedHotkeys = hotkeyMappings.sorted { $0.value < $1.value }
      for (hotkey, position) in sortedHotkeys {
        let keyName = keyCodeToString(keyCode: hotkey.keyCode)

        // Build modifier string in standard order: Alt, Cmd, Ctrl, Shift
        var modifiers = ""
        if hotkey.modifiers.contains(.maskAlternate) { modifiers += "Alt+" }
        if hotkey.modifiers.contains(.maskCommand) { modifiers += "Cmd+" }
        if hotkey.modifiers.contains(.maskControl) { modifiers += "Ctrl+" }
        if hotkey.modifiers.contains(.maskShift) { modifiers += "Shift+" }
        print("  \(modifiers)\(keyName) -> Dock position \(position)")
      }

      print("Press Ctrl+C to quit")
    } else {
      print("dock_hotkeys running. Use -v for verbose output. Press Ctrl+C to quit.")
    }

    // Request accessibility permissions if needed.
    let trusted = hotKeyManager.requestAccessibilityPermissions()

    if trusted {
      if verbose {
        print("Accessibility permissions granted")
      }
    } else {
      print("Please grant accessibility permissions when prompted")
      print(
        "(You may need to manually enable in System Settings → Privacy & Security → Accessibility)")
      if verbose {
        print("You can continue granting permissions while the app is running")
      }

      // Set up comprehensive permission monitoring
      hotKeyManager.setupPermissionMonitoring()
    }

    // Register hotkeys - will be recreated when permissions change
    hotKeyManager.registerHotkeys()

    if verbose {
      print("dock_hotkeys is running. Hotkeys will activate the configured Dock positions.")
      print("If hotkeys don't work yet, grant permissions and they'll activate automatically.")
    }

    // Keep the program running.
    RunLoop.current.run()
  }
}
