import Darwin
import Foundation
import OKVideoCore

enum SpiderHTTPURL {
    static func parse(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), isHTTP(url) {
            return url
        }
        guard let encoded = value.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed
        ),
        let url = URL(string: encoded),
        isHTTP(url) else {
            return nil
        }
        return url
    }

    private static func isHTTP(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

enum SpiderSourceURLCandidates {
    private static let rawGitHubPrefix = "https://raw.githubusercontent.com/"

    static func values(for url: URL) -> [URL] {
        let value = url.absoluteString
        var candidates = [url]
        if let range = value.range(of: rawGitHubPrefix),
           range.lowerBound != value.startIndex,
           let direct = SpiderHTTPURL.parse(String(value[range.lowerBound...])) {
            candidates.append(direct)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }
}

private typealias NativeStringOut = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private typealias NativeRequestCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    NativeStringOut
) -> UnsafeMutablePointer<CChar>?
private typealias NativeModuleCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    NativeStringOut
) -> UnsafeMutablePointer<CChar>?
private typealias NativeLogCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> Void

private final class QuickJSLibrary {
    typealias Create = @convention(c) (
        Int,
        NativeRequestCallback?,
        NativeModuleCallback?,
        NativeLogCallback?,
        UnsafeMutableRawPointer?,
        NativeStringOut
    ) -> OpaquePointer?
    typealias Load = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UInt64,
        NativeStringOut
    ) -> Int32
    typealias Invoke = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UInt64,
        NativeStringOut
    ) -> UnsafeMutablePointer<CChar>?
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    let create: Create
    let load: Load
    let invoke: Invoke
    let destroy: Destroy
    let freeString: FreeString

    private let handle: UnsafeMutableRawPointer

    init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) }
                ?? L10n.string("common.unknown-error", fallback: "Unknown error")
            throw AppError.spider(L10n.string("quickjs.load.failed", fallback: "Unable to load QuickJS: %@", message))
        }
        self.handle = handle
        do {
            create = try Self.symbol("okqjs_create", handle: handle)
            load = try Self.symbol("okqjs_load", handle: handle)
            invoke = try Self.symbol("okqjs_invoke", handle: handle)
            destroy = try Self.symbol("okqjs_destroy", handle: handle)
            freeString = try Self.symbol("okqjs_free_string", handle: handle)
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        dlclose(handle)
    }

    func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { freeString(pointer) }
        return String(cString: pointer)
    }

    private static func symbol<T>(
        _ name: String,
        handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw AppError.spider(L10n.string("quickjs.symbol.missing", fallback: "The QuickJS bridge is missing symbol %@.", name))
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

private final class QuickJSHostBox {
    private static let upstreamCommit = "5fdff00a602dc56e8ba756174daef20edab024f2"

    private let siteKey: String
    private let host: SpiderHost
    private let lock = NSLock()
    private var sourceURL: URL?
    private var moduleCache: [String: String] = [:]

    init(siteKey: String, host: SpiderHost) {
        self.siteKey = siteKey
        self.host = host
    }

    func log(_ message: String) {
        host.log(siteKey: siteKey, message: message)
    }

    func setSourceURL(_ sourceURL: URL?) {
        lock.lock()
        self.sourceURL = sourceURL
        lock.unlock()
    }

    func request(_ json: String) throws -> String {
        let request = try decodeRequest(json)
        let response = try send(request)
        var object: [String: Any] = [
            "code": response.statusCode,
            "headers": response.headers.dictionary
        ]
        if let text = String(data: response.body, encoding: .utf8) {
            object["content"] = text
        } else {
            object["content"] = ""
            object["base64"] = response.body.base64EncodedString()
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw AppError.spider(L10n.string("quickjs.response.encode.failed", fallback: "Unable to encode the Spider network response."))
        }
        return value
    }

    func module(named moduleName: String) throws -> String {
        lock.lock()
        if let cached = moduleCache[moduleName] {
            lock.unlock()
            return cached
        }
        let rootSourceURL = sourceURL
        lock.unlock()

        let candidates = try moduleCandidates(
            named: moduleName,
            rootSourceURL: rootSourceURL
        )
        var lastError: Error?
        for url in candidates {
            do {
                let response = try send(
                    SpiderNetworkRequest(url: url)
                )
                guard (200..<300).contains(response.statusCode) else {
                    throw AppError.spider(
                        L10n.string("quickjs.module.http-status", fallback: "Module %1$@ returned HTTP %2$lld.", moduleName, response.statusCode)
                    )
                }
                guard response.body.count <= 5 * 1_024 * 1_024 else {
                    throw AppError.spider(L10n.string("quickjs.module.too-large", fallback: "The Spider module exceeds 5 MiB."))
                }
                guard let source = String(data: response.body, encoding: .utf8) else {
                    throw AppError.spider(L10n.string("quickjs.module.not-utf8", fallback: "The Spider module is not UTF-8: %@", moduleName))
                }
                lock.lock()
                moduleCache[moduleName] = source
                lock.unlock()
                return source
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppError.spider(L10n.string("quickjs.module.load.failed", fallback: "Unable to load Spider module: %@", moduleName))
    }

    private func send(_ request: SpiderNetworkRequest) throws -> SpiderNetworkResponse {
        var lastError: Error?
        for url in SpiderSourceURLCandidates.values(for: request.url) {
            do {
                var candidate = request
                candidate.url = url
                return try sendOnce(candidate)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppError.spider(L10n.string("quickjs.network.failed", fallback: "The Spider network request failed."))
    }

    private func sendOnce(
        _ request: SpiderNetworkRequest
    ) throws -> SpiderNetworkResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedSpiderResponse()
        Task.detached {
            do {
                result.set(.success(try await self.host.request(request)))
            } catch {
                result.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 22) == .success else {
            throw AppError.spider(L10n.string("quickjs.network.timeout", fallback: "The Spider network bridge timed out."))
        }
        return try result.get().get()
    }

    private func moduleCandidates(
        named moduleName: String,
        rootSourceURL: URL?
    ) throws -> [URL] {
        if moduleName.hasPrefix("assets://") {
            let relativePath = String(moduleName.dropFirst("assets://".count))
            guard !relativePath.contains(".."),
                  relativePath.hasPrefix("js/lib/") else {
                throw AppError.spider(L10n.string("quickjs.resource.denied", fallback: "Access to Spider resource %@ is denied.", moduleName))
            }
            let upstream = "https://raw.githubusercontent.com/FongMi/TV/"
                + Self.upstreamCommit
                + "/quickjs/src/main/assets/"
                + relativePath
            var values: [URL] = []
            if let proxyPrefix = sourceProxyPrefix(rootSourceURL),
               let proxied = SpiderHTTPURL.parse(proxyPrefix + upstream) {
                values.append(proxied)
            }
            if let direct = SpiderHTTPURL.parse(upstream) {
                values.append(direct)
            }
            return values
        }
        guard let url = SpiderHTTPURL.parse(moduleName) else {
            throw AppError.spider(L10n.string("quickjs.module.scheme.invalid", fallback: "Spider modules must use HTTP/HTTPS: %@", moduleName))
        }
        return [url]
    }

    private func sourceProxyPrefix(_ sourceURL: URL?) -> String? {
        guard let value = sourceURL?.absoluteString,
              let range = value.range(of: "https://raw.githubusercontent.com/"),
              range.lowerBound != value.startIndex else {
            return nil
        }
        return String(value[..<range.lowerBound])
    }

    private func decodeRequest(_ json: String) throws -> SpiderNetworkRequest {
        guard let data = json.data(using: .utf8) else {
            throw AppError.spider(L10n.string("quickjs.request.not-utf8", fallback: "The Spider network request is not UTF-8."))
        }
        let value = try JSONSerialization.jsonObject(with: data)
        let rawURL: String
        var method: HTTPMethod = .get
        var headers: [String: String] = [:]
        var body: Data?

        if let string = value as? String {
            rawURL = string
        } else if let object = value as? [String: Any],
                  let url = object["url"] as? String {
            rawURL = url
            if let rawMethod = object["method"] as? String,
               let parsedMethod = HTTPMethod(rawValue: rawMethod.uppercased()) {
                method = parsedMethod
            }
            if let rawHeaders = object["headers"] as? [String: Any] {
                headers = rawHeaders.compactMapValues { $0 as? String }
            }
            if let rawBody = object["body"] as? String {
                body = Data(rawBody.utf8)
            } else if let rawBase64 = object["bodyBase64"] as? String {
                body = Data(base64Encoded: rawBase64)
            } else if let dataObject = object["data"],
                      JSONSerialization.isValidJSONObject(dataObject) {
                body = try JSONSerialization.data(
                    withJSONObject: dataObject,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            }
        } else {
            throw AppError.spider(L10n.string("quickjs.request.invalid", fallback: "Spider request parameters must be a URL string or object."))
        }

        guard let url = SpiderHTTPURL.parse(rawURL) else {
            throw AppError.spider(L10n.string("quickjs.request.scheme.invalid", fallback: "The Spider network bridge only allows HTTP/HTTPS."))
        }
        return SpiderNetworkRequest(
            url: url,
            method: method,
            headers: HTTPHeaders(headers),
            body: body
        )
    }
}

private final class LockedSpiderResponse {
    private let lock = NSLock()
    private var value: Result<SpiderNetworkResponse, Error>?

    func set(_ value: Result<SpiderNetworkResponse, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() throws -> Result<SpiderNetworkResponse, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let value else {
            throw AppError.spider(L10n.string("quickjs.network.no-result", fallback: "The Spider network bridge returned no result."))
        }
        return value
    }
}

private let quickJSRequestCallback: NativeRequestCallback = {
    opaque,
    rawJSON,
    errorOut in
    guard let opaque, let rawJSON else {
        errorOut?.pointee = mallocCString(L10n.string("quickjs.callback.request-missing", fallback: "Spider network callback parameters are missing."))
        return nil
    }
    let box = Unmanaged<QuickJSHostBox>.fromOpaque(opaque).takeUnretainedValue()
    do {
        return mallocCString(try box.request(String(cString: rawJSON)))
    } catch {
        errorOut?.pointee = mallocCString(error.localizedDescription)
        return nil
    }
}

private let quickJSModuleCallback: NativeModuleCallback = {
    opaque,
    rawModuleName,
    errorOut in
    guard let opaque, let rawModuleName else {
        errorOut?.pointee = mallocCString(L10n.string("quickjs.callback.module-missing", fallback: "Spider module callback parameters are missing."))
        return nil
    }
    let box = Unmanaged<QuickJSHostBox>.fromOpaque(opaque).takeUnretainedValue()
    do {
        return mallocCString(
            try box.module(named: String(cString: rawModuleName))
        )
    } catch {
        errorOut?.pointee = mallocCString(error.localizedDescription)
        return nil
    }
}

private let quickJSLogCallback: NativeLogCallback = { opaque, rawMessage in
    guard let opaque, let rawMessage else { return }
    let box = Unmanaged<QuickJSHostBox>.fromOpaque(opaque).takeUnretainedValue()
    box.log(String(cString: rawMessage))
}

private func mallocCString(_ value: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(value.utf8CString)
    guard let raw = malloc(bytes.count) else { return nil }
    let pointer = raw.assumingMemoryBound(to: CChar.self)
    bytes.withUnsafeBufferPointer { buffer in
        if let baseAddress = buffer.baseAddress {
            pointer.initialize(from: baseAddress, count: buffer.count)
        }
    }
    return pointer
}

final actor QuickJSSpiderRuntime: SpiderRuntime {
    nonisolated let siteKey: String
    nonisolated let limits: SpiderRuntimeLimits

    private let library: QuickJSLibrary
    private let hostBox: QuickJSHostBox
    private var runtime: OpaquePointer?

    init(
        siteKey: String,
        limits: SpiderRuntimeLimits,
        host: SpiderHost,
        libraryURL: URL
    ) throws {
        self.siteKey = siteKey
        self.limits = limits
        library = try QuickJSLibrary(url: libraryURL)
        hostBox = QuickJSHostBox(siteKey: siteKey, host: host)
    }

    deinit {
        if let runtime {
            library.destroy(runtime)
        }
    }

    func load(script: String, sourceURL: URL?) async throws {
        if runtime != nil {
            await destroy()
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        hostBox.setSourceURL(sourceURL)
        let hostOpaque = Unmanaged.passUnretained(hostBox).toOpaque()
        guard let created = library.create(
            limits.maximumMemoryBytes,
            quickJSRequestCallback,
            quickJSModuleCallback,
            quickJSLogCallback,
            hostOpaque,
            &errorPointer
        ) else {
            throw AppError.spider(
                library.takeString(errorPointer)
                    ?? L10n.string("quickjs.runtime.create.failed", fallback: "Unable to create the QuickJS Runtime.")
            )
        }
        runtime = created

        let timeout = UInt64(limits.executionTimeout * 1_000)
        let result = script.withCString { scriptPointer in
            (sourceURL?.absoluteString ?? "<spider>").withCString { sourcePointer in
                library.load(
                    created,
                    scriptPointer,
                    sourcePointer,
                    timeout,
                    &errorPointer
                )
            }
        }
        guard result == 0 else {
            library.destroy(created)
            runtime = nil
            throw AppError.spider(
                library.takeString(errorPointer)
                    ?? L10n.string("quickjs.script.load.failed", fallback: "The QuickJS script failed to load.")
            )
        }
    }

    func invoke(_ invocation: SpiderInvocation) async throws -> JSONValue {
        guard let runtime else {
            throw AppError.spider(L10n.string("quickjs.runtime.script-not-loaded", fallback: "The QuickJS Runtime has not loaded a script."))
        }
        let arguments = try JSONEncoder().encode(invocation.arguments)
        guard let argumentsJSON = String(data: arguments, encoding: .utf8) else {
            throw AppError.spider(L10n.string("quickjs.arguments.encode.failed", fallback: "Unable to encode Spider invocation arguments."))
        }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let resultPointer = invocation.method.rawValue.withCString { methodPointer in
            argumentsJSON.withCString { argumentsPointer in
                library.invoke(
                    runtime,
                    methodPointer,
                    argumentsPointer,
                    UInt64(limits.executionTimeout * 1_000),
                    &errorPointer
                )
            }
        }
        guard let resultText = library.takeString(resultPointer) else {
            throw AppError.spider(
                library.takeString(errorPointer)
                    ?? L10n.string("quickjs.invoke.failed", fallback: "The QuickJS method call failed.")
            )
        }
        guard let data = resultText.data(using: .utf8) else {
            throw AppError.spider(L10n.string("quickjs.result.not-utf8", fallback: "The QuickJS result is not UTF-8."))
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AppError.spider(L10n.string("quickjs.result.not-json", fallback: "The QuickJS result is not JSON: %@", error.localizedDescription))
        }
    }

    func destroy() async {
        if let runtime {
            library.destroy(runtime)
            self.runtime = nil
        }
    }
}

struct QuickJSSpiderRuntimeFactory: SpiderRuntimeFactory {
    let libraryURL: URL

    init(bundle: Bundle = .main) throws {
        guard let frameworks = bundle.privateFrameworksURL else {
            throw AppError.spider(L10n.string("quickjs.frameworks.missing", fallback: "The app bundle has no Frameworks folder."))
        }
        let candidate = frameworks.appendingPathComponent("libOKQuickJS.dylib")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw AppError.spider(L10n.string("quickjs.library.missing", fallback: "The app bundle is missing libOKQuickJS.dylib."))
        }
        libraryURL = candidate
    }

    func makeRuntime(
        siteKey: String,
        limits: SpiderRuntimeLimits,
        host: SpiderHost
    ) throws -> SpiderRuntime {
        try QuickJSSpiderRuntime(
            siteKey: siteKey,
            limits: limits,
            host: host,
            libraryURL: libraryURL
        )
    }
}
