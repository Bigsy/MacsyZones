//
// MacsyZones, macOS system utility for managing windows on your Mac.
// 
// https://macsyzones.com
// 
// Copyright © 2024, Oğuzhan Eroğlu <meowingcate@gmail.com> (https://meowingcat.io)
// 
// This file is part of MacsyZones.
// Licensed under GNU General Public License v3.0
// See LICENSE file.
//

import Foundation
import Cocoa

struct ScreenSpacePair: Hashable, Codable {
    let screen: String
    let space: Int
}

func getDisplayUUID(for screen: NSScreen) -> String? {
    guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
        return nil
    }
    return CFUUIDCreateString(nil, uuid) as String
}

class SpaceLayoutPreferences: UserData {
    var spaces: [ScreenSpacePair: String] = [:]
    static let defaultConfigFileName = "SpaceLayoutPreferences.json"

    override init(name: String = "SpaceLayoutPreferences", data: String = "{}", fileName: String = SpaceLayoutPreferences.defaultConfigFileName) {
        super.init(name: name, data: data, fileName: fileName)
    }

    func set(screenUUID: String, spaceNumber: Int, layoutName: String) {
        spaces[ScreenSpacePair(screen: screenUUID, space: spaceNumber)] = layoutName
        save()
    }

    func get(screenUUID: String, spaceNumber: Int) -> String? {
        let name = spaces[ScreenSpacePair(screen: screenUUID, space: spaceNumber)]

        if name == nil {
            return nil
        }

        if !userLayouts.layouts.keys.contains(name!) {
            return userLayouts.layouts.values.first?.name
        }

        return name
    }

    func setCurrent(layoutName: String) {
        guard let (screenUUID, spaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() else {
            debugLog("Unable to get the current screen and space")
            return
        }

        set(screenUUID: screenUUID, spaceNumber: spaceNumber, layoutName: layoutName)
    }

    func getCurrent() -> String? {
        guard let (screenUUID, spaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() else {
            debugLog("Unable to get the current screen and space")
            return nil
        }

        return get(screenUUID: screenUUID, spaceNumber: spaceNumber)
    }

    static func getCurrentScreenAndSpace() -> (String, Int)? {
        guard let focusedScreen = getFocusedScreen(),
              let screenUUID = getDisplayUUID(for: focusedScreen) else {
            return nil
        }

        guard let spaceNumber = getCurrentSpaceNumber(for: focusedScreen) else {
            return nil
        }

        return (screenUUID, spaceNumber)
    }

    static func getCurrentSpaceNumber(for screen: NSScreen) -> Int? {
        let connection = CGSMainConnectionID()

        guard let unmanagedDisplaySpaces = CGSCopyManagedDisplaySpaces(connection),
              let displaySpaces = unmanagedDisplaySpaces.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        guard let screenUUID = getDisplayUUID(for: screen) else {
            return nil
        }

        // Find the matching display entry
        for displaySpace in displaySpaces {
            guard let displayIdentifier = displaySpace["Display Identifier"] as? String else { continue }
            if displayIdentifier == screenUUID,
               let currentSpace = displaySpace["Current Space"] as? NSDictionary,
               let activeSpaceID = currentSpace["ManagedSpaceID"] as? Int {
                return activeSpaceID
            }
        }

        // Fallback: if no match found (e.g. "Displays have separate Spaces" is off),
        // try the first entry
        if let firstEntry = displaySpaces.first,
           let currentSpace = firstEntry["Current Space"] as? NSDictionary,
           let activeSpaceID = currentSpace["ManagedSpaceID"] as? Int {
            return activeSpaceID
        }

        return nil
    }

    private struct VersionedPreferences: Codable {
        var version: Int = 2
        var spaces: [ScreenSpacePair: String]
    }

    override func save() {
        do {
            let versioned = VersionedPreferences(version: 2, spaces: spaces)
            let jsonData = try JSONEncoder().encode(versioned)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            data = jsonString
            super.save()
        } catch {
            debugLog("Error saving SpaceLayoutPreferences: \(error)")
        }
    }

    override func load() {
        super.load()

        guard let jsonData = data.data(using: .utf8) else { return }

        // Try current versioned format (v2: screen is a UUID string)
        if let versioned = try? JSONDecoder().decode(VersionedPreferences.self, from: jsonData),
           versioned.version >= 2 {
            spaces = versioned.spaces
            debugLog("Preferences loaded successfully (v\(versioned.version)).")
            return
        }

        // Old format (v0: no version + index-based, or v1: UInt32 display ID) — clear and re-save
        debugLog("Legacy SpaceLayoutPreferences detected. Clearing and migrating to v2 with display UUIDs.")
        spaces = [:]
        save()
    }
    
    private var screenChangeWorkItem: DispatchWorkItem?
    private var isWakingFromSleep = false

    func switchToCurrent() {
        if let layoutName = self.getCurrent() {
            userLayouts.currentLayoutName = layoutName

            for (_, layout) in userLayouts.layouts {
                layout.hideAllWindows()
            }
        }
    }

    private func scheduleScreenRefresh() {
        screenChangeWorkItem?.cancel()

        let delay: Double = isWakingFromSleep ? 3.0 : 0.5
        screenChangeWorkItem = DispatchWorkItem { [weak self] in
            self?.isWakingFromSleep = false

            if #available(macOS 12.0, *) { quickSnapper.close() }
            guard appSettings.selectPerDesktopLayout else { return }
            self?.switchToCurrent()
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: screenChangeWorkItem!
        )
    }

    func startObserving() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil,
            using: { _ in
                stopEditing()
                isFitting = false
                userLayouts.hideAllSectionWindows()
                if #available(macOS 12.0, *) { quickSnapper.close() }

                if !appSettings.selectPerDesktopLayout { return }

                self.switchToCurrent()
            }
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil,
            using: { _ in
                self.isWakingFromSleep = true
                self.scheduleScreenRefresh()
            }
        )

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil,
            using: { _ in
                self.scheduleScreenRefresh()
            }
        )
    }
}
