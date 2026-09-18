//
//  HomeBase_GUIApp.swift
//  HomeBase-GUI
//
//  Created by bitwise on 8/7/26.
//

import SwiftUI

@main
struct HomeBase_GUIApp: App {
    @StateObject private var serverStore = PairedServerStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverStore)
        }
    }
}
