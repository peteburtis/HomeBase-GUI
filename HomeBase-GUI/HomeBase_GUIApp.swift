//
//  HomeBase_GUIApp.swift
//  HomeBase-GUI
//
//  Created by bitwise on 8/7/26.
//

import SwiftUI

#if os(iOS)
import UIKit

@MainActor
final class HomeBaseApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        CameraLandscapeOrientation.supportedInterfaceOrientations(
            for: window
        )
    }
}
#endif

@main
struct HomeBase_GUIApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(HomeBaseApplicationDelegate.self)
    private var applicationDelegate
#endif
    @StateObject private var serverStore = PairedServerStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverStore)
        }
    }
}
