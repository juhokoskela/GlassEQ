import Foundation

public enum ProfileTextFileReader {
    public static func read(
        _ url: URL,
        maximumBytes: Int = ProfileImportLimits.default.maxUTF8Bytes
    ) throws -> String {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize,
           fileSize > maximumBytes {
            throw ProfileImportError.inputTooLarge(
                byteCount: fileSize,
                maximum: maximumBytes
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        return try readBounded(
            from: handle,
            knownFileSize: values.fileSize,
            maximumBytes: maximumBytes
        )
    }

    public static func readBounded(
        from handle: FileHandle,
        knownFileSize: Int?,
        maximumBytes: Int
    ) throws -> String {
        if let knownFileSize, knownFileSize > maximumBytes {
            throw ProfileImportError.inputTooLarge(
                byteCount: knownFileSize,
                maximum: maximumBytes
            )
        }

        var data = Data()
        data.reserveCapacity(min(max(knownFileSize ?? 0, 0), maximumBytes))
        while true {
            try Task.checkCancellation()
            let remainingCapacity = maximumBytes - data.count
            let readCount = min(64 * 1_024, remainingCapacity + 1)
            guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw ProfileImportError.inputTooLarge(
                    byteCount: data.count,
                    maximum: maximumBytes
                )
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
