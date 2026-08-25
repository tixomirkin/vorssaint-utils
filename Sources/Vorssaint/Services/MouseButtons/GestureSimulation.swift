// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreGraphics
import Foundation

/// Uses IOHIDEvents embedded in CGEvents to simulate trackpad swipes for
/// Spaces and Mission Control, similarly to how Mac Mouse Fix does it.
enum GestureSimulation {

    // Reverse engineered enum from IOHIDEventTypes
    enum DockSwipeType: Int {
        case horizontal = 1 // Swipe between pages / Spaces
        case vertical = 2 // Mission Control & App Expose
        case pinch = 3 // Show Desktop & Launchpad
    }

    enum Phase: Int {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    private static var currentOriginOffset: Double = 0
    private static var isSynthesizing = false

    static func beginDockSwipe(delta: Double, type: DockSwipeType) {
        currentOriginOffset = delta
        isSynthesizing = true
        postDockSwipe(delta: delta, type: type, phase: .began, exitSpeed: 0)
    }

    static func updateDockSwipe(delta: Double, type: DockSwipeType) {
        guard isSynthesizing else { return }
        if delta == 0 { return }
        postDockSwipe(delta: delta, type: type, phase: .changed, exitSpeed: 0)
    }

    static func endDockSwipe(delta: Double, type: DockSwipeType, exitSpeed: Double = 0) {
        guard isSynthesizing else { return }
        postDockSwipe(delta: delta, type: type, phase: .ended, exitSpeed: exitSpeed)
        isSynthesizing = false
        currentOriginOffset = 0
    }

    static func cancelDockSwipe(delta: Double, type: DockSwipeType) {
        guard isSynthesizing else { return }
        postDockSwipe(delta: delta, type: type, phase: .cancelled, exitSpeed: 0)
        isSynthesizing = false
        currentOriginOffset = 0
    }

    private static func postDockSwipe(delta: Double, type: DockSwipeType, phase: Phase, exitSpeed: Double) {
        // macOS 27 and newer removed standard CGEvent field routing for this,
        // requiring true HIDEvents to be constructed. But for macOS 14+,
        // we can still synthesize NSEventTypeGesture and NSEventTypeMagnify/30

        guard let e29 = CGEvent(source: nil),
              let e30 = CGEvent(source: nil) else { return }

        // Type 29 (NSEventTypeGesture)
        e29.type = CGEventType(rawValue: 29)! // NSEventTypeGesture
        e29.setDoubleValueField(CGEventField(rawValue: 41)!, value: 33231) // Magic value

        // Type 30 (used for Dock Swipes)
        e30.type = CGEventType(rawValue: 30)! // NSEventTypeMagnify
        e30.setDoubleValueField(CGEventField(rawValue: 110)!, value: 13) // kIOHIDEventTypeDockSwipe is 13
        e30.setDoubleValueField(CGEventField(rawValue: 132)!, value: Double(phase.rawValue))
        e30.setDoubleValueField(CGEventField(rawValue: 134)!, value: Double(phase.rawValue))

        e30.setDoubleValueField(CGEventField(rawValue: 124)!, value: currentOriginOffset)

        // Origin offset encoding hack as seen in MMF
        let ofsFloat32 = Float32(currentOriginOffset)
        let ofsInt32 = ofsFloat32.bitPattern
        let ofsInt64 = Int64(ofsInt32)
        e30.setIntegerValueField(CGEventField(rawValue: 135)!, value: ofsInt64)
        e30.setDoubleValueField(CGEventField(rawValue: 41)!, value: 33231)

        var weirdTypeOrSum: Double = -1
        switch type {
        case .horizontal:
            weirdTypeOrSum = 1.401298464324817e-45
        case .vertical:
            weirdTypeOrSum = 2.802596928649634e-45
        case .pinch:
            weirdTypeOrSum = 4.203895392974451e-45
        }

        e30.setDoubleValueField(CGEventField(rawValue: 119)!, value: weirdTypeOrSum)
        e30.setDoubleValueField(CGEventField(rawValue: 139)!, value: weirdTypeOrSum)

        e30.setDoubleValueField(CGEventField(rawValue: 123)!, value: Double(type.rawValue))
        e30.setDoubleValueField(CGEventField(rawValue: 165)!, value: Double(type.rawValue))

        e30.setIntegerValueField(CGEventField(rawValue: 136)!, value: 0) // invertedFromDevice

        if phase == .ended || phase == .cancelled {
            e30.setDoubleValueField(CGEventField(rawValue: 129)!, value: exitSpeed)
            e30.setDoubleValueField(CGEventField(rawValue: 130)!, value: exitSpeed)
        }

        e30.post(tap: .cghidEventTap)
        e29.post(tap: .cghidEventTap)
    }
}
