//
//  ServiceOpsApp.swift
//  ServiceOps
//
//  Created by Anushka Wijesundara on 2026/08/14.
//

import SwiftUI

@main
struct ServiceOpsApp: App {
    @UIApplicationDelegateAdaptor(ServiceOpsAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
