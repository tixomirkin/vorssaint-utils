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
    static var activeSwipeType: DockSwipeType?
    private static var doubleSendTimer: Timer?
    private static var tripleSendTimer: Timer?

    static func beginDockSwipe(delta: Double, type: DockSwipeType) {
        DispatchQueue.main.async {
            doubleSendTimer?.invalidate()
            tripleSendTimer?.invalidate()
            doubleSendTimer = nil
            tripleSendTimer = nil
        }
        currentOriginOffset = delta
        isSynthesizing = true
        activeSwipeType = type
        postDockSwipe(delta: delta, type: type, phase: .began, exitSpeed: 0)
    }

    static func updateDockSwipe(delta: Double, type: DockSwipeType) {
        guard isSynthesizing, let activeType = activeSwipeType else { return }
        if delta == 0 { return }
        currentOriginOffset += delta
        postDockSwipe(delta: currentOriginOffset, type: activeType, phase: .changed, exitSpeed: 0)
    }

    static func endDockSwipe(delta: Double, type: DockSwipeType, exitSpeed: Double = 0) {
        guard isSynthesizing, let activeType = activeSwipeType else { return }
        // For the end gesture, we also pass the final accumulated offset
        postDockSwipe(delta: currentOriginOffset, type: activeType, phase: .ended, exitSpeed: exitSpeed)
        isSynthesizing = false
        currentOriginOffset = 0
        activeSwipeType = nil
    }

    static func cancelDockSwipe(delta: Double, type: DockSwipeType) {
        guard isSynthesizing, let activeType = activeSwipeType else { return }
        postDockSwipe(delta: delta, type: activeType, phase: .cancelled, exitSpeed: 0)
        isSynthesizing = false
        currentOriginOffset = 0
        activeSwipeType = nil
    }

    private static func postDockSwipe(delta: Double, type: DockSwipeType, phase: Phase, exitSpeed: Double) {
        // macOS 27 and newer removed standard CGEvent field routing for this,
        // requiring true HIDEvents to be constructed. But for macOS 14+,
        // we can still synthesize NSEventTypeGesture and NSEventTypeMagnify/30

        guard let e29 = CGEvent(source: nil),
              let e30 = CGEvent(source: nil) else { return }

        // Helper to forcefully set event fields, since rawValue: 55 / 41 / etc are not present in the Swift enum.
        // We use unsafeBitCast to bypass the optional initialization which would fail and skip assignment.
        func setDoubleField(_ event: CGEvent, _ fieldRawValue: UInt32, _ value: Double) {
            let field = unsafeBitCast(fieldRawValue, to: CGEventField.self)
            event.setDoubleValueField(field, value: value)
        }

        func setIntegerField(_ event: CGEvent, _ fieldRawValue: UInt32, _ value: Int64) {
            let field = unsafeBitCast(fieldRawValue, to: CGEventField.self)
            event.setIntegerValueField(field, value: value)
        }

        // Type 29 (NSEventTypeGesture)
        e29.type = CGEventType(rawValue: 29)! // NSEventTypeGesture
        setDoubleField(e29, 55, 29)
        setDoubleField(e29, 41, 33231) // Magic value

        // Type 30 (used for Dock Swipes)
        e30.type = CGEventType(rawValue: 30)! // NSEventTypeMagnify
        setDoubleField(e30, 55, 30)
        setDoubleField(e30, 110, 13) // kIOHIDEventTypeDockSwipe is 13
        setDoubleField(e30, 132, Double(phase.rawValue))
        setDoubleField(e30, 134, Double(phase.rawValue))

        setDoubleField(e30, 124, currentOriginOffset)

        // Origin offset encoding hack as seen in MMF
        let ofsFloat32 = Float32(currentOriginOffset)
        let ofsInt32 = ofsFloat32.bitPattern
        let ofsInt64 = Int64(ofsInt32)
        setIntegerField(e30, 135, ofsInt64)
        setDoubleField(e30, 41, 33231)

        var weirdTypeOrSum: Double = -1
        switch type {
        case .horizontal:
            weirdTypeOrSum = 1.401298464324817e-45
        case .vertical:
            weirdTypeOrSum = 2.802596928649634e-45
        case .pinch:
            weirdTypeOrSum = 4.203895392974451e-45
        }

        setDoubleField(e30, 119, weirdTypeOrSum)
        setDoubleField(e30, 139, weirdTypeOrSum)

        setDoubleField(e30, 123, Double(type.rawValue))
        setDoubleField(e30, 165, Double(type.rawValue))

        setIntegerField(e30, 136, 0) // invertedFromDevice

        if phase == .ended || phase == .cancelled {
            setDoubleField(e30, 129, exitSpeed)
            setDoubleField(e30, 130, exitSpeed)

            // Double-send end-events for macOS to avoid the "stuck bug" where a swipe does not transition properly
            // by scheduling it to fire again after 0.2s and 0.5s.
            // CoreFoundation objects are reference counted, so capturing them in the closure
            // will retain them as long as the timer is alive.
            if let e30Copy = e30.copy(), let e29Copy = e29.copy() {
                DispatchQueue.main.async {
                    doubleSendTimer?.invalidate()
                    tripleSendTimer?.invalidate()

                    doubleSendTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                        if let e30C = e30Copy as? CGEvent, let e29C = e29Copy as? CGEvent {
                            e30C.post(tap: CGEventTapLocation.cghidEventTap)
                            e29C.post(tap: CGEventTapLocation.cghidEventTap)
                        }
                    }
                    tripleSendTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                        if let e30C = e30Copy as? CGEvent, let e29C = e29Copy as? CGEvent {
                            e30C.post(tap: CGEventTapLocation.cghidEventTap)
                            e29C.post(tap: CGEventTapLocation.cghidEventTap)
                        }
                    }
                }
            }
        }

        e30.post(tap: CGEventTapLocation.cghidEventTap)
        e29.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
