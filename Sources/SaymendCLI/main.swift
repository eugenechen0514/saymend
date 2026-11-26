import Darwin
import Foundation
import SaymendControl

// `saymend`：連到執行中的 Saymend.app 的薄 client。所有邏輯在 SaymendControl 的 `CLIRunner`；
// 這裡只接 stdout／stderr 與訊號。

/// 每行寫完立刻落地（FileHandle 不經 stdio 緩衝）。鎖住是因為訊號佇列也可能寫（取消逾時的 error 行）。
let outputLock = NSLock()
let output = CLIRunner.Output(
    out: { line in
        outputLock.lock(); defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    },
    err: { line in
        outputLock.lock(); defer { outputLock.unlock() }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    })

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let cliVersion = (Bundle.main.executableURL).flatMap(CLIVersion.detect(executable:))
    ?? CLIVersion.detect(executable: executable)
    ?? "dev"

let runner = CLIRunner(socketPath: ControlProtocol.resolvedSocketPath(),
                       output: output,
                       cliVersion: cliVersion)

// SIGINT／SIGTERM：交給 runner 決定（dictate 進行中＝請 app 取消這一段，exit 5）。
// 先 SIG_IGN 才能改由 dispatch source 接手，否則預設動作會直接殺掉行程、來不及通知 app。
let signalQueue = DispatchQueue(label: "io.saymend.cli.signals")
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler { runner.interrupt() }
    source.resume()
    signalSources.append(source)
}

exit(runner.run(Array(CommandLine.arguments.dropFirst())))
