import Foundation
import LocalAuthentication

/// Result wrapper for `LAContext` authentication requests.
enum BiometricAuthResult {
    case success
    case failed
    case cancelled
    case unavailable(String)
    case error(String)
}

/// Small helper that normalizes biometric/passcode prompts for previews and settings.
enum BiometricAuthenticator {
    @MainActor
    static func authenticate(reason: String) async -> BiometricAuthResult {
        let biometricContext = LAContext()
        biometricContext.localizedFallbackTitle = NSLocalizedString("biometrics.fallback", comment: "Fallback button title")

        var biometricError: NSError?
        let canUseBiometrics = biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)

        let fallbackContext = LAContext()
        var passcodeError: NSError?
        let canUsePasscode = fallbackContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError)

        guard canUseBiometrics || canUsePasscode else {
            let message = biometricError?.localizedDescription
                ?? passcodeError?.localizedDescription
                ?? NSLocalizedString("biometrics.unavailable.message", comment: "Biometrics unavailable message")
            return .unavailable(message)
        }

        do {
            if canUseBiometrics {
                do {
                    let granted = try await evaluate(policy: .deviceOwnerAuthenticationWithBiometrics, using: biometricContext, reason: reason)
                    return granted ? .success : .failed
                } catch let laError as LAError {
                    switch laError.code {
                    case .userFallback, .biometryLockout:
                        guard canUsePasscode else { return .error(laError.localizedDescription) }
                        let granted = try await evaluate(policy: .deviceOwnerAuthentication, using: fallbackContext, reason: reason)
                        return granted ? .success : .failed
                    case .userCancel, .systemCancel:
                        return .cancelled
                    default:
                        return .error(laError.localizedDescription)
                    }
                }
            }

            let granted = try await evaluate(policy: .deviceOwnerAuthentication, using: fallbackContext, reason: reason)
            return granted ? .success : .failed
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel:
                return .cancelled
            default:
                return .error(laError.localizedDescription)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    @MainActor
    private static func evaluate(policy: LAPolicy, using context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
