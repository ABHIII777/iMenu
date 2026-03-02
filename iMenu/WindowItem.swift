//
//  WindowItem.swift
//  iMenu
//
//  Created by Abhi Patel on 02/03/26.
//

import ScreenCaptureKit
import AppKit

struct WindowItem: Identifiable {
    let id = UUID()
    let window: SCWindow
    let app: NSRunningApplication
}