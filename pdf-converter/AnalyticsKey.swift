//
//  AnalyticsKey.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/24/25.
//


import SwiftUI

private struct AnalyticsKey: EnvironmentKey {
    static let defaultValue: AnalyticsTracking = NoopTracker()
}

extension EnvironmentValues {
    var analytics: AnalyticsTracking {
        get { self[AnalyticsKey.self] }
        set { self[AnalyticsKey.self] = newValue }
    }
}

final class NoopTracker: AnalyticsTracking {
    func identify(_ distinctId: String) {}
    func capture(_ event: String, properties: [String : Any]) {}
    func screen(_ name: String, properties: [String : Any]) {}
}
