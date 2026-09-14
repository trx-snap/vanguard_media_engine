// VGGreenScreenExportMethodHandler.swift
// Thin dispatch layer from VanguardMediaEnginePlugin for green-screen export routes.

import Flutter
import Foundation

/// Thin dispatch handler for green-screen export MethodChannel routes.
/// Plugin owns one instance and calls `handle` for routes `ownsMethod` returns true for.
final class VGGreenScreenExportMethodHandler {

    // MARK: - Owned routes

    private static let ownedMethods: Set<String> = [
        "exportGreenScreenComposition",
    ]

    static func ownsMethod(_ method: String) -> Bool {
        return ownedMethods.contains(method)
    }

    // MARK: - Session

    private let exportSession = VGGreenScreenExportSession()

    // MARK: - Init

    init() {
    }

    // MARK: - Dispatch

    func handle(method: String, args: [String: Any]?, result: @escaping FlutterResult) {
        switch method {

        case "exportGreenScreenComposition":
            exportSession.export(args: args, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Teardown

    func disposeAll() {
        exportSession.disposeAll()
    }
}
