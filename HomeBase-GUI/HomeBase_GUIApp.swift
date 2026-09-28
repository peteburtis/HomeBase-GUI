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
    @StateObject private var cameraAccess: CameraAccessLifecycle
#if os(iOS)
    @UIApplicationDelegateAdaptor(CameraExternalDisplayAppDelegate.self) private var appDelegate
    @StateObject private var cameraPiP: CameraPictureInPictureController
    @StateObject private var cameraViewer = CameraViewerPresentation()
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
                .modifier(CameraViewerHost(presentation: cameraViewer))
                .modifier(CameraPictureInPictureHost(controller: cameraPiP))
                .environment(\.cameraViewerPresentation, cameraViewer)
#endif
                .environmentObject(serverStore)
                .cameraAccessLifecycle(cameraAccess)
#if os(iOS)
                .modifier(CameraSceneLifecycle(access: cameraAccess, pictureInPicture: cameraPiP))
#else
                .modifier(CameraSceneLifecycle(access: cameraAccess))
#endif
                .onChange(of: serverStore.selectedServerID) { _, _ in
#if os(iOS)
                    cameraPiP.reset()
                    cameraViewer.close()
#endif
                    cameraAccess.reset()
                }
        }

#if os(macOS)
        WindowGroup("Camera", for: CameraWindowRequest.self) { request in
            if let request = request.wrappedValue {
                CameraWindowRoot(request: request)
                    .cameraAccessLifecycle(cameraAccess)
                    .modifier(CameraSceneLifecycle(access: cameraAccess))
            }
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
#endif
    }
}

/// Observe interactive windows individually so one background window cannot
/// suspend another window's camera. iOS output accessories remain separate.
private struct CameraSceneLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
    let access: CameraAccessLifecycle
#if os(iOS)
    let pictureInPicture: CameraPictureInPictureController
#endif

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
#if os(iOS)
                pictureInPicture.scenePhaseChanged(phase)
                access.scenePhaseChanged(phase)
#else
                access.scenePhaseChanged(phase, scene: sceneID)
#endif
            }
#if os(macOS)
            .onDisappear {
                access.sceneDisconnected(sceneID)
            }
#endif
    }
}
