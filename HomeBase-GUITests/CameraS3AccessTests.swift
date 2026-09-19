import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraS3AccessTests: XCTestCase {
    private let storeID = "8EC120A6-5FF1-49E2-83CF-F7C2BCFF8A31"

    private func store(name: String = "Archive", bucket: String = "camera-recordings",
                       region: String = "us-west-2", prefix: String = "nvr/",
                       encryption: String? = "hbnvr-pbe-v1") -> HBCameraPlaybackMetadata.S3Store {
        .init(id: storeID, name: name, bucket: bucket, region: region, prefix: prefix,
              expectedOwner: "123456789012", clientEncryptionFormat: encryption)
    }

    private func metadata(s3: HBCameraPlaybackMetadata.S3Store?, available: Bool = true,
                          local: Bool = true) throws -> [String: HBJSONValue] {
        var playback = HBCameraPlaybackMetadata(nvrInstanceID: UUID().uuidString,
            cameraID: UUID().uuidString,
            stores: local ? [.init(id: UUID().uuidString, name: "Local")] : [], s3Store: s3)
        playback.available = available
        return [HBDeviceMetadataKeys.cameraPlayback: try HBJSONValue(encoding: playback)]
    }

    func testOldServerOrNoS3AdvertisementDoesNotOfferPadlock() throws {
        XCTAssertNil(CameraS3Destination.advertised(in: [:]))
        XCTAssertNil(CameraS3Destination.advertised(in: try metadata(s3: nil)))
        XCTAssertNil(CameraS3Destination.advertised(in: [HBDeviceMetadataKeys.cameraPlayback: .string("bad")]))
    }

    func testS3AdvertisementIsIndependentOfLocalAvailability() throws {
        for available in [true, false] {
            for local in [true, false] {
                let value = try metadata(s3: store(), available: available, local: local)
                XCTAssertNotNil(CameraS3Destination.advertised(in: value))
                XCTAssertEqual(CameraPlaybackHistoryAvailability.isAvailable(in: value), available && local)
            }
        }
    }

    func testCredentialBindingSurvivesCameraStoreRenameAndDaemonRestart() throws {
        let first = try XCTUnwrap(CameraS3Destination.advertised(in: metadata(s3: store())))
        let next = try XCTUnwrap(CameraS3Destination.advertised(in: metadata(s3: store(name: "New name"))))
        XCTAssertEqual(first.id, next.id)
        XCTAssertEqual(first.id, CameraS3Destination(store: store(encryption: nil)).id,
                       "Encryption toggles must not silently switch credential identity")
    }

    func testCredentialBindingIncludesDestinationNotOnlyStoreID() {
        let first = CameraS3Destination(store: store()).id
        XCTAssertNotEqual(first, CameraS3Destination(store: store(bucket: "another-bucket")).id)
        XCTAssertNotEqual(first, CameraS3Destination(store: store(region: "eu-west-1")).id)
        XCTAssertNotEqual(first, CameraS3Destination(store: store(prefix: "another/")).id)
    }

    func testMalformedDestinationDoesNotOfferCredentialEntry() throws {
        XCTAssertNil(CameraS3Destination.advertised(in: try metadata(s3: store(bucket: ""))))
        XCTAssertNil(CameraS3Destination.advertised(in: try metadata(s3: store(prefix: "bad\nvalue"))))
    }

    func testPadlockAppearsOnlyOnMissingVideoAndNeverDuringLoading() {
        let destination = CameraS3Destination(store: store())
        for state in [CameraHistoryPlayback.State.gap, .failed("offline"), .idle] {
            XCTAssertTrue(CameraS3AccessPolicy.showsPadlock(isLive: false, showsVideo: false,
                historyState: state, resolvingTime: false, destination: destination, unlockedDestinationID: nil))
        }
        XCTAssertFalse(CameraS3AccessPolicy.showsPadlock(isLive: true, showsVideo: false,
            historyState: .gap, resolvingTime: false, destination: destination, unlockedDestinationID: nil))
        XCTAssertFalse(CameraS3AccessPolicy.showsPadlock(isLive: false, showsVideo: true,
            historyState: .ready, resolvingTime: false, destination: destination, unlockedDestinationID: nil))
        XCTAssertFalse(CameraS3AccessPolicy.showsPadlock(isLive: false, showsVideo: false,
            historyState: .loading, resolvingTime: false, destination: destination, unlockedDestinationID: nil))
        XCTAssertFalse(CameraS3AccessPolicy.showsPadlock(isLive: false, showsVideo: false,
            historyState: .gap, resolvingTime: true, destination: destination, unlockedDestinationID: nil))
        XCTAssertFalse(CameraS3AccessPolicy.showsPadlock(isLive: false, showsVideo: false,
            historyState: .gap, resolvingTime: false, destination: nil, unlockedDestinationID: nil))
    }

    func testAlreadyUnlockedStoreHasNoPadlockButDifferentStoreStillOffersSetup() {
        let destination = CameraS3Destination(store: store())
        XCTAssertFalse(CameraS3AccessPolicy.showsPadlock(isLive: false, showsVideo: false,
            historyState: .gap, resolvingTime: false, destination: destination, unlockedDestinationID: destination.id))
        XCTAssertTrue(CameraS3AccessPolicy.showsPadlock(isLive: false, showsVideo: false,
            historyState: .gap, resolvingTime: false, destination: destination, unlockedDestinationID: "another-store"))
    }

    func testReaderPolicyGrantsOnlyObjectReadsWithinAdvertisedPrefix() throws {
        let json = try CameraS3ReadPolicy.json(for: store())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["Version"] as? String, "2012-10-17")
        let statements = try XCTUnwrap(object["Statement"] as? [[String: Any]])
        XCTAssertEqual(statements.count, 1)
        let statement = try XCTUnwrap(statements.first)
        XCTAssertEqual(statement["Effect"] as? String, "Allow")
        XCTAssertEqual(statement["Action"] as? [String], ["s3:GetObject"])
        XCTAssertEqual(statement["Resource"] as? String, "arn:aws:s3:::camera-recordings/nvr/*")
        XCTAssertNil(statement["Principal"], "An identity policy, not a public bucket policy")
        XCTAssertFalse(json.contains("123456789012"), "An S3 object ARN does not embed the account ID")
        XCTAssertFalse(json.contains("ListBucket"))
    }

    func testReaderPolicyPreservesExactPrefixAndSupportsAWSPartitions() throws {
        for (region, partition) in [("us-west-2", "aws"), ("cn-north-1", "aws-cn"), ("us-gov-west-1", "aws-us-gov")] {
            for prefix in ["", "hbnvr/a b/", "cameras/日本語/", "quote\"slash\\/"] {
                let json = try CameraS3ReadPolicy.json(for: store(region: region, prefix: prefix))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let statement = try XCTUnwrap((object["Statement"] as? [[String: Any]])?.first)
                XCTAssertEqual(statement["Resource"] as? String, "arn:\(partition):s3:::camera-recordings/\(prefix)*")
            }
        }
        XCTAssertEqual(try CameraS3ReadPolicy.json(for: store(encryption: nil)),
                       try CameraS3ReadPolicy.json(for: store(encryption: "hbnvr-pbe-v1")))
    }

    func testReaderPolicyRefusesIAMWildcardsVariablesAndMalformedDestinations() {
        for prefix in ["nvr/*/", "nvr/?/", "nvr/${aws:username}/", "nvr/\n", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try CameraS3ReadPolicy.json(for: store(prefix: prefix)))
        }
        for bucket in ["*", "bad/bucket", "${aws:username}", "bad\nname", "", "ab", "bad..bucket"] {
            XCTAssertThrowsError(try CameraS3ReadPolicy.json(for: store(bucket: bucket)))
        }
        XCTAssertThrowsError(try CameraS3ReadPolicy.json(for: store(region: "not-a-region")))
    }
}
