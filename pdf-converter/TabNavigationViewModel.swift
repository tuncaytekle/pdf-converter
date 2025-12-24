//
//  TabNavigationViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class TabNavigationViewModel: ObservableObject {
    private var currentTab: Tab?

    func trackTabSwitched(analytics: AnalyticsTracking, from: Tab, to: Tab) {
        let fromName = tabName(from)
        let toName = tabName(to)

        analytics.capture("tab_switched", properties: [
            "from": fromName,
            "to": toName
        ])

        // Also track screen view
        analytics.screen(toName.capitalized, properties: [:])
    }

    func trackTabIfNeeded(analytics: AnalyticsTracking, tab: Tab) {
        if let current = currentTab, current != tab {
            trackTabSwitched(analytics: analytics, from: current, to: tab)
        }
        currentTab = tab
    }

    private func tabName(_ tab: Tab) -> String {
        switch tab {
        case .files: return "files"
        case .tools: return "tools"
        case .settings: return "settings"
        case .account: return "account"
        }
    }
}
