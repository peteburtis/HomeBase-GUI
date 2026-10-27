#if os(macOS)
import HomeBaseProtocol

enum MacHomeContainer: Hashable {
    case allDevices
    case room(String)
    case group(String)
    case hiddenRoot
    case hiddenRoom(String)
    case hiddenGroup(String)
    case hiddenAllDevices
}

/// Resolves identifiers against the latest, already-presented topology.
@MainActor
struct MacHomeContent {
    let title: String
    let rooms: [HBTopologyRoomDescriptor]
    let deviceItems: [TopologyDeviceListItem]
    let groups: [HBTopologyGroupDescriptor]
    let controlDeviceIdentifier: String?
    let hiddenDestination: MacHomeContainer?
    let hiddenCount: Int
    let emptyDevicesMessage: String

    init?(container: MacHomeContainer, topology: HBTopologyListResult) {
        let placement = TopologyGroupPlacement(topology: topology)
        switch container {
        case .allDevices, .hiddenAllDevices:
            let items = placement.allDeviceItems
            let hidden = container == .hiddenAllDevices
            self.init(
                title: hidden ? "Hidden" : "All Devices",
                deviceItems: items.filter { $0.isHidden == hidden },
                hiddenDestination: hidden ? nil : .hiddenAllDevices,
                hiddenCount: hidden ? 0 : items.filter(\.isHidden).count,
                emptyDevicesMessage: hidden ? "No hidden devices."
                    : items.isEmpty ? "No devices are available."
                    : "No visible devices are configured here."
            )

        case .room(let identifier), .hiddenRoom(let identifier):
            guard let room = topology.rooms.first(where: { $0.identifier == identifier }) else { return nil }
            let items = placement.deviceItems(in: room)
            let groups = placement.groups(in: room)
            let hidden = container == .hiddenRoom(identifier)
            self.init(
                title: hidden ? "Hidden" : room.displayName,
                deviceItems: items.filter { $0.isHidden == hidden },
                groups: groups.filter { $0.metadata.hasHiddenFlag == hidden },
                hiddenDestination: hidden ? nil : .hiddenRoom(identifier),
                hiddenCount: hidden ? 0 : items.filter(\.isHidden).count
                    + groups.filter { $0.metadata.hasHiddenFlag }.count,
                emptyDevicesMessage: hidden ? "No hidden devices."
                    : items.isEmpty ? "No devices are configured in this room."
                    : "No visible devices are configured here."
            )

        case .group(let identifier), .hiddenGroup(let identifier):
            guard let group = topology.groups.first(where: { $0.identifier == identifier }) else { return nil }
            let items = placement.deviceItems(in: group)
            let hidden = container == .hiddenGroup(identifier)
            self.init(
                title: hidden ? "Hidden" : group.displayName,
                deviceItems: items.filter { $0.isHidden == hidden },
                controlDeviceIdentifier: hidden ? nil : group.controlDeviceIdentifier,
                hiddenDestination: hidden ? nil : .hiddenGroup(identifier),
                hiddenCount: hidden ? 0 : items.filter(\.isHidden).count,
                emptyDevicesMessage: hidden ? "No hidden devices."
                    : items.isEmpty ? "No devices are configured in this group."
                    : "No visible devices are configured here."
            )

        case .hiddenRoot:
            self.init(
                title: "Hidden",
                rooms: topology.rooms.filter { $0.metadata.hasHiddenFlag },
                deviceItems: placement.topLevelDeviceItems.filter(\.isHidden),
                groups: placement.topLevelGroups.filter { $0.metadata.hasHiddenFlag },
                emptyDevicesMessage: "No hidden devices."
            )
        }
    }

    private init(
        title: String,
        rooms: [HBTopologyRoomDescriptor] = [],
        deviceItems: [TopologyDeviceListItem],
        groups: [HBTopologyGroupDescriptor] = [],
        controlDeviceIdentifier: String? = nil,
        hiddenDestination: MacHomeContainer? = nil,
        hiddenCount: Int = 0,
        emptyDevicesMessage: String
    ) {
        self.title = title
        self.rooms = rooms
        self.deviceItems = deviceItems
        self.groups = groups
        self.controlDeviceIdentifier = controlDeviceIdentifier
        self.hiddenDestination = hiddenCount > 0 ? hiddenDestination : nil
        self.hiddenCount = hiddenCount
        self.emptyDevicesMessage = emptyDevicesMessage
    }

    fileprivate var isEmpty: Bool {
        rooms.isEmpty && deviceItems.isEmpty && groups.isEmpty
    }

    fileprivate var defaultDetail: TopologyDetailDestination? {
        controlDeviceIdentifier.map(TopologyDetailDestination.groupControls)
    }

    fileprivate func contains(_ destination: TopologyDetailDestination) -> Bool {
        switch destination {
        case .device(let identifier):
            deviceItems.contains {
                if case .device(let device) = $0 { return device.identifier == identifier }
                return false
            }
        case .groupControls(let identifier), .groupAdvanced(let identifier):
            controlDeviceIdentifier == identifier
        }
    }

    fileprivate func canNavigate(to container: MacHomeContainer) -> Bool {
        if hiddenDestination == container { return true }
        switch container {
        case .room(let identifier):
            return rooms.contains { $0.identifier == identifier }
        case .group(let identifier):
            return groups.contains { $0.identifier == identifier } || deviceItems.contains {
                if case .group(let group) = $0 { return group.identifier == identifier }
                return false
            }
        case .allDevices, .hiddenRoot, .hiddenRoom, .hiddenGroup, .hiddenAllDevices:
            return false
        }
    }
}

/// Keeps the three columns consistent without retaining stale topology descriptors.
@MainActor
struct MacHomeNavigationSelection {
    private(set) var sidebar: MacHomeContainer?
    private(set) var path: [MacHomeContainer] = []
    var detail: TopologyDetailDestination?

    var currentContainer: MacHomeContainer? { path.last ?? sidebar }

    mutating func selectSidebar(_ container: MacHomeContainer?, in topology: HBTopologyListResult) {
        let candidate = container.flatMap { Self.isSidebarContainer($0, in: topology) ? $0 : nil }
        guard sidebar != candidate else {
            reconcile(in: topology)
            return
        }
        sidebar = candidate
        path = []
        detail = currentContent(in: topology)?.defaultDetail
    }

    mutating func setPath(_ proposedPath: [MacHomeContainer], in topology: HBTopologyListResult) {
        let candidate = validPath(proposedPath, in: topology)
        guard path != candidate else {
            reconcile(in: topology)
            return
        }
        path = candidate
        detail = currentContent(in: topology)?.defaultDetail
    }

    mutating func reconcile(in topology: HBTopologyListResult) {
        guard let sidebar, Self.isSidebarContainer(sidebar, in: topology) else {
            self.sidebar = nil
            path = []
            detail = nil
            return
        }
        let previousContainer = currentContainer
        path = validPath(path, in: topology)
        let content = currentContent(in: topology)
        let detailIsValid = detail.map { content?.contains($0) == true } ?? false
        if currentContainer != previousContainer || !detailIsValid {
            detail = content?.defaultDetail
        }
    }

    private func currentContent(in topology: HBTopologyListResult) -> MacHomeContent? {
        currentContainer.flatMap { MacHomeContent(container: $0, topology: topology) }
    }

    private func validPath(_ proposedPath: [MacHomeContainer], in topology: HBTopologyListResult) -> [MacHomeContainer] {
        guard let sidebar, Self.isSidebarContainer(sidebar, in: topology) else { return [] }
        var current = sidebar
        var visited: Set<MacHomeContainer> = [sidebar]
        var result: [MacHomeContainer] = []
        for destination in proposedPath {
            guard !visited.contains(destination),
                  let content = MacHomeContent(container: current, topology: topology),
                  content.canNavigate(to: destination) else { break }
            result.append(destination)
            visited.insert(destination)
            current = destination
        }
        return result
    }

    private static func isSidebarContainer(_ container: MacHomeContainer, in topology: HBTopologyListResult) -> Bool {
        switch container {
        case .allDevices:
            return true
        case .room(let identifier):
            return topology.rooms.contains { $0.identifier == identifier && !$0.metadata.hasHiddenFlag }
        case .group(let identifier):
            let placement = TopologyGroupPlacement(topology: topology)
            return (placement.topLevelGroups + placement.topLevelDeviceGroups).contains {
                $0.identifier == identifier && !$0.metadata.hasHiddenFlag
            }
        case .hiddenRoot:
            return MacHomeContent(container: .hiddenRoot, topology: topology)?.isEmpty == false
        case .hiddenRoom, .hiddenGroup, .hiddenAllDevices:
            return false
        }
    }
}
#endif
