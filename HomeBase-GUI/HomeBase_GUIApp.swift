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
                .modifier(CameraPhoneSceneLifecycle(access: cameraAccess, pictureInPicture: cameraPiP))
#else
                .modifier(CameraPhoneSceneLifecycle(access: cameraAccess))
#endif
                .onChange(of: serverStore.selectedServerID) { _, _ in
#if os(iOS)
                    cameraPiP.reset()
                    cameraViewer.close()
#endif
                    cameraAccess.reset()
                }
        }
    }
}

/// Observe the interactive window, not the App's aggregate scene phase: an
/// external scene remaining active must not keep phone previews/controls alive.
private struct CameraPhoneSceneLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let access: CameraAccessLifecycle
#if os(iOS)
    let pictureInPicture: CameraPictureInPictureController
#endif

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
#if os(iOS)
            pictureInPicture.scenePhaseChanged(phase)
#endif
            access.scenePhaseChanged(phase)
        }
    }
}
