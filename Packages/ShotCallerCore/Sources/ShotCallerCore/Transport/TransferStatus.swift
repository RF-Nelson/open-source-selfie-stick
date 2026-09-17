import Foundation

/// Progress of one file moving between the two devices, in either direction.
public struct TransferStatus: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case sending
        case sent
        case receiving
        case saving
        case saved
        case failed(String)
    }

    public var name: String
    public var fraction: Double
    public var phase: Phase

    public init(name: String, fraction: Double, phase: Phase) {
        self.name = name
        self.fraction = fraction
        self.phase = phase
    }

    public var isFinished: Bool {
        switch phase {
        case .sent, .saved, .failed: true
        case .sending, .receiving, .saving: false
        }
    }

    public var isVideo: Bool {
        ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }
}
