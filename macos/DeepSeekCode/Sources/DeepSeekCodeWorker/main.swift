import Foundation
import DeepSeekCodeCore

@main
struct DeepSeekCodeWorker {
    static func main() async {
        guard CommandLine.arguments.contains("--stdio") else {
            FileHandle.standardError.write(Data("deepseek-worker requires --stdio\n".utf8))
            return
        }
        while let line = readLine(strippingNewline: true) {
            let response: WorkerHelperResponse
            do {
                let request = try WorkerHelperJSON.decoder.decode(WorkerHelperRequest.self, from: Data(line.utf8))
                response = try await WorkerHelperService.execute(request)
            } catch {
                response = WorkerHelperResponse(
                    requestID: UUID().uuidString,
                    ok: false,
                    error: error.localizedDescription
                )
            }
            if let data = try? WorkerHelperJSON.encoder.encode(response) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
                fflush(stdout)
            }
        }
    }
}
