//
//  PostHogTracker.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/24/25.
//


import Foundation
import PostHog

final class PostHogTracker: AnalyticsTracking {
    func identify(_ distinctId: String) {
        PostHogSDK.shared.identify(distinctId)
    }

    func capture(_ event: String, properties: [String: Any]) {
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func screen(_ name: String, properties: [String: Any]) {
        PostHogSDK.shared.screen(name, properties: properties)
    }
}
