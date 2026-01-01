//
//  AnalyticsTracking.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/24/25.
//


import Foundation

protocol AnalyticsTracking {
    func identify(_ distinctId: String)
    func capture(_ event: String, properties: [String: Any])
    func screen(_ name: String, properties: [String: Any])
}
