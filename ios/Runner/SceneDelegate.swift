//
//  SceneDelegate.swift
//  Runner
//
//  Required by flutter_carplay plugin
//

import UIKit
import Flutter

@available(iOS 13.0, *)
@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    private static let quickActionsChannelName = "com.unicornsonlsd.finamp-ios/home_screen_quick_actions"

    var window: UIWindow?

    private var quickActionsChannel: FlutterMethodChannel?
    private var pendingShortcutItem: UIApplicationShortcutItem?
    private var isQuickActionsReady = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)

        let controller = FlutterViewController.init(engine: flutterEngine, nibName: nil, bundle: nil)
        controller.loadDefaultSplashScreenView()
        window?.rootViewController = controller
        window?.makeKeyAndVisible()

        setupQuickActionsChannel(binaryMessenger: controller.binaryMessenger)
        pendingShortcutItem = connectionOptions.shortcutItem
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if isQuickActionsReady {
            deliverShortcut(shortcutItem)
        } else {
            pendingShortcutItem = shortcutItem
        }

        completionHandler(true)
    }

    private func setupQuickActionsChannel(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.quickActionsChannelName,
            binaryMessenger: binaryMessenger
        )
        quickActionsChannel = channel

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "unavailable", message: "Scene delegate is unavailable", details: nil))
                return
            }

            switch call.method {
            case "setShortcuts":
                guard let shortcuts = call.arguments as? [[String: String]] else {
                    result(FlutterError(code: "invalid_arguments", message: "Expected a list of shortcut definitions", details: nil))
                    return
                }

                UIApplication.shared.shortcutItems = shortcuts.compactMap(Self.makeShortcutItem)
                result(nil)

            case "ready":
                self.isQuickActionsReady = true
                result(nil)

                if let pendingShortcutItem = self.pendingShortcutItem {
                    self.pendingShortcutItem = nil
                    self.deliverShortcut(pendingShortcutItem)
                }

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func deliverShortcut(_ shortcutItem: UIApplicationShortcutItem) {
        quickActionsChannel?.invokeMethod("performShortcut", arguments: shortcutItem.type)
    }

    private static func makeShortcutItem(from definition: [String: String]) -> UIApplicationShortcutItem? {
        guard
            let id = definition["id"],
            !id.isEmpty,
            let title = definition["title"],
            !title.isEmpty
        else {
            return nil
        }

        let icon = definition["systemImageName"].map {
            UIApplicationShortcutIcon(systemImageName: $0)
        }

        return UIApplicationShortcutItem(
            type: id,
            localizedTitle: title,
            localizedSubtitle: nil,
            icon: icon,
            userInfo: nil
        )
    }
}
