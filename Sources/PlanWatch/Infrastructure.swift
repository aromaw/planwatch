import Foundation
import Security
import PlanWatchCore

enum Keychain {
    static let service = "app.planwatch.credentials"
    static func read(_ key: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: key,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else { throw AppError("无法读取钥匙串，请检查系统授权") }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, for key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: key]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError("无法删除钥匙串凭证") }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError("无法保存凭证到钥匙串") }
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Storage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlanWatch", isDirectory: true)
    }
    static func load<T: Decodable>(_ type: T.Type, file: String) throws -> T? {
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func save<T: Encodable>(_ value: T, file: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(file)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Collector {
    static func fetch(_ request: FetchRequest) async -> Snapshot {
        await Task.detached(priority: .utility) {
            do {
                let executable = Bundle.main.resourceURL?.appendingPathComponent("planwatch-collector")
                guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw AppError("采集组件缺失，请使用打包后的 PlanWatch.app")
                }
                let process = Process()
                process.executableURL = executable
                let input = Pipe(), output = Pipe()
                process.standardInput = input; process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let timeout = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
                defer { timeout.cancel() }
                try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AppError("额度查询超时或采集组件退出，请重试") }
                return try JSONDecoder().decode(Snapshot.self, from: data)
            } catch {
                let message = (error as? AppError)?.message ?? "无法完成额度查询，请重试"
                return Snapshot(provider: request.provider, windows: [], error: message)
            }
        }.value
    }
}
