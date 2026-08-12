//
//  TriggerTimeOfDayCondition.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

/// A lossless lens over HomeBase's TimeOfDay condition. The source may use a
/// single expression or a one/two-element array; that choice is retained until
/// the user explicitly adds or removes an end expression.
struct TriggerTimeOfDayCondition: Equatable, Sendable {
    struct Expression: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case clock
            case function(String)
        }

        static let knownFunctionIdentifiers = [
            "Sunrise",
            "Sunset",
            "CivilDawn",
            "CivilDusk",
            "NauticalDawn",
            "NauticalDusk",
            "AstroDawn",
            "AstroDusk",
            "CustomDawn",
            "CustomDusk",
        ]

        let rawValue: HBJSONValue

        init?(_ rawValue: HBJSONValue) {
            if rawValue.stringValue != nil {
                self.rawValue = rawValue
                return
            }
            guard let fields = rawValue.objectValue,
                  fields.count == 1,
                  let entry = fields.first,
                  !entry.key.isEmpty,
                  entry.value.numberValue != nil else {
                return nil
            }
            self.rawValue = rawValue
        }

        init(clock: String) {
            rawValue = .string(clock)
        }

        init(function: String, argument: HBJSONValue = .integer(0)) {
            rawValue = .object([function: argument])
        }

        var kind: Kind {
            if rawValue.stringValue != nil { return .clock }
            return .function(rawValue.objectValue?.keys.first ?? "")
        }

        var selectorIdentifier: String {
            switch kind {
            case .clock: "clock"
            case .function(let identifier): identifier
            }
        }

        var clockText: String? { rawValue.stringValue }

        var functionArgument: HBJSONValue? {
            guard case .function(let identifier) = kind else { return nil }
            return rawValue.objectValue?[identifier]
        }

        var summary: String {
            switch kind {
            case .clock:
                return clockText ?? "Clock time"
            case .function(let identifier):
                guard let argument = functionArgument,
                      let number = argument.numberValue else {
                    return humanizedConditionIdentifier(identifier)
                }
                let event = humanizedConditionIdentifier(identifier)
                    .lowercased()
                let amount = argument.compactConfigurationJSON
                if Self.minuteOffsetFunctions.contains(identifier) {
                    if number == 0 { return event }
                    let minutes = Self.positiveNumberText(argument)
                    let unit = abs(number) == 1 ? "minute" : "minutes"
                    return number < 0
                        ? "\(minutes) \(unit) before \(event)"
                        : "\(amount) \(unit) after \(event)"
                }
                if Self.solarAltitudeFunctions.contains(identifier) {
                    return "\(event) at \(amount)° solar altitude"
                }
                return "\(event) (\(amount))"
            }
        }

        var validationMessage: String? {
            switch kind {
            case .clock:
                guard let text = clockText,
                      text.range(
                        of: #"^\d?\d(:\d\d)?(:\d\d)?([+-]1)?$"#,
                        options: .regularExpression
                      ) != nil else {
                    return "Use a clock time such as 07:30, optionally followed by +1 or -1."
                }
                return nil
            case .function(let identifier):
                guard !identifier.isEmpty,
                      let number = functionArgument?.numberValue,
                      number.isFinite else {
                    return "A time function needs a name and a numeric argument."
                }
                return nil
            }
        }

        func replacingKind(identifier: String) -> Self {
            guard identifier != selectorIdentifier else { return self }
            if identifier == "clock" {
                return Self(clock: "08:00")
            }
            return Self(
                function: identifier,
                argument: functionArgument ?? .integer(0)
            )
        }

        func replacingClockText(_ text: String) -> Self {
            guard case .clock = kind else { return self }
            return Self(clock: text)
        }

        func replacingFunctionArgument(_ argument: HBJSONValue) -> Self {
            guard case .function(let identifier) = kind else { return self }
            return Self(function: identifier, argument: argument)
        }

        private static let minuteOffsetFunctions = Set([
            "Sunrise", "Sunset", "CivilDawn", "CivilDusk",
            "NauticalDawn", "NauticalDusk", "AstroDawn", "AstroDusk",
        ])

        private static let solarAltitudeFunctions = Set([
            "CustomDawn", "CustomDusk",
        ])

        private static func positiveNumberText(_ value: HBJSONValue) -> String {
            guard let number = value.numberValue else {
                return value.compactConfigurationJSON
            }
            if let integer = Int64(exactly: number), integer != .min {
                return String(abs(integer))
            }
            return String(abs(number))
        }
    }

    let start: Expression
    let end: Expression?

    private let usesArray: Bool

    init?(_ rawValue: HBJSONValue) {
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        guard context.type == "TimeOfDay", let payload = context.payload else {
            return nil
        }
        if let values = payload.arrayValue {
            guard (1 ... 2).contains(values.count),
                  let start = Expression(values[0]) else {
                return nil
            }
            let end = values.count == 2 ? Expression(values[1]) : nil
            guard values.count == 1 || end != nil else { return nil }
            self.start = start
            self.end = end
            usesArray = true
        } else {
            guard let start = Expression(payload) else { return nil }
            self.start = start
            end = nil
            usesArray = false
        }
    }

    init(start: Expression, end: Expression? = nil) {
        self.start = start
        self.end = end
        usesArray = end != nil
    }

    private init(start: Expression, end: Expression?, usesArray: Bool) {
        self.start = start
        self.end = end
        self.usesArray = usesArray
    }

    var rawValue: HBJSONValue {
        let payload: HBJSONValue
        if usesArray || end != nil {
            var expressions = [start.rawValue]
            if let end { expressions.append(end.rawValue) }
            payload = .array(expressions)
        } else {
            payload = start.rawValue
        }
        return .object(["TimeOfDay": payload])
    }

    var summary: String {
        guard let end else { return "At \(start.summary)" }
        return "From \(start.summary) until \(end.summary)"
    }

    var validationMessage: String? {
        if let message = start.validationMessage {
            return "Start: \(message)"
        }
        if let message = end?.validationMessage {
            return "End: \(message)"
        }
        return nil
    }

    func replacingStart(_ expression: Expression) -> Self {
        Self(start: expression, end: end, usesArray: usesArray)
    }

    func replacingEnd(_ expression: Expression?) -> Self {
        Self(
            start: start,
            end: expression,
            usesArray: usesArray
        )
    }

    var suggestedEnd: Expression {
        guard case .function(let identifier) = start.kind else {
            return Expression(clock: "09:00")
        }
        let counterpart = [
            "Sunrise": "Sunset",
            "CivilDawn": "CivilDusk",
            "NauticalDawn": "NauticalDusk",
            "AstroDawn": "AstroDusk",
            "CustomDawn": "CustomDusk",
        ][identifier]
        return Expression(
            function: counterpart ?? identifier,
            argument: start.functionArgument ?? .integer(0)
        )
    }
}

extension TriggerConditionTypeModule {
    static let timeOfDay = TriggerConditionTypeModule(
        identifier: "TimeOfDay",
        wireType: "TimeOfDay",
        creationOption: TriggerConditionCreationOption(
            id: "time-of-day",
            title: "Time of Day",
            systemImage: "clock",
            initialValue: TriggerTimeOfDayCondition(
                start: .init(clock: "08:00"),
                end: .init(clock: "09:00")
            ).rawValue
        ),
        presentation: { context in
            guard let condition = TriggerTimeOfDayCondition(context.rawValue)
            else {
                return rawPresentation(context, title: "Time of Day")
            }
            return TriggerConditionPluginPresentation(
                title: "Time of Day",
                detail: condition.summary
            )
        },
        editingPlan: { context in
            TriggerTimeOfDayCondition(context.rawValue).map {
                .timeOfDay($0)
            } ?? .raw
        },
        validation: { context, _ in
            guard let condition = TriggerTimeOfDayCondition(context.rawValue)
            else {
                return "This Time of Day condition does not have a supported configuration."
            }
            return condition.validationMessage
        },
        makeEditorRows: { context in
            guard TriggerTimeOfDayCondition(
                context.rawValue.wrappedValue
            ) != nil else { return nil }
            return AnyView(
                TriggerTimeOfDayConditionEditorRows(
                    rawValue: context.rawValue
                )
            )
        }
    )
}

struct TriggerTimeOfDayConditionEditorRows: View {
    @Binding var rawValue: HBJSONValue

    private var condition: TriggerTimeOfDayCondition? {
        TriggerTimeOfDayCondition(rawValue)
    }

    var body: some View {
        if let condition {
            Section("Start") {
                TriggerTimeExpressionEditorRows(
                    expression: condition.start
                ) { expression in
                    replace(condition.replacingStart(expression))
                }
            }

            Section("End") {
                Toggle(
                    "Set an end time",
                    isOn: Binding(
                        get: { condition.end != nil },
                        set: { enabled in
                            replace(
                                condition.replacingEnd(
                                    enabled ? condition.suggestedEnd : nil
                                )
                            )
                        }
                    )
                )

                if let end = condition.end {
                    TriggerTimeExpressionEditorRows(expression: end) {
                        expression in
                        replace(condition.replacingEnd(expression))
                    }
                } else {
                    Text(
                        "Without an end time, this condition matches briefly at the selected time."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func replace(_ condition: TriggerTimeOfDayCondition) {
        rawValue = condition.rawValue
    }
}

private struct TriggerTimeExpressionEditorRows: View {
    private enum OffsetDirection: String, CaseIterable, Identifiable {
        case before
        case after

        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    let expression: TriggerTimeOfDayCondition.Expression
    let onChange: (TriggerTimeOfDayCondition.Expression) -> Void

    var body: some View {
        Picker("Time based on", selection: kindBinding) {
            Text("Clock Time").tag("clock")
            ForEach(functionIdentifiers, id: \.self) { identifier in
                Text(humanizedConditionIdentifier(identifier)).tag(identifier)
            }
        }

        switch expression.kind {
        case .clock:
            LabeledContent("Time") {
                TextField("07:30", text: clockBinding)
                    .font(.body.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
#if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
#endif
            }
            Text(
                "Uses the HomeBase server’s local time."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .function(let identifier):
            if isMinuteOffsetFunction(identifier) {
                LabeledContent("Offset (minutes)") {
                    TextField(
                        "0",
                        value: offsetMagnitudeBinding,
                        format: .number
                    )
                    .multilineTextAlignment(.trailing)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                }
                Picker("Relative to event", selection: offsetDirectionBinding) {
                    ForEach(OffsetDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
            } else if identifier == "CustomDawn" || identifier == "CustomDusk" {
                LabeledContent("Sun height (degrees)") {
                    TextField(
                        "0",
                        value: argumentBinding,
                        format: .number
                    )
                    .multilineTextAlignment(.trailing)
#if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
#endif
                }
                Text(
                    "Enter degrees above the horizon; negative values are below it."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(
                    "Current setting",
                    value: expression.summary
                )
                Text(
                    "This custom HomeBase time rule is preserved here and can be changed in Advanced JSON."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var functionIdentifiers: [String] {
        guard case .function(let current) = expression.kind else {
            // Geographic time functions are published dynamically by the
            // server. Until the API exposes that capability list, a newly
            // created clock-time condition must not offer functions that may
            // make the configuration fail to reload.
            return []
        }
        if TriggerTimeOfDayCondition.Expression.knownFunctionIdentifiers
            .contains(current) {
            // A loaded condition using one geographic function proves that
            // the module publishing the complete built-in family is present.
            return TriggerTimeOfDayCondition.Expression
                .knownFunctionIdentifiers
        }
        // Preserve and display custom functions without inventing new ones.
        return [current]
    }

    private var kindBinding: Binding<String> {
        Binding(
            get: { expression.selectorIdentifier },
            set: { onChange(expression.replacingKind(identifier: $0)) }
        )
    }

    private var clockBinding: Binding<String> {
        Binding(
            get: { expression.clockText ?? "" },
            set: { onChange(expression.replacingClockText($0)) }
        )
    }

    private var argumentBinding: Binding<Double> {
        Binding(
            get: { expression.functionArgument?.numberValue ?? 0 },
            set: { number in
                onChange(
                    expression.replacingFunctionArgument(
                        Self.jsonNumber(number)
                    )
                )
            }
        )
    }

    private var offsetMagnitudeBinding: Binding<Double> {
        Binding(
            get: { abs(expression.functionArgument?.numberValue ?? 0) },
            set: { magnitude in
                let sign = offsetDirectionBinding.wrappedValue == .before
                    ? -1.0
                    : 1.0
                onChange(
                    expression.replacingFunctionArgument(
                        Self.jsonNumber(abs(magnitude) * sign)
                    )
                )
            }
        )
    }

    private var offsetDirectionBinding: Binding<OffsetDirection> {
        Binding(
            get: {
                (expression.functionArgument?.numberValue ?? 0) < 0
                    ? .before
                    : .after
            },
            set: { direction in
                let magnitude = abs(
                    expression.functionArgument?.numberValue ?? 0
                )
                let value = direction == .before ? -magnitude : magnitude
                onChange(
                    expression.replacingFunctionArgument(
                        Self.jsonNumber(value)
                    )
                )
            }
        )
    }

    private func isMinuteOffsetFunction(_ identifier: String) -> Bool {
        [
            "Sunrise", "Sunset", "CivilDawn", "CivilDusk",
            "NauticalDawn", "NauticalDusk", "AstroDawn", "AstroDusk",
        ].contains(identifier)
    }

    private static func jsonNumber(_ number: Double) -> HBJSONValue {
        triggerConditionJSONNumber(number)
    }
}
