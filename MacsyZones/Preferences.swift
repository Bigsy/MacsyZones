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
    let screen: UInt32
    let space: Int
}

class SpaceLayoutPreferences: UserData {
    var spaces: [ScreenSpacePair: String] = [:]
    static let defaultConfigFileName = "SpaceLayoutPreferences.json"

    override init(name: String = "SpaceLayoutPreferences", data: String = "{}", fileName: String = SpaceLayoutPreferences.defaultConfigFileName) {
        super.init(name: name, data: data, fileName: fileName)
    }

    func set(screenID: UInt32, spaceNumber: Int, layoutName: String) {
        spaces[ScreenSpacePair(screen: screenID, space: spaceNumber)] = layoutName
        save()
    }

    func get(screenID: UInt32, spaceNumber: Int) -> String? {
        let name = spaces[ScreenSpacePair(screen: screenID, space: spaceNumber)]
        
        if name == nil {
            return nil
        }
        
        if !userLayouts.layouts.keys.contains(name!) {
            return userLayouts.layouts.values.first?.name
        }
        
        return name
    }

    func setCurrent(layoutName: String) {
        guard let (screenID, spaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() else {
            debugLog("Unable to get the current screen and space")
            return
        }

        set(screenID: screenID, spaceNumber: spaceNumber, layoutName: layoutName)
    }

    func getCurrent() -> String? {
        guard let (screenID, spaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() else {
            debugLog("Unable to get the current screen and space")
            return nil
        }

        return get(screenID: screenID, spaceNumber: spaceNumber)
    }

    static func getCurrentScreenAndSpace() -> (UInt32, Int)? {
        guard let focusedScreen = getFocusedScreen(),
              let screenID = focusedScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            return nil
        }

        guard let spaceNumber = getCurrentSpaceNumber(for: focusedScreen) else {
            return nil
        }

        return (screenID, spaceNumber)
    }

    static func getCurrentSpaceNumber(for screen: NSScreen) -> Int? {
        let connection = CGSMainConnectionID()

        guard let unmanagedDisplaySpaces = CGSCopyManagedDisplaySpaces(connection),
              let displaySpaces = unmanagedDisplaySpaces.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        // Get the display UUID for the target screen
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).takeRetainedValue()
        let uuidString = CFUUIDCreateString(nil, uuid) as String

        // Find the matching display entry
        for displaySpace in displaySpaces {
            guard let displayIdentifier = displaySpace["Display Identifier"] as? String else { continue }
            if displayIdentifier == uuidString,
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
        var version: Int = 1
        var spaces: [ScreenSpacePair: String]
    }

    override func save() {
        do {
            let versioned = VersionedPreferences(version: 1, spaces: spaces)
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

        // Try new versioned format first
        if let versioned = try? JSONDecoder().decode(VersionedPreferences.self, from: jsonData),
           versioned.version >= 1 {
            spaces = versioned.spaces
            debugLog("Preferences loaded successfully (v\(versioned.version)).")
            return
        }

        // Old format (no version field, screen was an array index) — clear and re-save as v1
        debugLog("Legacy SpaceLayoutPreferences detected (index-based screens). Clearing and migrating to v1 with display IDs.")
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
