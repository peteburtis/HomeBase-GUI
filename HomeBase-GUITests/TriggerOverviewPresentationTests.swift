//
//  TriggerOverviewPresentationTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class TriggerOverviewPresentationTests: XCTestCase {
    func testLastFiredPresentationOnlyAppliesToWhenTriggers() {
        let date = Date(timeIntervalSince1970: 1_234)

        XCTAssertEqual(
            TriggerOverviewPresentation.lastFired(
                for: trigger(kind: .when, lastFiredAt: date)
            ),
            .date(date)
        )
        XCTAssertEqual(
            TriggerOverviewPresentation.lastFired(
                for: trigger(kind: .when, lastFiredAt: nil)
            ),
            .never
        )
        XCTAssertEqual(
            TriggerOverviewPresentation.lastFired(
                for: trigger(kind: .while, lastFiredAt: date)
            ),
            .omitted
        )
    }

    func testConditionTreeFlattensInDisplayOrderWithDepth() {
        let child = condition(
            path: "conditions.0.children.0",
            type: "ControlValueGreaterThan",
            configuration: .array([
                .string("Sensor"),
                .string("Presence"),
                .number(0.5),
            ]),
            status: .satisfied
        )
        let root = condition(
            path: "conditions.0",
            type: "Or",
            configuration: .array([]),
            status: .satisfied,
            children: [child]
        )

        let flattened = TriggerOverviewPresentation.flatten([root])

        XCTAssertEqual(flattened.map(\.id), [
            "conditions.0",
            "conditions.0.children.0",
        ])
        XCTAssertEqual(flattened.map(\.depth), [0, 1])
    }

    func testCompareConditionUsesReadableControlPathExpression() {
        let descriptor = condition(
            path: "conditions.0",
            type: "Compare",
            configuration: .array([
                .object([
                    "ControlValue": .array([
                        .string("HallSensor"),
                        .string("Motion"),
                    ])
                ]),
                .string("=="),
                .integer(1),
            ]),
            status: .satisfied
        )

        XCTAssertEqual(
            TriggerOverviewPresentation.conditionSummary(descriptor),
            "Equals 1"
        )
        let presentation = TriggerConditionTypeRegistry.standard.presentation(
            for: descriptor
        )
        XCTAssertEqual(presentation.title, "Hall Sensor — Motion")
    }

    func testLegacyControlConditionUsesReadableComparison() {
        let descriptor = condition(
            path: "conditions.0",
            type: "ControlValueLessThanOrEqual",
            configuration: .array([
                .string("Thermostat"),
                .string("Temperature"),
                .integer(68),
            ]),
            status: .unsatisfied
        )

        XCTAssertEqual(
            TriggerOverviewPresentation.conditionSummary(descriptor),
            "Is Less Than or Equal To 68"
        )
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.presentation(
                for: descriptor
            ).title,
            "Thermostat — Temperature"
        )
    }

    func testNestedLogicSummaryDoesNotRepeatRawChildJSON() {
        let descriptor = condition(
            path: "conditions.0",
            type: "And",
            configuration: .array([]),
            status: .unsatisfied,
            children: [
                condition(
                    path: "conditions.0.children.0",
                    type: "DayOfWeek",
                    configuration: .string("M-F"),
                    status: .satisfied
                ),
                condition(
                    path: "conditions.0.children.1",
                    type: "TimeOfDay",
                    configuration: .string("08:00-18:00"),
                    status: .satisfied
                ),
            ]
        )

        XCTAssertEqual(
            TriggerOverviewPresentation.conditionSummary(descriptor),
            "2 conditions"
        )
    }

    private func condition(
        path: String,
        type: String,
        configuration: HBJSONValue,
        status: HBTriggerConditionStatus,
        children: [HBTriggerConditionDescriptor] = []
    ) -> HBTriggerConditionDescriptor {
        HBTriggerConditionDescriptor(
            path: path,
            type: type,
            configuration: configuration,
            status: status,
            effectiveTruth: status == .satisfied,
            trueWhileInvalid: false,
            children: children
        )
    }

    private func trigger(
        kind: HBTriggerKind,
        lastFiredAt: Date?
    ) -> HBTriggerSummaryDescriptor {
        HBTriggerSummaryDescriptor(
            name: "Example",
            kind: kind,
            state: kind == .when ? .satisfied : .active,
            schedulerRunning: true,
            lastFiredAt: lastFiredAt
        )
    }
}
