import Foundation

/// A temporary presentation order. The caller commits one move on release;
/// cancellation never mutates the saved catalog.
public struct CatalogDragOrder: Equatable, Sendable {
    public let draggedID: String
    public private(set) var deviceIDs: [String]
    private let originalIDs: [String]
    private let pinnedIDs: Set<String>
    private let allowedIDs: Set<String>

    public init?(deviceIDs: [String], pinnedIDs: Set<String>, draggedID: String, allowedIDs: Set<String>? = nil) {
        let keys = Set(deviceIDs)
        guard keys.count == deviceIDs.count, !keys.contains(""), keys.contains(draggedID),
            pinnedIDs.isSubset(of: keys),
            deviceIDs.prefix(pinnedIDs.count).allSatisfy({ pinnedIDs.contains($0) })
        else { return nil }
        self.draggedID = draggedID
        self.deviceIDs = deviceIDs
        originalIDs = deviceIDs
        self.pinnedIDs = pinnedIDs
        let group = Set(deviceIDs.filter { pinnedIDs.contains($0) == pinnedIDs.contains(draggedID) })
        let allowed = allowedIDs ?? group
        guard allowed.contains(draggedID), allowed.isSubset(of: group) else { return nil }
        let indices = deviceIDs.indices.filter { allowed.contains(deviceIDs[$0]) }
        guard indices.last! - indices.first! + 1 == indices.count else { return nil }
        self.allowedIDs = allowed
    }

    public mutating func move(to proposedIndex: Int) {
        let first = deviceIDs.firstIndex { allowedIDs.contains($0) }!
        let last = deviceIDs.lastIndex { allowedIDs.contains($0) }!
        let destination = min(last, max(first, proposedIndex))
        guard let current = deviceIDs.firstIndex(of: draggedID), current != destination else { return }
        deviceIDs.remove(at: current)
        deviceIDs.insert(draggedID, at: destination)
    }

    public var destinationBefore: String? {
        guard let index = deviceIDs.firstIndex(of: draggedID), index + 1 < deviceIDs.count else { return nil }
        let next = deviceIDs[index + 1]
        return allowedIDs.contains(next) ? next : nil
    }

    public func isCompatible(deviceIDs: [String], pinnedIDs: Set<String>) -> Bool {
        originalIDs == deviceIDs && self.pinnedIDs == pinnedIDs
    }
}
