//
//  HomeBase_GUIApp.swift
//  HomeBase-GUI
//
//  Created by bitwise on 8/7/26.
//

import SwiftUI

@main
struct HomeBase_GUIApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var serverStore = PairedServerStore()
    @StateObject private var cameraAccess = CameraAccessLifecycle()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverStore)
                .cameraAccessLifecycle(cameraAccess)
                .onChange(of: scenePhase) { _, phase in
                    cameraAccess.scenePhaseChanged(phase)
                }
                .onChange(of: serverStore.selectedServerID) { _, _ in
                    cameraAccess.reset()
                }
        }
    }
}
