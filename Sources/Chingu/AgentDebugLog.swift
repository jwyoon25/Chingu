import Foundation

/// Session-scoped NDJSON logger for debug-mode investigation (removed after fix verified).
enum AgentDebugLog {
    private static let path =
        "/Users/jaydenyoon/Developer/ChinguPlan/.cursor/debug-483ae4.log"
    private static let sessionId = "483ae4"

    static func write(
        location: String,
        message: String,
        hypothesisId: String,
        data: [String: Any] = [:],
        runId: String = "pre-fix"
    ) {
        // #region agent log
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if !data.isEmpty { payload["data"] = data }
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8)
        else { return }
        let url = URL(fileURLWithPath: path)
        guard let bytes = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forUpdating: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url)
        }
        // #endregion
    }
}
