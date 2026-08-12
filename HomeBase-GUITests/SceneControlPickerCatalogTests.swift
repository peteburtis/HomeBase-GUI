//
//  SceneControlPickerCatalogTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class SceneControlPickerCatalogTests: XCTestCase {
    func testCatalogMirrorsRoomsNestedGroupsGlobalGroupsAndOther() throws {
        let bedroomLamp = device(
            identifier: "raw-bedroom-lamp",
            addressableName: "BedroomLamp",
            displayName: "Bedroom Lamp"
        )
        let hallLamp = device(
            identifier: "raw-hall-lamp",
            addressableName: "HallLamp",
            displayName: "Hall Lamp"
        )
        let porchLamp = device(
            identifier: "raw-porch-lamp",
            addressableName: "PorchLamp",
            displayName: "Porch Lamp"
        )
        let bedroomLights = device(
            identifier: "BedroomLights",
            addressableName: "BedroomLights",
            displayName: "Bedroom Lights"
        )
        let allLights = device(
            identifier: "AllLights",
            addressableName: "AllLights",
            displayName: "All Lights"
        )

        let localGroup = group(
            identifier: "BedroomLights",
            displayName: "Bedroom Lights",
            roomIdentifier: "Bedroom",
            devices: ["raw-bedroom-lamp"]
        )
        let globalGroup = group(
            identifier: "AllLights",
            displayName: "All Lights",
            devices: [
                "raw-bedroom-lamp",
                "raw-hall-lamp",
                "raw-porch-lamp",
            ]
        )
        let topology = HBTopologyListResult(
            devices: [
                topologyDevice(bedroomLamp),
                topologyDevice(hallLamp),
                topologyDevice(porchLamp),
            ],
            rooms: [
                room(
                    identifier: "Bedroom",
                    displayName: "Bedroom",
                    devices: ["raw-bedroom-lamp"]
                ),
                room(
                    identifier: "Hall",
                    displayName: "Hall",
                    devices: ["raw-hall-lamp"]
                ),
            ],
            groups: [localGroup, globalGroup]
        )
        let catalog = SceneControlPickerCatalog(
            source: SceneConfigurationDeviceCatalog(
                topology: topology,
                devices: [
                    bedroomLamp,
                    hallLamp,
                    porchLamp,
                    bedroomLights,
                    allLights,
                ]
            ),
            excludedControlPaths: []
        )

        XCTAssertEqual(
            catalog.rooms.map(\.displayName),
            ["Bedroom", "Hall", "Other"]
        )
        let bedroom = try XCTUnwrap(
            catalog.rooms.first { $0.identifier == "Bedroom" }
        )
        XCTAssertEqual(
            catalog.devices(in: bedroom).map(\.descriptor.addressableName),
            ["BedroomLamp"]
        )
        XCTAssertEqual(
            catalog.groups(in: bedroom).map(\.identifier),
            ["BedroomLights"]
        )
        XCTAssertEqual(
            catalog.controlDevice(for: localGroup)?.descriptor.addressableName,
            "BedroomLights"
        )
        XCTAssertEqual(
            catalog.topLevelGroups.map(\.identifier),
            ["AllLights"]
        )

        let other = try XCTUnwrap(
            catalog.rooms.first { $0.displayName == "Other" }
        )
        XCTAssertNil(catalog.technicalName(for: other))
        XCTAssertEqual(
            catalog.devices(in: other).map(\.descriptor.addressableName),
            ["PorchLamp"]
        )
        XCTAssertEqual(other.resolvedDeviceIdentifiers, ["raw-porch-lamp"])
    }

    func testCatalogHidesDevicesWhoseOnlyControlIsAlreadyInTheScene() {
        let lamp = device(
            identifier: "raw-lamp",
            addressableName: "HallLamp",
            displayName: "Hall Lamp"
        )
        let catalog = SceneControlPickerCatalog(
            source: SceneConfigurationDeviceCatalog(
                topology: HBTopologyListResult(
                    devices: [topologyDevice(lamp)],
                    rooms: [
                        room(
                            identifier: "Hall",
                            displayName: "Hall",
                            devices: ["raw-lamp"]
                        )
                    ],
                    groups: []
                ),
                devices: [lamp]
            ),
            excludedControlPaths: ["halllamp:binaryswitch"]
        )

        XCTAssertTrue(catalog.isEmpty)
        XCTAssertTrue(catalog.rooms.isEmpty)
    }

    func testCatalogKeepsSelectableDevicesMissingFromTopologyInOther() throws {
        let diagnosticDevice = device(
            identifier: "runtime-probe",
            addressableName: "RuntimeProbe",
            displayName: "Runtime Probe"
        )
        let catalog = SceneControlPickerCatalog(
            source: SceneConfigurationDeviceCatalog(
                topology: HBTopologyListResult(
                    devices: [],
                    rooms: [],
                    groups: []
                ),
                devices: [diagnosticDevice]
            ),
            excludedControlPaths: []
        )

        let other = try XCTUnwrap(catalog.rooms.first)
        XCTAssertEqual(other.displayName, "Other")
        XCTAssertEqual(
            catalog.devices(in: other).map(\.descriptor.addressableName),
            ["RuntimeProbe"]
        )
    }

    func testMixedAggregateColorUsesDedicatedEditorInsteadOfRawJSON() throws {
        let color = HBControlDescriptor(
            identifier: "Color",
            name: "Color",
            kind: "color-v1:RGB+White+XY",
            value: .null,
            projection: .presentation,
            metadata: [
                "readable": true,
                "writable": true,
                "structured": true,
                "aggregateState": "mixed",
                "aggregateValues": [
                    ["RGB": [1, 0, 0]],
                    ["White": 2_700],
                ],
                "aggregateValueCount": 2,
            ]
        )
        let groupDevice = HBDeviceDescriptor(
            identifier: "MainRoomColoredLights",
            addressableName: "MainRoomColoredLights",
            displayName: "Main Room Colored Lights",
            moduleName: "Test",
            controls: [color]
        )
        let catalog = SceneControlPickerCatalog(
            source: SceneConfigurationDeviceCatalog(
                topology: HBTopologyListResult(
                    devices: [],
                    rooms: [],
                    groups: []
                ),
                devices: [groupDevice]
            ),
            excludedControlPaths: []
        )

        let device = try XCTUnwrap(catalog.devices.first)
        XCTAssertEqual(device.supportedControls.map(\.identifier), ["Color"])
        XCTAssertTrue(device.otherWritableControls.isEmpty)

        let target = SceneResolvedControl(
            device: groupDevice,
            descriptor: color
        )
        XCTAssertEqual(target.valueEntryMode, .dedicatedEditor)
        XCTAssertEqual(
            target.descriptor.listedControlValueSnapshot.aggregateState,
            .mixed
        )
        XCTAssertEqual(
            target.descriptor.listedControlValueSnapshot.aggregateValues,
            [
                ["RGB": [1, 0, 0]],
                ["White": 2_700],
            ]
        )
    }

    private func device(
        identifier: String,
        addressableName: String,
        displayName: String
    ) -> HBDeviceDescriptor {
        HBDeviceDescriptor(
            identifier: identifier,
            addressableName: addressableName,
            displayName: displayName,
            moduleName: "Test",
            controls: [
                HBControlDescriptor(
                    identifier: "BinarySwitch",
                    name: "Switch",
                    kind: "BinarySwitch",
                    value: 1,
                    projection: .presentation,
                    metadata: [
                        "readable": true,
                        "writable": true,
                        "structured": false,
                        "minimum": 0,
                        "maximum": 1,
                    ]
                )
            ]
        )
    }

    private func topologyDevice(
        _ device: HBDeviceDescriptor
    ) -> HBTopologyDeviceDescriptor {
        HBTopologyDeviceDescriptor(
            identifier: device.identifier,
            addressableName: device.addressableName,
            displayName: device.displayName
        )
    }

    private func room(
        identifier: String,
        displayName: String,
        devices: [String]
    ) -> HBTopologyRoomDescriptor {
        HBTopologyRoomDescriptor(
            identifier: identifier,
            displayName: displayName,
            members: devices.map {
                HBTopologyMemberDescriptor(kind: .device, identifier: $0)
            },
            resolvedDeviceIdentifiers: devices
        )
    }

    private func group(
        identifier: String,
        displayName: String,
        roomIdentifier: String? = nil,
        devices: [String]
    ) -> HBTopologyGroupDescriptor {
        HBTopologyGroupDescriptor(
            identifier: identifier,
            displayName: displayName,
            origin: .configured,
            role: .lights,
            roomIdentifier: roomIdentifier,
            members: devices.map {
                HBTopologyMemberDescriptor(kind: .device, identifier: $0)
            },
            resolvedDeviceIdentifiers: devices,
            controlDeviceIdentifier: identifier
        )
    }
}
