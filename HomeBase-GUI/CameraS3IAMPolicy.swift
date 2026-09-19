import Foundation
import HomeBaseProtocol
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Identity policy for the client, never the recorder's write credential.
/// Predictable manifest keys and their referenced objects need no bucket list.
enum CameraS3ReadPolicy {
    enum Failure: Error, LocalizedError {
        case unsafeDestination
        var errorDescription: String? {
            "A safely scoped policy could not be generated for the advertised S3 destination."
        }
    }

    static func json(for store: HBCameraPlaybackMetadata.S3Store) throws -> String {
        // Metadata comes from the server. Never turn IAM wildcard/variable
        // characters in a bucket or prefix into broader access than advertised.
        guard (3...63).contains(store.bucket.utf8.count),
              store.bucket.range(of: "^[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression) != nil,
              !store.bucket.contains(".."),
              store.region.range(of: "^(?:[a-z]{2}-[a-z]+-[0-9]+|us-gov-[a-z]+-[0-9]+)$", options: .regularExpression) != nil,
              store.prefix.utf8.count <= 1024,
              store.prefix.rangeOfCharacter(from: .controlCharacters) == nil,
              !store.prefix.contains("*"), !store.prefix.contains("?"), !store.prefix.contains("${") else {
            throw Failure.unsafeDestination
        }
        let partition = store.region.hasPrefix("cn-") ? "aws-cn"
            : (store.region.hasPrefix("us-gov-") ? "aws-us-gov" : "aws")
        let policy: [String: Any] = [
            "Version": "2012-10-17",
            "Statement": [[
                "Sid": "ReadHomeBaseRecordings",
                "Effect": "Allow",
                "Action": ["s3:GetObject"],
                "Resource": "arn:\(partition):s3:::\(store.bucket)/\(store.prefix)*",
            ]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: policy,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

struct CameraS3IAMPolicyView: View {
    let destination: CameraS3Destination
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("Create a separate IAM user without console access. Attach this as its only permissions policy, then create an access key for use outside AWS and enter it on the S3 Access screen.")
                Text("Allows object reads only within this store's prefix, including manifests and recordings. No listing, uploads, deletion, or bucket administration.")
                    .foregroundStyle(.secondary)
                if destination.store.prefix.isEmpty {
                    Text("This store uses the bucket root, so the policy allows reading every object in that bucket.")
                        .foregroundStyle(.secondary)
                }
            }
            if let json = try? CameraS3ReadPolicy.json(for: destination.store) {
                Section("IAM permissions JSON") {
                    Button(copied ? "Copied" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc") {
#if os(iOS)
                        UIPasteboard.general.string = json
#elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
#endif
                        copied = true
                    }
                    .accessibilityIdentifier("camera.s3.copyIAMPolicy")
                    ShareLink("Share JSON", item: json)
                    ScrollView(.horizontal) {
                        Text(json)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            } else {
                Section {
                    Text(CameraS3ReadPolicy.Failure.unsafeDestination.localizedDescription)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text("This policy adds permissions; it does not restrict access granted by other policies. Use a dedicated reader identity. The encryption password stays in the app and is not part of this policy.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Read-only IAM Policy")
    }
}
