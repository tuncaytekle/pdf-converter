import SwiftUI

/// Banner that displays cloud sync status at the top of the screen
struct CloudSyncBanner: View {
    @ObservedObject var status: CloudSyncStatus
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch status.state {
            case .idle:
                EmptyView()

            case .syncing(let fileCount):
                syncingBanner(fileCount: fileCount)

            case .success(let message):
                successBanner(message: message)

            case .error(let message):
                errorBanner(message: message)

            case .unavailable(let reason):
                unavailableBanner(reason: reason)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: status.state)
    }

    // MARK: - Banner Variants

    private func syncingBanner(fileCount: Int) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())

            Text(fileCount == 1
                 ? NSLocalizedString("Syncing 1 file...", comment: "Syncing single file")
                 : String(format: NSLocalizedString("Syncing %d files...", comment: "Syncing multiple files"), fileCount))
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func successBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.icloud.fill")
                .foregroundColor(.green)
                .font(.title3)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            Button(action: {
                status.dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onTapGesture {
            status.dismiss()
        }
    }

    private func errorBanner(message: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundColor(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("iCloud Sync Failed", comment: "Sync error title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(action: {
                    status.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func unavailableBanner(reason: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.slash.fill")
                .foregroundColor(.gray)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("iCloud Unavailable", comment: "iCloud unavailable title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                // Open Settings app (deep linking to iCloud settings is no longer supported)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }) {
                Text(NSLocalizedString("Settings", comment: "Settings button"))
                    .font(.caption.weight(.medium))
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#if DEBUG
#Preview("Syncing") {
    VStack {
        CloudSyncBanner(status: {
            let status = CloudSyncStatus()
            status.setSyncing(count: 3)
            return status
        }())
        Spacer()
    }
}

#Preview("Success") {
    VStack {
        CloudSyncBanner(status: {
            let status = CloudSyncStatus()
            status.setSuccess("3 files backed up", autoDismiss: false)
            return status
        }())
        Spacer()
    }
}

#Preview("Error") {
    VStack {
        CloudSyncBanner(status: {
            let status = CloudSyncStatus()
            status.setError("Network connection lost")
            return status
        }())
        Spacer()
    }
}

#Preview("Unavailable") {
    VStack {
        CloudSyncBanner(status: {
            let status = CloudSyncStatus()
            status.setUnavailable("Not signed in to iCloud")
            return status
        }())
        Spacer()
    }
}
#endif
