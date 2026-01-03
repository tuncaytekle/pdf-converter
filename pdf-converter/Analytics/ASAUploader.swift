import Foundation
import AdServices

enum ASAUploader {
    @MainActor private static let didSendKey = "asa_attribution_sent_v1"

    static func sendIfNeeded() {
        Task { // inherits the current actor; safe to hop to MainActor explicitly below
            // 1) MainActor section: read/write defaults and fetch anonymousId
            let shouldSend: Bool = await MainActor.run {
                !UserDefaults.standard.bool(forKey: didSendKey)
            }
            guard shouldSend else { return }
            guard #available(iOS 14.3, *) else { return }

            // getOrCreate() is MainActor-isolated in your project, so call it on MainActor
            let anonymousId: String = await MainActor.run {
                AnonymousIdProvider.getOrCreate()
            }

            // 2) Non-UI work can happen off-main
            do {
                let token = try AAAttribution.attributionToken()

                var request = URLRequest(url: URL(string: "https://YOUR_CLOUD_RUN_URL/v1/asa/attribution")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("UX_X9d6Y9xP7LOSbhIy_QUgBWUeZF7vvkpNFi50nNWo", forHTTPHeaderField: "X-ASA-INGEST-KEY")

                let body: [String: Any] = [
                    "anonymousId": anonymousId,
                    "token": token,
                    "bundleId": Bundle.main.bundleIdentifier ?? ""
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

                let (_, response) = try await URLSession.shared.data(for: request)

                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    await MainActor.run {
                        UserDefaults.standard.set(true, forKey: didSendKey)
                    }
                }
            } catch {
                // keep simple: ignore; will retry next launch
            }
        }
    }
}
