//
//  DeviceAdvancedStackPresentationTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class DeviceAdvancedStackPresentationTests: XCTestCase {
    private let layerID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000111"
    )!
    private let createdAt = Date(timeIntervalSince1970: 100)

    func testAggregateLayerIdentityIncludesControlPath() {
        let layer = makeLayer(activeCount: 1)
        let first = DeviceAdvancedAggregateLayerPresentation(
            controlPath: "Room:Lights",
            layer: layer,
            constituentCount: 3
        )
        let second = DeviceAdvancedAggregateLayerPresentation(
            controlPath: "House:Lights",
            layer: layer,
            constituentCount: 3
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.hasSuffix(layerID.uuidString.lowercased()))
    }

    func testEveryLayerWinningAtLeastOneLeafIsProminent() {
        let broad = DeviceAdvancedAggregateLayerPresentation(
            controlPath: "Room:Lights",
            layer: makeLayer(activeCount: 2),
            constituentCount: 3
        )
        let leafException = DeviceAdvancedAggregateLayerPresentation(
            controlPath: "Room:Lights",
            layer: makeLayer(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000112"
                )!,
                coverageCount: 1,
                activeCount: 1
            ),
            constituentCount: 3
        )
        let obscured = DeviceAdvancedAggregateLayerPresentation(
            controlPath: "Room:Lights",
            layer: makeLayer(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000113"
                )!,
                activeCount: 0
            ),
            constituentCount: 3
        )

        XCTAssertTrue(broad.isActive)
        XCTAssertTrue(leafException.isActive)
        XCTAssertFalse(obscured.isActive)
        XCTAssertTrue(broad.details.contains("retained winner: 2 of 3"))
        XCTAssertTrue(leafException.details.contains("coverage: 1 of 3"))
    }

    func testMixedLayerPreservesAlignedLeafValueSample() {
        let presentation = DeviceAdvancedAggregateLayerPresentation(
            controlPath: "Room:Lights",
            layer: makeLayer(
                activeCount: 2,
                aggregateState: .mixed,
                value: nil,
                values: [0.2, nil, nil],
                valueStates: [.defined, .uncovered, .unavailable]
            ),
            constituentCount: 3
        )

        XCTAssertEqual(
            presentation.valueText,
            "Mixed [0.2, —, Unavailable]"
        )
    }

    func testAggregateOverridePresentsObservedAndReturnStatesSeparately() {
        let presentation = DeviceAdvancedAggregateOverridePresentation(
            value: HBControlStackAggregateOverride(
                coverageCount: 2,
                observedState: .mixed,
                observedValues: [1, nil, nil],
                observedValueStates: [.defined, .defined, .uncovered],
                capturedReturnState: .defined,
                capturedReturnValue: 0.4
            ),
            constituentCount: 3
        )

        XCTAssertEqual(presentation.observedValueText, "Mixed [1, null, —]")
        XCTAssertEqual(presentation.returnValueText, "0.4")
        XCTAssertEqual(presentation.coverageText, "coverage: 2 of 3")
    }

    func testConstituentRowIdentityUsesLogicalLayerInsteadOfToken() {
        let control = HBControlReference(
            deviceIdentifier: "Lamp",
            controlIdentifier: "Level"
        )
        let first = DeviceAdvancedConstituentPresentation(
            value: HBControlStackConstituent(
                control: control,
                holds: [makeHold(identifierSuffix: "201")]
            )
        )
        let refreshed = DeviceAdvancedConstituentPresentation(
            value: HBControlStackConstituent(
                control: control,
                holds: [makeHold(identifierSuffix: "202")]
            )
        )

        XCTAssertEqual(first.holds.first?.id, refreshed.holds.first?.id)
        XCTAssertEqual(first.controlPath, "Lamp:Level")
    }

    func testConstituentExposesUnavailableOverrideSuppression() {
        let presentation = DeviceAdvancedConstituentPresentation(
            value: HBControlStackConstituent(
                control: HBControlReference(
                    deviceIdentifier: "Lamp",
                    controlIdentifier: "Level"
                ),
                holds: [],
                hasExternalOverrideSuppression: true
            )
        )

        XCTAssertTrue(presentation.hasUnavailableExternalOverride)
        XCTAssertTrue(presentation.hasExternalOverrideSuppression)
        XCTAssertNil(presentation.externalOverride)
    }

    func testUnavailableConstituentHoldDoesNotRenderAsJSONNull() {
        var hold = makeHold(identifierSuffix: "203")
        hold.value = .null
        hold.valueState = .unavailable
        let presentation = DeviceAdvancedConstituentHoldPresentation(
            controlPath: "Lamp:Level",
            hold: hold
        )

        XCTAssertEqual(presentation.valueText, "Unavailable")
    }

    private func makeLayer(
        identifier: UUID? = nil,
        coverageCount: Int = 3,
        activeCount: Int,
        aggregateState: HBControlAggregateState = .defined,
        value: HBJSONValue? = 0.5,
        values: [HBJSONValue?]? = nil,
        valueStates: [HBControlStackValueState]? = nil
    ) -> HBControlStackLayer {
        HBControlStackLayer(
            identifier: identifier ?? layerID,
            kind: .hold,
            coverageCount: coverageCount,
            activeCount: activeCount,
            aggregateState: aggregateState,
            value: value,
            values: values,
            valueStates: valueStates,
            priority: 4,
            sourceName: "Scene",
            createdAt: createdAt
        )
    }

    private func makeHold(identifierSuffix: String) -> HBHoldDescriptor {
        HBHoldDescriptor(
            identifier: UUID(
                uuidString: "00000000-0000-0000-0000-000000000\(identifierSuffix)"
            )!,
            logicalLayerID: layerID,
            ownerClientID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000301"
            )!,
            control: HBControlReference(
                deviceIdentifier: "Lamp",
                controlIdentifier: "Level"
            ),
            value: 0.5,
            priority: 4,
            createdAt: createdAt,
            active: true
        )
    }
}
