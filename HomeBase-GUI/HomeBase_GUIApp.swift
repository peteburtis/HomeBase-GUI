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
    @StateObject private var cameraAccess: CameraAccessLifecycle
#if os(iOS)
    @StateObject private var cameraPiP: CameraPictureInPictureController
#endif

    init() {
        let access = CameraAccessLifecycle(session: CameraPiPTestFixture.makeAccessSession())
        _cameraAccess = StateObject(wrappedValue: access)
#if os(iOS)
        _cameraPiP = StateObject(wrappedValue: CameraPictureInPictureController(accessLifecycle: access))
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
#if os(iOS)
                .modifier(CameraPictureInPictureHost(controller: cameraPiP))
#endif
                .environmentObject(serverStore)
                .cameraAccessLifecycle(cameraAccess)
                .onChange(of: scenePhase) { _, phase in
#if os(iOS)
                    cameraPiP.scenePhaseChanged(phase)
#endif
                    cameraAccess.scenePhaseChanged(phase)
                }
                .onChange(of: serverStore.selectedServerID) { _, _ in
#if os(iOS)
                    cameraPiP.reset()
#endif
                    cameraAccess.reset()
                }
        }
    }
}
