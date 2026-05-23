import Foundation
import ClaudeUsageCore

@main
struct ClaudeUsageDaemon {
    static func main() async {
        Log.info("ClaudeUsageDaemon starting (pid=\(ProcessInfo.processInfo.processIdentifier))")
        Log.info("Cache file: \(SnapshotCache.fileURL.path)")

        let engine = UsageEngine()
        await engine.run()
    }
}
