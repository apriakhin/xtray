import Darwin
import Foundation
import LibXray

final class LibXrayRuntime {
    func test(configPath: String) throws {
        _ = try invoke(method: "testXray", environment: nil, payload: [
            "configPath": configPath
        ])
    }

    func run(configPath: String, assetPath: String? = nil, tunFileDescriptor: Int32? = nil) throws {
        var environment: [String: String] = [
            "xray.location.config": (configPath as NSString).deletingLastPathComponent
        ]

        if let assetPath {
            environment["xray.location.asset"] = assetPath
        }

        if let tunFileDescriptor {
            environment["xray.tun.fd"] = String(tunFileDescriptor)
        }

        _ = try invoke(method: "runXray", environment: environment, payload: [
            "configPath": configPath
        ])
    }

    func stop() {
        _ = try? invoke(method: "stopXray", environment: nil, payload: [:])
    }

    @discardableResult
    private func invoke(
        method: String,
        environment: [String: String]?,
        payload: [String: Any]
    ) throws -> [String: Any] {
        var request: [String: Any] = [
            "apiVersion": 1,
            "method": method,
            "payload": payload
        ]

        if let environment {
            request["env"] = environment
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw LibXrayRuntimeError.invalidRequest
        }

        guard let requestPointer = strdup(requestJSON) else {
            throw LibXrayRuntimeError.invalidRequest
        }
        defer { free(requestPointer) }

        guard let responsePointer = CGoInvoke(requestPointer) else {
            throw LibXrayRuntimeError.emptyResponse
        }
        defer { free(responsePointer) }

        let responseJSON = String(cString: responsePointer)
        let responseData = Data(responseJSON.utf8)
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw LibXrayRuntimeError.invalidResponse(responseJSON)
        }

        if response["success"] as? Bool == true {
            return response["data"] as? [String: Any] ?? [:]
        }

        let message = response["error"] as? String ?? "Unknown libXray error."
        throw LibXrayRuntimeError.invocationFailed(message)
    }
}

enum LibXrayRuntimeError: LocalizedError {
    case invalidRequest
    case emptyResponse
    case invalidResponse(String)
    case invocationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Unable to encode libXray request."
        case .emptyResponse:
            "libXray returned an empty response."
        case .invalidResponse(let response):
            "libXray returned an invalid response: \(response)"
        case .invocationFailed(let message):
            message
        }
    }
}
