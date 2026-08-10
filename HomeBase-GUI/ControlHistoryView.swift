//
//  ControlHistoryView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

struct ControlHistoryView: View {
    @StateObject private var model: ControlHistoryModel

    init(
        control: String,
        displayName: String,
        client: HomeBaseWebSocketClient
    ) {
        _model = StateObject(
            wrappedValue: ControlHistoryModel(
                control: control,
                displayName: displayName,
                client: client
            )
        )
    }

    var body: some View {
        List {
            Section {
                if model.entries.isEmpty {
                    emptyContent
                } else {
                    ForEach(model.entries) { item in
                        ControlHistoryEntryRow(entry: item.entry)
                    }
                }

                paginationContent
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    Text(model.control)
                        .font(.caption.monospaced())
                }
                .textCase(nil)
            }
        }
        .navigationTitle("History")
        .task {
            await model.loadIfNeeded()
        }
        .refreshable {
            await model.reload()
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch model.initialState {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView("Loading history…")
                Spacer()
            }
            .foregroundStyle(.secondary)

        case .loaded:
            Text("No history is available for this control.")
                .foregroundStyle(.secondary)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "History could not be loaded",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Try Again") {
                    Task {
                        await model.reload()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var paginationContent: some View {
        if !model.entries.isEmpty {
            if model.isLoadingNextPage {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .accessibilityLabel("Loading more history")
            } else if let paginationError = model.paginationError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(paginationError)
                        .font(.caption)
                        .foregroundStyle(.red)

                    Button("Try Again") {
                        Task {
                            await model.loadNextPage()
                        }
                    }
                }
            } else if model.hasNextPage {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .accessibilityLabel("Load more history")
                .task(id: model.nextCursor) {
                    await model.loadNextPage()
                }
            }
        }
    }
}

private struct ControlHistoryEntryRow: View {
    let entry: HBControlHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.displayValue)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.source)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(entry.value.historyRawJSONString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(
                    entry.timestamp.formatted(
                        date: .abbreviated,
                        time: .standard
                    )
                )

                if let valueDescriptor = entry.valueDescriptor {
                    Text(valueDescriptor)
                } else if let precision = entry.precision {
                    Text("precision: \(precision)")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
private final class ControlHistoryModel: ObservableObject {
    enum InitialState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let entry: HBControlHistoryEntry
    }

    private enum HistoryError: LocalizedError {
        case repeatedCursor

        var errorDescription: String? {
            "The server repeated a history cursor instead of advancing it."
        }
    }

    let control: String
    let displayName: String

    @Published private(set) var initialState: InitialState = .idle
    @Published private(set) var entries: [Item] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var paginationError: String?

    private static let pageSize = 50
    private let client: HomeBaseWebSocketClient

    init(
        control: String,
        displayName: String,
        client: HomeBaseWebSocketClient
    ) {
        self.control = control
        self.displayName = displayName
        self.client = client
    }

    var hasNextPage: Bool {
        nextCursor != nil
    }

    func loadIfNeeded() async {
        guard initialState == .idle else { return }
        await loadFirstPage()
    }

    func reload() async {
        guard initialState != .loading, !isLoadingNextPage else { return }
        entries = []
        nextCursor = nil
        paginationError = nil
        await loadFirstPage()
    }

    func loadNextPage() async {
        guard initialState == .loaded,
              !isLoadingNextPage,
              let cursor = nextCursor else { return }

        isLoadingNextPage = true
        paginationError = nil
        do {
            let result = try await loadPage(cursor: cursor)
            guard result.nextCursor != cursor else {
                throw HistoryError.repeatedCursor
            }
            entries.append(contentsOf: result.entries.map(Item.init(entry:)))
            nextCursor = result.nextCursor
        } catch is CancellationError {
            // A disappearing lazy row cancels its task. The same cursor can be
            // requested again when the row reappears.
        } catch {
            paginationError = error.localizedDescription
        }
        isLoadingNextPage = false
    }

    private func loadFirstPage() async {
        initialState = .loading
        do {
            let result = try await loadPage(cursor: nil)
            entries = result.entries.map(Item.init(entry:))
            nextCursor = result.nextCursor
            initialState = .loaded
        } catch is CancellationError {
            initialState = .idle
        } catch {
            initialState = .failed(error.localizedDescription)
        }
    }

    private func loadPage(cursor: String?) async throws
        -> HBControlHistoryResult
    {
        try await client.reactivate()
        return try await client.controlHistory(
            for: control,
            limit: Self.pageSize,
            cursor: cursor
        )
    }
}

private extension HBJSONValue {
    var historyRawJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
