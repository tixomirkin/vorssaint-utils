// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MouseButtonActionType: String, Codable {
    case shortcut
    case missionControlAndSpaces
}

struct MouseButtonAction: Codable, Equatable {
    var type: MouseButtonActionType
    var shortcut: GlobalShortcut?

    init(type: MouseButtonActionType, shortcut: GlobalShortcut? = nil) {
        self.type = type
        self.shortcut = shortcut
    }
}

struct MouseButtonConfig: Codable, Equatable {
    var click: MouseButtonAction?
    var hold: MouseButtonAction?
    var drag: MouseButtonAction?
    var scroll: MouseButtonAction?

    init(click: MouseButtonAction? = nil, hold: MouseButtonAction? = nil, drag: MouseButtonAction? = nil, scroll: MouseButtonAction? = nil) {
        self.click = click
        self.hold = hold
        self.drag = drag
        self.scroll = scroll
    }
}
