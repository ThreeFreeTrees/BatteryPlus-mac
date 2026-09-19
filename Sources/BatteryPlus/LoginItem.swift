// LoginItem.swift — Login Items → "Open at Login".
//
// macOS offers two doors, and they differ in whether they are open to an app signed like this one:
//
//   * SMAppService.mainApp (macOS 13+) — the modern API Apple wants apps to use, and the one actually
//     allowed here: an ad-hoc signature is accepted for the app's OWN login item. (A *daemon*
//     registration through the same framework is refused with EPERM — measured, from /Applications
//     too — which is why the helper's row in Background App Activity keeps the generic "exec" glyph.)
//   * LSSharedFileList (deprecated since 10.11, still honoured) — the fallback: adds the app *bundle*
//     to the session login items, so the row shows the app's own name and icon.
//
// The item is ON BY DEFAULT. A fresh install — or any reinstall, which rewrites the app bundle and so
// changes its modification date — registers it. After that the app keeps its hands off: if the row is
// deleted in System Settings it stays deleted, because the system gives no way to tell a user deletion
// from an uninstall having removed the item. The bundle's modification date separates those two cases:
// unchanged since we registered ⇒ the user did it, so respect it; new ⇒ a new install, which starts
// from "on" again. There is deliberately no switch in the menu for this.

import Foundation
import ServiceManagement
import CoreServices

enum LoginItem {
    private static let routeKey = "loginItemRoute"
    private static let installStampKey = "loginItemRegisteredForInstall"

    /// True when the system currently has this app as a login item, by either door.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval { return true }
        }
        return legacyContainsSelf()
    }

    /// Last route taken — exposed for `--login-item status`.
    static var lastRoute: String? { UserDefaults.standard.string(forKey: routeKey) }

    /// Called on launch: registers the item on a fresh install, then leaves it alone.
    static func ensurePresent() {
        guard Bundle.main.bundlePath == "/Applications/BatteryPlus.app" else {
            // A build-directory run or a demo instance must not claim the login item — the row has to
            // point at the app the user actually keeps.
            setRoute("skipped:not-the-installed-copy")
            return
        }
        let defaults = UserDefaults.standard
        let stamp = installStamp()
        if defaults.string(forKey: installStampKey) == stamp {
            // The same install we already handled once: never re-add what the user may have removed.
            setRoute(isEnabled ? "already-present" : "left-removed-by-user")
            return
        }
        defaults.set(stamp, forKey: installStampKey)
        guard !isEnabled else {
            setRoute("already-present")
            return
        }
        setRoute("registered-on-install:\(setEnabled(true))")
    }

    /// Identifies this installation of the app: the bundle's modification date, which any reinstall
    /// changes and nothing else touches.
    private static func installStamp() -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)
        guard let date = attributes?[.modificationDate] as? Date else { return "unknown" }
        return String(Int(date.timeIntervalSince1970))
    }

    /// Turns the login item on or off, returning a short diagnostic string.
    @discardableResult
    static func setEnabled(_ on: Bool) -> String {
        guard on else {
            unregister()
            setRoute("disabled")
            return "disabled"
        }
        let route = register()
        setRoute(route)
        return route
    }

    private static func setRoute(_ value: String) {
        UserDefaults.standard.set(value, forKey: routeKey)
    }

    // MARK: - the two doors

    private static func register() -> String {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                return "smappservice"
            } catch {
                // Fall through rather than leaving the user without a login item at all.
            }
        }
        return legacyRegister()
    }

    private static func unregister() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        }
        legacyRemoveSelf()
    }

    // MARK: - LSSharedFileList (the fallback door)

    private static func sessionList() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?
            .takeRetainedValue()
    }

    private static func legacyItems() -> [LSSharedFileListItem] {
        guard let list = sessionList() else { return [] }
        return (LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
    }

    private static func legacyContainsSelf() -> Bool {
        legacyItems().contains { entry in
            var error: Unmanaged<CFError>?
            guard let resolved = LSSharedFileListItemCopyResolvedURL(entry, 0, &error)?.takeRetainedValue()
            else { return false }
            return (resolved as URL).standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
    }

    private static func legacyRemoveSelf() {
        guard let list = sessionList() else { return }
        for entry in legacyItems() {
            var error: Unmanaged<CFError>?
            guard let resolved = LSSharedFileListItemCopyResolvedURL(entry, 0, &error)?.takeRetainedValue()
            else { continue }
            if (resolved as URL).standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
                LSSharedFileListItemRemove(list, entry)
            }
        }
    }

    private static func legacyRegister() -> String {
        guard let list = sessionList() else { return "failed:no-session-login-item-list" }
        if legacyContainsSelf() { return "legacy:already-present" }
        let url = Bundle.main.bundleURL as CFURL
        let inserted = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast.takeUnretainedValue(),
                                                     nil, nil, url, nil, nil)
        return inserted != nil ? "legacy:inserted" : "legacy:insert-failed"
    }
}
