import AppKit
import ImageIO
import CryptoKit
import Darwin

enum ClearError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

enum Attributes {
    static let finderInfo = "com.apple.FinderInfo"
    static let resourceFork = "com.apple.ResourceFork"
    static func read(_ path: String, _ name: String) throws -> Data? {
        let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if n < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard n <= 16 * 1024 * 1024 else { throw ClearError.message("图标属性过大，已跳过") }
        var data = Data(count: n)
        let result = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, n, 0, XATTR_NOFOLLOW) }
        guard result == n else { throw ClearError.message("读取图标属性失败") }
        return data
    }
    static func write(_ path: String, _ name: String, _ data: Data?) throws {
        let rc: Int32
        if let data {
            rc = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        } else {
            rc = removexattr(path, name, XATTR_NOFOLLOW)
            if rc != 0 && errno == ENOATTR { return }
        }
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func custom(_ data: Data?) -> Bool {
        guard let data, data.count >= 10 else { return false }
        return data[8] & 0x04 != 0
    }
}

struct PhotoFingerprint: Codable, Equatable {
    let inode: UInt64
    let size: UInt64
    let modified: Double
    static func get(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ClearError.message("已跳过非普通文件")
        }
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return Self(inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                    size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                    modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
}

struct IconRecord: Codable {
    let path: String
    let originalFinderInfo: Data?
    let originalResourceFork: Data?
    var fingerprint: PhotoFingerprint
    var appliedResourceHash: String?
}

/// Serial-queue-owned store. Journals the original icon attributes before changing them.
/// The photo data fork is only ever opened for reading.
final class IconStore {
    let directory: URL
    let fm = FileManager.default
    let extensions: Set<String> = ["jpg", "jpeg", "jpe", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func recordURL(_ path: String) -> URL { directory.appendingPathComponent(digest(Data(path.utf8)) + ".json") }
    func load(_ path: String) throws -> IconRecord? {
        let url = recordURL(path)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(IconRecord.self, from: Data(contentsOf: url))
    }
    func save(_ record: IconRecord) throws {
        try JSONEncoder().encode(record).write(to: recordURL(record.path), options: .atomic)
    }
    func images(in folder: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey], options: [.skipsHiddenFiles])
            .filter { url in
                guard extensions.contains(url.pathExtension.lowercased()),
                      let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                          .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true else { return false }
                return v.isUbiquitousItem != true || v.ubiquitousItemDownloadingStatus == .current
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    func icon(for url: URL) throws -> NSImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ClearError.message("无法生成图片预览")
        }
        let scale = min(1024.0 / Double(thumbnail.width), 1024.0 / Double(thumbnail.height))
        let w = Double(thumbnail.width) * scale, h = Double(thumbnail.height) * scale
        canvas.interpolationQuality = .high
        canvas.draw(thumbnail, in: CGRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h))
        guard let image = canvas.makeImage() else { throw ClearError.message("预览绘制失败") }
        return NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
    }
    enum Outcome { case applied, current, skipped }
    func apply(_ url: URL, cancelled: () -> Bool = { false }) throws -> Outcome {
        let before = try PhotoFingerprint.get(url)
        var record = try load(url.path)
        let info = try Attributes.read(url.path, Attributes.finderInfo)
        let fork = try Attributes.read(url.path, Attributes.resourceFork)
        if let existing = record {
            // Never overwrite a custom icon changed by another application or a replacement file.
            guard existing.fingerprint.inode == before.inode,
                  let expected = existing.appliedResourceHash,
                  let fork, digest(fork) == expected, Attributes.custom(info) else { return .skipped }
            if existing.fingerprint == before { return .current }
        } else {
            guard !Attributes.custom(info) else { return .skipped }
            record = IconRecord(path: url.path, originalFinderInfo: info, originalResourceFork: fork,
                                fingerprint: before, appliedResourceHash: nil)
        }
        let image = try icon(for: url)
        guard !cancelled(), try PhotoFingerprint.get(url) == before else { return .skipped }
        guard try Attributes.read(url.path, Attributes.resourceFork) == fork,
              try Attributes.read(url.path, Attributes.finderInfo) == info else { return .skipped }
        try save(record!) // Backup must succeed before any attribute write.
        guard NSWorkspace.shared.setIcon(image, forFile: url.path, options: []) else {
            if record!.appliedResourceHash == nil { try? fm.removeItem(at: recordURL(url.path)) }
            throw ClearError.message("Finder 图标写入失败，可能是文件只读")
        }
        guard let result = try Attributes.read(url.path, Attributes.resourceFork),
              Attributes.custom(try Attributes.read(url.path, Attributes.finderInfo)) else {
            throw ClearError.message("图标未能回读验证；已保留恢复记录")
        }
        record!.fingerprint = try PhotoFingerprint.get(url)
        record!.appliedResourceHash = digest(result)
        try save(record!)
        return .applied
    }
    func restore(_ url: URL) throws -> Bool {
        guard let record = try load(url.path) else { return false }
        let now = try PhotoFingerprint.get(url)
        guard now.inode == record.fingerprint.inode,
              let expected = record.appliedResourceHash,
              let resource = try Attributes.read(url.path, Attributes.resourceFork),
              digest(resource) == expected else {
            throw ClearError.message("图标已被其他程序更改，未覆盖；恢复记录仍保留")
        }
        // Retain later Finder label/flag changes while restoring only our custom-icon bit.
        let currentInfo = try Attributes.read(url.path, Attributes.finderInfo)
        guard NSWorkspace.shared.setIcon(nil, forFile: url.path, options: []) else {
            throw ClearError.message("移除高清图标失败")
        }
        try Attributes.write(url.path, Attributes.resourceFork, record.originalResourceFork)
        var restoredInfo = currentInfo ?? Data(repeating: 0, count: 32)
        if restoredInfo.count >= 10 { restoredInfo[8] &= 0xFB }
        if record.originalFinderInfo == nil && restoredInfo.allSatisfy({ $0 == 0 }) {
            try Attributes.write(url.path, Attributes.finderInfo, nil)
        } else {
            try Attributes.write(url.path, Attributes.finderInfo, restoredInfo)
        }
        guard try Attributes.read(url.path, Attributes.resourceFork) == record.originalResourceFork,
              !Attributes.custom(try Attributes.read(url.path, Attributes.finderInfo)) else {
            throw ClearError.message("恢复回读校验失败，备份已保留")
        }
        try fm.removeItem(at: recordURL(url.path))
        return true
    }
    func ownedFiles(in folder: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url in
                guard let record = try? JSONDecoder().decode(IconRecord.self, from: Data(contentsOf: url)),
                      URL(fileURLWithPath: record.path).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
                else { return nil }
                return URL(fileURLWithPath: record.path)
            }
    }
}
