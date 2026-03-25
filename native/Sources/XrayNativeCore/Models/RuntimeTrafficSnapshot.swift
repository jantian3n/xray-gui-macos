import Foundation

public struct RuntimeTrafficSnapshot: Codable, Equatable, Sendable {
    public let uploadBytesPerSecond: Int
    public let downloadBytesPerSecond: Int

    public init(uploadBytesPerSecond: Int, downloadBytesPerSecond: Int) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
    }

    public static let zero = RuntimeTrafficSnapshot(
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0
    )
}
