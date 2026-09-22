import Foundation

enum BoundedFile {
    enum ReadError: Error { case tooLarge }

    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        return data
    }
}
