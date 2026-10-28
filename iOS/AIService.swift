import Foundation
import SwiftUI
import Security
import CryptoKit
import WatchMindCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Configuration can be backed up independently of credentials. Credentials never enter UserDefaults or the journal.
@MainActor
final class AISettings: ObservableObject {
    @Published var configuration: AIConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration) {
                UserDefaults.standard.set(data, forKey: "aiReviewConfiguration.v1")
            }
            reloadKeyStatus()
        }
    }
    @Published private(set) var keyAvailable = false
    @Published private(set) var keyError: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: "aiReviewConfiguration.v1"),
           let stored = try? JSONDecoder().decode(AIConfiguration.self, from: data) {
            configuration = stored
        } else { configuration = .preset(.apple) }
        reloadKeyStatus()
    }

    func usePreset(_ provider: AIProvider) { configuration = .preset(provider) }

    /// A custom endpoint receives a separate credential, even if the provider kind is unchanged.
    private var credentialAccount: String? {
        guard let url = try? configuration.chatCompletionsURL() else { return nil }
        let identity = configuration.provider.rawValue + "|" + url.absoluteString
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func saveKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let account = credentialAccount else { throw AIServiceError.invalidCredential }
        try AIKeychain.write(key, account: account)
        reloadKeyStatus()
    }

    func deleteKey() throws {
        guard let account = credentialAccount else { throw AIServiceError.invalidConfiguration }
        try AIKeychain.delete(account: account)
        reloadKeyStatus()
    }

    /// Removes credentials belonging to previous custom endpoints as well as the selected one.
    func deleteAllKeys() throws {
        try AIKeychain.deleteAll()
        reloadKeyStatus()
    }

    func reloadKeyStatus() {
        guard let account = credentialAccount else { keyAvailable = false; keyError = nil; return }
        do { keyAvailable = try AIKeychain.read(account: account) != nil; keyError = nil }
        catch { keyAvailable = false; keyError = "keychain" }
    }

    fileprivate func credential() throws -> String? {
        guard let account = credentialAccount else { return nil }
        return try AIKeychain.read(account: account)
    }
}

private enum AIKeychain {
    private static let service = "WatchMind.AIReview.Credentials.v1"
    private static func query(account: String? = nil) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { value[kSecAttrAccount as String] = account }
        return value
    }
    static func read(account: String) throws -> String? {
        var value = query(account: account)
        value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 4096,
              let result = String(data: data, encoding: .utf8), !result.isEmpty else { throw AIServiceError.keychain }
        return result
    }
    static func write(_ key: String, account: String) throws {
        let value = query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(value as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = value
            attributes.forEach { addition[$0.key] = $0.value }
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw AIServiceError.keychain }
        } else if status != errSecSuccess { throw AIServiceError.keychain }
    }
    static func delete(account: String) throws { try remove(query(account: account)) }
    static func deleteAll() throws { try remove(query()) }
    private static func remove(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIServiceError.keychain }
    }
}

enum AIServiceError: Error {
    case invalidCredential, missingCredential, keychain, invalidConfiguration, localUnavailable
    case network, timeout, unauthorized, rateLimited, server, redirect, oversized, invalidResponse, localGeneration
}

@MainActor
enum AIReviewService {
    static func generate(evidence: AIReviewEvidence, goal: AIReviewGoal, language: AppLanguage, settings: AISettings) async throws -> String {
        try Task.checkCancellation()
        let configuration = settings.configuration // Freeze endpoint and model for this request.
        let messages = try AIReviewPrompt.messages(evidence: evidence, goal: goal, language: language)
        if configuration.provider == .apple {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
                do {
                    let instructions = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
                    let input = messages.filter { $0.role != "system" }.map(\.content).joined(separator: "\n")
                    let session = LanguageModelSession(instructions: instructions)
                    let result = try await session.respond(to: input)
                    try Task.checkCancellation()
                    let content = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty, content.count <= 12000 else { throw AIServiceError.invalidResponse }
                    return content
                } catch is CancellationError { throw CancellationError() }
                catch let error as AIServiceError { throw error }
                catch { throw AIServiceError.localGeneration }
            }
            #endif
            throw AIServiceError.localUnavailable
        }
        let url = try configuration.chatCompletionsURL()
        let key = try settings.credential()
        if [.openAI, .deepSeek].contains(configuration.provider), key == nil { throw AIServiceError.missingCredential }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try OpenAIReviewCodec.request(configuration: configuration, messages: messages)
        let data: Data
        do { data = try await BoundedAIRequest().run(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as AIServiceError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? AIServiceError.timeout : AIServiceError.network
        } catch { throw AIServiceError.network }
        try Task.checkCancellation()
        do { return try OpenAIReviewCodec.response(data) }
        catch { throw AIServiceError.invalidResponse }
    }

    /// Never displays raw provider responses or localizedDescription, which can contain request details.
    static func errorMessage(_ error: Error, language: AppLanguage) -> String {
        let zh = language.resolved == .simplifiedChinese
        if error is CancellationError { return zh ? "已取消，本次未保存分析。" : "Cancelled. This analysis was not saved." }
        if let input = error as? AIReviewError {
            switch input {
            case .invalidWindow: return zh ? "请选择有效的开始和结束时间，范围不超过24小时。" : "Choose a valid start and end within 24 hours."
            case .sourceUnavailable: return zh ? "请选择仍可读取的来源录音。" : "Choose an available source recording."
            case .emptyEvidence: return zh ? "所选范围没有可用原话或健康样本，请调整范围或信号。" : "No words or health samples are available in this range. Adjust the range or signals."
            case .tooMuchEvidence: return zh ? "所选依据过多，请缩短范围或减少信号；不会静默丢弃内容。" : "Too much evidence. Shorten the range or select fewer signals; content is never silently dropped."
            case .invalidEndpoint, .missingModel: return zh ? "请填写有效 HTTPS 接口地址和模型名；HTTP 仅限本机回环地址。" : "Enter a valid HTTPS endpoint and model; HTTP is limited to loopback addresses."
            case .invalidResponse, .responseTooLarge: return zh ? "模型响应不可用或过长，请缩短输入后重试。" : "The model response is unusable or too long. Shorten the input and retry."
            }
        }
        switch error as? AIServiceError {
        case .invalidCredential: return zh ? "请输入有效的 API Key，勿包含空格或换行。" : "Enter a valid API key without spaces or line breaks."
        case .missingCredential: return zh ? "请先在 AI 设置中保存该服务的 API Key。" : "Save an API key for this provider in AI settings first."
        case .keychain: return zh ? "无法访问钥匙串，请解锁设备后重试。密钥未写入普通设置。" : "Keychain is unavailable. Unlock the device and retry. Keys are never saved in ordinary settings."
        case .invalidConfiguration: return zh ? "请检查服务地址和模型名称。" : "Check the endpoint and model name."
        case .localUnavailable: return zh ? "此设备的 Apple 端侧模型尚未就绪或不受支持。请选择其他模型；不会自动上传。" : "Apple’s on-device model is unavailable or not ready. Choose another model; nothing is uploaded automatically."
        case .localGeneration: return zh ? "端侧模型未能完成本次分析。请缩短片段或减少输入后重试；不会自动切换云端。" : "The on-device model could not finish. Shorten the selection or reduce inputs and retry; there is no automatic cloud fallback."
        case .unauthorized: return zh ? "服务拒绝了密钥或模型权限，请检查 AI 设置。" : "The provider rejected the key or model access. Check AI settings."
        case .rateLimited: return zh ? "服务额度不足或请求过于频繁，请检查服务商额度后重试。" : "The provider reports a quota or rate limit. Check your provider’s allowance and retry."
        case .timeout: return zh ? "分析超时，请检查连接或缩短输入。" : "The request timed out. Check the connection or shorten the input."
        case .redirect: return zh ? "服务发生重定向，已停止请求以保护密钥。请填写最终接口地址。" : "The endpoint redirected. The request stopped to protect your key. Enter the final endpoint address."
        case .oversized: return zh ? "服务响应过大，已停止接收。请缩短输入或更换模型。" : "The response was too large and reception stopped. Shorten the input or choose another model."
        case .server: return zh ? "AI 服务暂时无法处理请求，请稍后重试。" : "The AI service cannot process the request right now. Try again later."
        case .invalidResponse: return zh ? "服务返回了无法读取的内容，请检查模型是否支持 Chat Completions。" : "The service returned unreadable content. Check that the model supports Chat Completions."
        case .network: return zh ? "无法连接 AI 服务。请检查网络、接口地址和本地服务是否运行。" : "Cannot reach the AI service. Check the network, endpoint, and whether the local server is running."
        case nil: return zh ? "输入或服务配置无效。请缩短片段，检查时间范围、服务地址及模型名称。" : "The input or configuration is invalid. Shorten the selection and check the time range, endpoint, and model name."
        }
    }
}

/// A per-request, non-caching session. Reject every redirect; never forward a bearer token to a new URL.
/// Streaming delegate callbacks impose a hard response bound even when Content-Length is absent or false.
private final class BoundedAIRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var received = Data()
    private var cancelled = false
    private var finished = false
    private let maximumBytes = 256000

    func run(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 90
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        complete(.failure(CancellationError()))
    }
    private func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; task = nil
        received.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        complete(.failure(AIServiceError.redirect))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); complete(.failure(AIServiceError.invalidResponse)); return
        }
        let failure: AIServiceError?
        switch response.statusCode {
        case 200..<300: failure = response.expectedContentLength > Int64(maximumBytes) ? .oversized : nil
        case 300..<400: failure = .redirect
        case 401, 403: failure = .unauthorized
        case 429: failure = .rateLimited
        default: failure = .server
        }
        if let failure { completionHandler(.cancel); complete(.failure(failure)) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard received.count + data.count <= maximumBytes else {
            lock.unlock(); complete(.failure(AIServiceError.oversized)); return
        }
        received.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)); return }
        lock.lock(); let data = received; lock.unlock()
        complete(.success(data))
    }
}
