import Foundation
import Security

public final class VoicePolishConfig {
    public static let shared = VoicePolishConfig()

    private let configDir: URL
    private let configPath: URL
    private let secrets: SecretStoring

    /// 敏感鍵：存 Keychain，絕不寫明文 config.json。
    static let secretKeys: Set<String> = [
        "ark_api_key", "dashscope_api_key", "bigasr_api_key",
        "bigasr_access_token", "zhipu_api_key",
        "openai_api_key", "groq_api_key", "gemini_api_key",
    ]

    /// 供其他模块读取 config 文件（如热词）
    public var configFileURL: URL { configPath }
    public var configDirectoryURL: URL { configDir }

    /// 默认初始化：macOS 使用 ~/.config/voicepolish/
    private convenience init() {
        #if os(iOS)
        // iOS：使用 App Group 共享容器；钥匙串用共享 access group，让主 App 与键盘扩展互通
        let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.voicepolish.shared")
            ?? FileManager.default.temporaryDirectory
        self.init(configDir: containerURL,
                  secrets: KeychainSecretStore(accessGroup: "NHC4C4K7X7.com.voicepolish.shared"))
        #else
        // macOS：使用用户主目录（钥匙串不设 access group）
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepolish")
        self.init(configDir: dir)
        #endif
    }

    /// 可注入的初始化方法，用于测试或自定义路径
    public init(configDir: URL, secrets: SecretStoring = KeychainSecretStore.shared) {
        self.configDir = configDir
        self.configPath = configDir.appendingPathComponent("config.json")
        self.secrets = secrets
        hardenLocalStoragePermissions()
    }

    public func string(forKey key: String, envKey: String? = nil, persistEnvValue: Bool = false) -> String? {
        if Self.secretKeys.contains(key) {
            if let v = secrets.get(key), !v.isEmpty { return v }
            if let v = configValue(forKey: key), !v.isEmpty { return v }   // 迁移完成前的明文兜底
            if let envKey = envKey,
               let v = ProcessInfo.processInfo.environment[envKey], !v.isEmpty {
                if persistEnvValue { _ = saveSecret(v, forKey: key) }
                return v
            }
            return nil
        }

        if let value = configValue(forKey: key), !value.isEmpty {
            return value
        }

        if let envKey = envKey,
           let value = ProcessInfo.processInfo.environment[envKey],
           !value.isEmpty {
            if persistEnvValue {
                save(value: value, forKey: key)
            }
            return value
        }

        return nil
    }

    public func bool(forKey key: String, defaultValue: Bool = false) -> Bool {
        let value = loadConfig()[key]
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }
        return defaultValue
    }

    public func save(value: String, forKey key: String) {
        if Self.secretKeys.contains(key) { _ = saveSecret(value, forKey: key); return }
        var json = loadConfig()
        json[key] = value
        _ = writeConfig(json)
    }

    public func save(bool value: Bool, forKey key: String) {
        var json = loadConfig()
        json[key] = value
        _ = writeConfig(json)
    }

    public func save(values: [String: Any]) {
        for (key, value) in values where Self.secretKeys.contains(key) {
            if let s = value as? String { _ = saveSecret(s, forKey: key) }
        }
        // 仅落非 secret 改动；绝不把 secret 写进 config（未传入的 secret 明文留给 reconcileSecrets 处理）
        var merged = loadConfig()
        for (key, value) in values where !Self.secretKeys.contains(key) { merged[key] = value }
        _ = writeConfig(merged)
    }

    // MARK: - 敏感凭证（Keychain）

    /// 写敏感凭证到 Keychain，写后读回核对 == value，且确认明文已从 config 删除，三者皆成才返 true。
    /// value 为空 = 删除该 key（用户清空输入框 = 移除该 provider 凭证）；换 key 走非空分支，覆盖即生效。
    @discardableResult
    public func saveSecret(_ value: String, forKey key: String) -> Bool {
        if value.isEmpty {
            guard secrets.set(key, nil) else { return false }
            return stripPlaintextKeys([key])
        }
        guard secrets.set(key, value), secrets.get(key) == value else { return false }
        return stripPlaintextKeys([key])
    }

    /// 删除明文键并回读确认已不在。返回是否确实清除。
    @discardableResult
    private func stripPlaintextKeys(_ keys: [String]) -> Bool {
        var json = loadConfig(); var changed = false
        for k in keys where json[k] != nil { json.removeValue(forKey: k); changed = true }
        guard changed else { return true }
        guard writeConfig(json) else { return false }
        let after = loadConfig()
        return keys.allSatisfy { after[$0] == nil }
    }

    /// 启动早期调用一次，每次启动都做。残留明文 secret 收敛进 Keychain，fail-closed：
    /// Keychain 空 → 写入 + 读回核对 + 删明文；Keychain == 明文 → 删明文；
    /// Keychain ≠ 明文（冲突）→ 不覆盖 Keychain，并删除已失效的明文副本。
    public func reconcileSecrets() {
        migrateLegacyArkKeychainItem()
        let json = loadConfig()
        for key in Self.secretKeys {
            guard let plain = json[key] as? String, !plain.isEmpty else { continue }
            if let existing = secrets.get(key), !existing.isEmpty {
                let removed = stripPlaintextKeys([key])
                if existing != plain {
                    NSLog(removed
                        ? "[secret] %@: removed stale plaintext; keychain remains authoritative"
                        : "[secret] %@: failed to remove stale plaintext; keychain remains authoritative",
                        key)
                }
            } else if secrets.set(key, plain), secrets.get(key) == plain {
                _ = stripPlaintextKeys([key])
            }
        }
    }

    /// 旧版遗留 Keychain item（service 名直接是 "ark_api_key"）迁移：
    /// 仅当 config 无明文 ark 且新位置也为空时才搬（避免遮蔽更新的明文）。
    private func migrateLegacyArkKeychainItem() {
        if (loadConfig()["ark_api_key"] as? String)?.isEmpty == false { return }
        if let v = secrets.get("ark_api_key"), !v.isEmpty { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ark_api_key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return }
        _ = secrets.set("ark_api_key", key)
    }

    private func configValue(forKey key: String) -> String? {
        loadConfig()[key] as? String
    }

    @discardableResult
    private func writeConfig(_ json: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            #if os(macOS)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
            #endif
            let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try data.write(to: configPath, options: .atomic)
            #if os(macOS)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
            #endif
            return true
        } catch {
            return false
        }
    }

    private func hardenLocalStoragePermissions() {
        #if os(macOS)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configDir.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
        }
        if fileManager.fileExists(atPath: configPath.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
        }
        #endif
    }

    public func loadConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}
