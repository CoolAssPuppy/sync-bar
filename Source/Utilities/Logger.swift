//
//  Logger.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import os

enum Log {
    private static let subsystem = "com.strategicnerds.SyncBar"

    static let app       = Logger(subsystem: subsystem, category: "app")
    static let sync      = Logger(subsystem: subsystem, category: "sync")
    static let notion    = Logger(subsystem: subsystem, category: "notion")
    static let remarkable = Logger(subsystem: subsystem, category: "remarkable")
    static let ocr       = Logger(subsystem: subsystem, category: "ocr")
    static let ledger    = Logger(subsystem: subsystem, category: "ledger")
    static let ui        = Logger(subsystem: subsystem, category: "ui")
    static let google    = Logger(subsystem: subsystem, category: "google")
}
