import Foundation
import zlib

/// Samsung Keyboard receives a remote image as a ZIP holding the image plus a
/// `clip` entry: a Java-serialized SemImageClipData whose image path names that
/// file. The object below was captured from the phone's own image copy; only
/// the timestamp and the file name change.
enum KeyboardClipArchive {
    private static let objectPrefix = Data(base64Encoded: "rO0ABXNyADtjb20uc2Ftc3VuZy5hbmRyb2lkLmNvbnRlbnQuY2xpcGJvYXJkLmRhdGEuU2VtSW1hZ2VDbGlwRGF0YQAAAAAAAAABAgAFWgATbUluaXRCYXNlVmFsdWVDaGVja0wAEW1Db250ZW50VXJpU3RyaW5ndAASTGphdmEvbGFuZy9TdHJpbmc7TAAObUV4dHJhRGF0YVBhdGhxAH4AAUwACm1JbWFnZVBhdGhxAH4AAUwADm1Jbml0QmFzZVZhbHVlcQB+AAF4cgA2Y29tLnNhbXN1bmcuYW5kcm9pZC5jb250ZW50LmNsaXBib2FyZC5kYXRhLlNlbUNsaXBEYXRhAAAAAAAAAAECAA1KAAptQ2FsbGVyVWlkWgAJbUlzUENDbGlwWgAMbUlzUHJvdGVjdGVkWgANbUlzUmVtb3RlQ2xpcEkADG1SZW1vdGVTdGF0ZUoACm1UaW1lc3RhbXBJAAVtVHlwZUwAB21DbGlwSWRxAH4AAUwACG1LZXlMaXN0dAAVTGphdmEvdXRpbC9BcnJheUxpc3Q7TAAGbUxhYmVsdAAYTGphdmEvbGFuZy9DaGFyU2VxdWVuY2U7TAAKbU1pbWVUeXBlc3EAfgADTAAIbU9iakxpc3RxAH4AA0wADW1SZW1vdGVDbGlwSWRxAH4AAXhwAAAAAAAAJ9MAAQAAAAAAAAABoWQT408AAAACdAARMTcxNDU0NTM1NDYyNzQwNzFwdAAAcHBwAHEAfgAHcQB+AAc=")!
    private static let timestampOffset = 0x20a
    /// TC_REFERENCE to the path string, reused as mInitBaseValue.
    private static let objectSuffix = Data([0x71, 0x00, 0x7e, 0x00, 0x08])

    static func clipObject(fileName: String, date: Date = Date()) -> Data {
        var object = objectPrefix
        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        object.replaceSubrange(timestampOffset..<timestampOffset + 8, with: withUnsafeBytes(of: millis.bigEndian) { Data($0) })
        let path = Data(("/data/user/0/com.samsung.android.honeyboard/clipboard/remote_send/" + fileName).utf8)
        object += Data([0x74]) + withUnsafeBytes(of: UInt16(path.count).bigEndian) { Data($0) } + path + objectSuffix
        return object
    }

    static func make(image: Data, fileName: String) -> Data {
        zip([(fileName, image), ("clip", clipObject(fileName: fileName))])
    }

    /// Minimal stored (uncompressed) ZIP; Android's ZipInputStream reads it directly.
    static func zip(_ entries: [(String, Data)]) -> Data {
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var body = Data(), directory = Data()
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
            let commonFields: [Data] = [le16(20), le16(0), le16(0), le16(0), le16(0x21), le32(crc), le32(UInt32(data.count)), le32(UInt32(data.count)), le16(nameBytes.count), le16(0)]
            var common = Data()
            for field in commonFields { common.append(field) }
            let directoryFields: [Data] = [le32(0x02014b50), le16(20), common, le16(0), le16(0), le16(0), le32(0), le32(UInt32(body.count)), nameBytes]
            for field in directoryFields { directory.append(field) }
            body.append(le32(0x04034b50)); body.append(common)
            body.append(nameBytes); body.append(data)
        }
        let footer: [Data] = [le32(0x06054b50), le16(0), le16(0), le16(entries.count), le16(entries.count), le32(UInt32(directory.count)), le32(UInt32(body.count)), le16(0)]
        var archive = body
        archive.append(directory)
        for field in footer { archive.append(field) }
        return archive
    }
}
