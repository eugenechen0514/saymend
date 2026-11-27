import Foundation
import Testing
@testable import SaymendCore

@Suite struct RemoteBridgeProtocolTests {
    /// 和參考實作（claude-code-mods 的 test_saymend_remote.py）同一組案例
    @Test func whitelistAcceptsWhatTheModUses() {
        for args in [
            ["status", "--json"], ["events", "--json"], ["events", "--json", "--presence", "loop"],
            ["events", "--presence=loop"], ["cancel"], ["stop", "--json"], ["--version"],
            ["dictate", "--json", "--silence-ms", "1500", "--max-seconds", "120"],
            ["dictate", "--json", "--no-speech-seconds=10", "--polish"], ["dictate", "--max-seconds", "0.5"],
        ] {
            #expect(RemoteBridgeProtocol.validateSaymendArgs(args) == nil, "\(args)")
        }
    }

    @Test func whitelistRejectsEverythingElse() {
        for args in [
            [], ["open", "/etc/passwd"], ["dictate", "--output", "/tmp/x"], ["dictate", "--silence-ms"],
            ["dictate", "--silence-ms", "abc"], ["dictate", "--max-seconds=-1"], ["status", "--polish"],
            ["status", "--presence", "loop"], ["events", "--presence"], ["events", "--presence", "LOOP; rm -rf"],
            ["status", "--max-seconds", "3"],
            // 比參考實作嚴：只收 ASCII 數字、不收 1.、.5
            ["dictate", "--max-seconds", "١٢"], ["dictate", "--max-seconds", "1."], ["dictate", "--max-seconds", ".5"],
            ["dictate", "--help"], ["--help"], ["dictate", "--json", "--polish=yes"],
        ] {
            #expect(RemoteBridgeProtocol.validateSaymendArgs(args) != nil, "\(args)")
        }
    }

    private func parse(_ json: String) -> Result<RemoteBridgeRequest, RemoteBridgeRequest.Rejection> {
        RemoteBridgeRequest.parse(Data(json.utf8))
    }

    @Test func parsesValidRequests() throws {
        #expect(try parse(#"{"v":1,"cmd":"saymend","args":["status","--json"]}"#).get()
                == .saymend(args: ["status", "--json"]))
        #expect(try parse(#"{"v":1,"cmd":"say","text":"你好"}"#).get() == .say(text: "你好", voice: nil))
        #expect(try parse(#"{"v":1,"cmd":"say","text":"x","voice":null}"#).get() == .say(text: "x", voice: nil))
        #expect(try parse(#"{"v":1,"cmd":"say","text":"x","voice":"Samantha (Enhanced)"}"#).get()
                == .say(text: "x", voice: "Samantha (Enhanced)"))
        #expect(try parse(#"{"v":1.0,"cmd":"saymend","args":["cancel"]}"#).get() == .saymend(args: ["cancel"]))
    }

    @Test func rejectsMalformedRequests() {
        for json in [
            #"{"v":99,"cmd":"saymend","args":["status"]}"#, #"{"cmd":"saymend","args":["status"]}"#,
            #"{"v":true,"cmd":"saymend","args":["status"]}"#, #"{"v":1,"cmd":"shell","args":["ls"]}"#,
            #""不是物件""#, "garbage", #"{"v":1,"cmd":"saymend","args":"status"}"#,
            #"{"v":1,"cmd":"saymend","args":["status",1]}"#, #"{"v":1,"cmd":"say"}"#,
            #"{"v":1,"cmd":"say","text":3}"#, #"{"v":1,"cmd":"say","text":"x","voice":"-o/tmp/x.aiff"}"#,
            #"{"v":1,"cmd":"say","text":"x","voice":"a;b"}"#, #"{"v":1,"cmd":"say","text":"x","voice":7}"#,
            #"{"v":1,"cmd":"saymend","args":["dictate","--output","/tmp/x"]}"#,
        ] {
            guard case .failure = parse(json) else { Issue.record("應該拒絕：\(json)"); continue }
        }
    }

    @Test func sayTextIsTruncated() throws {
        let long = String(repeating: "字", count: 9000)
        guard case .say(let text, _) = try parse(#"{"v":1,"cmd":"say","text":"\#(long)"}"#).get() else {
            Issue.record("不是 say"); return
        }
        #expect(text.count == RemoteBridgeProtocol.maxSayCharacters)
    }

    @Test func logSummaryNeverContainsContent() {
        #expect(RemoteBridgeRequest.say(text: "不可以出現在紀錄裡", voice: "Meijia").logSummary == "say（9 字）")
        #expect(RemoteBridgeRequest.saymend(args: ["dictate", "--json"]).logSummary == "saymend dictate")
    }

    /// 遠端的 Python client 逐行 json.loads：形狀要和參考實作一致
    @Test func framesMatchTheClientFormat() {
        #expect(RemoteBridgeFrame.out("a\n").encoded() == #"{"out":"a\n"}"#)
        #expect(RemoteBridgeFrame.err("saymend: 中文\n").encoded() == #"{"err":"saymend: 中文\n"}"#)
        #expect(RemoteBridgeFrame.exit(3).encoded() == #"{"exit":3}"#)
    }

    @Test func utf8ChunkerKeepsSplitCharactersForTheNextChunk() {
        var c = UTF8Chunker()
        let bytes = Array("你好".utf8)                     // 6 bytes
        #expect(c.feed(Data(bytes[0..<4])) == "你")
        #expect(c.feed(Data(bytes[4...])) == "好")
        #expect(c.feed(Data([0xE4])) == "")
        #expect(c.flush() == "\u{FFFD}")
    }
}

@Suite struct RemoteHostTests {
    @Test func sshConfigHostLetsSSHResolveEverything() {
        let h = RemoteHost(id: "abc", kind: .sshConfig, host: "devbox")
        #expect(h.displayName == "devbox")
        #expect(h.sshArguments(command: ["echo hi"])
                == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ControlMaster=no", "--", "devbox", "echo hi"])
    }

    @Test func manualHostPassesPortAndUserAsOptions() {
        let h = RemoteHost(id: "abc", kind: .manual, host: "10.0.0.5", port: 2222, user: "eve")
        #expect(h.displayName == "eve@10.0.0.5:2222")
        #expect(h.sshArguments(options: ["-N"])
                == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ControlMaster=no", "-N", "-p", "2222", "-l", "eve",
                    "--", "10.0.0.5"])
        #expect(RemoteHost(kind: .manual, host: "box").displayName == "box")
    }

    @Test func validation() {
        #expect(RemoteHost.validate(kind: .manual, host: "box", port: 22, user: "u") == nil)
        #expect(RemoteHost.validate(kind: .manual, host: "", port: nil, user: nil) != nil)
        #expect(RemoteHost.validate(kind: .manual, host: "-oProxyCommand=x", port: nil, user: nil) != nil)
        #expect(RemoteHost.validate(kind: .manual, host: "a b", port: nil, user: nil) != nil)
        #expect(RemoteHost.validate(kind: .manual, host: "u@box", port: nil, user: nil) != nil)
        #expect(RemoteHost.validate(kind: .manual, host: "box", port: 0, user: nil) != nil)
        #expect(RemoteHost.validate(kind: .manual, host: "box", port: 70000, user: nil) != nil)
        #expect(RemoteHost.validate(kind: .manual, host: "box", port: nil, user: "-x") != nil)
        #expect(RemoteHost.validate(kind: .manual, host: "box", port: nil, user: "a b") != nil)
    }

    @Test func roundTripsThroughSettings() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "remote-\(UUID().uuidString)")!,
                                   secrets: InMemorySecretStore())
        #expect(settings.remoteHosts.isEmpty)
        let hosts = [RemoteHost(kind: .sshConfig, host: "devbox", autoConnect: true),
                     RemoteHost(kind: .manual, host: "10.0.0.5", port: 2222, user: "eve")]
        settings.remoteHosts = hosts
        #expect(settings.remoteHosts == hosts)
    }

    @Test func setupLinesUseTheRealRemoteHome() {
        #expect(RemoteClientInstall.setupLines(home: "/home/alice") == [
            "/saymend bin /home/alice/.saymend-remote/bin/saymend",
            "/saymend speaker /home/alice/.saymend-remote/bin/say",
        ])
        #expect(RemoteClientInstall.shellQuote("/home/o'neil") == #"'/home/o'\''neil'"#)
        #expect(!RemoteClientInstall.isUsableHome("relative"))
        #expect(!RemoteClientInstall.isUsableHome("/home/a:b"))
    }

    /// GUI app 的 PATH 很短：補上 Homebrew 與 /usr/local，其餘環境（SSH_AUTH_SOCK 等）原樣保留
    @Test func guiAppEnvironmentExtendsPathButKeepsTheAgent() {
        let env = SSHRunner.environmentForGUIApp(["PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/agent"])
        #expect(env["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(env["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(SSHRunner.environmentForGUIApp(["PATH": "/opt/homebrew/bin:/usr/bin"])["PATH"]
                == "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
    }

    @Test func sshFailuresAreClassified() {
        let denied = SSHFailure.classify(exitCode: 255, stderrLine: "alice@box: Permission denied (publickey).", action: "x")
        #expect(denied.isFatal)
        #expect(denied.message.contains("Permission denied"))
        #expect(SSHFailure.classify(exitCode: 255, stderrLine: "Host key verification failed.", action: "x").isFatal)
        #expect(!SSHFailure.classify(exitCode: 255, stderrLine: "ssh: connect to host box port 22: Connection refused",
                                     action: "x").isFatal)
        #expect(!SSHFailure.classify(exitCode: 255, stderrLine: nil, action: "x").isFatal)
        let noPython = RemoteClientInstall.parseInstall(.init(exitCode: 0, stdout: "SAYMEND_REMOTE_NOPYTHON\n",
                                                              stderr: "", timedOut: false))
        guard case .failed(let f) = noPython else { Issue.record("應該失敗"); return }
        #expect(f.isFatal)
    }
}

@Suite struct SSHConfigReaderTests {
    @Test func tokenizesKeywordsAndValues() {
        #expect(SSHConfigReader.tokenize("Host a b") == ["Host", "a", "b"])
        #expect(SSHConfigReader.tokenize("  Host=a") == ["Host", "a"])
        #expect(SSHConfigReader.tokenize("Host = a") == ["Host", "a"])
        #expect(SSHConfigReader.tokenize(#"Include "My Configs/*.conf""#) == ["Include", "My Configs/*.conf"])
        #expect(SSHConfigReader.tokenize("# Host x").isEmpty)
        #expect(SSHConfigReader.tokenize("Host a # 註解") == ["Host", "a"])
    }

    @Test func listsConcreteAliasesFollowingIncludes() {
        let files: [String: String] = [
            "/h/.ssh/config": """
                Include conf.d/*
                Host devbox staging
                  HostName 10.0.0.1
                Host *.internal !bad
                Match host foo
                  User x
                Include /h/extra/more.conf
                Host devbox
                """,
            "/h/.ssh/conf.d/a": "Host alpha\nHost beta*",
            "/h/.ssh/conf.d/b": "host=gamma",
            "/h/extra/more.conf": "Host delta\nInclude /h/.ssh/config",   // 繞回自己：不能無限遞迴
        ]
        let fs = SSHConfigReader.FileSystem(
            read: { files[$0] },
            glob: { pattern in
                pattern == "/h/.ssh/conf.d/*" ? ["/h/.ssh/conf.d/a", "/h/.ssh/conf.d/b"] : []
            })
        let aliases = SSHConfigReader.aliases(sshDirectory: "/h/.ssh", fileSystem: fs)
        // 萬用字元、否定、Match 都不列；照出現順序、去重；繞回自己的 Include 只讀一次
        #expect(aliases == ["alpha", "gamma", "devbox", "staging", "delta"])
    }

    @Test func parsesSSHGOutput() {
        let e = SSHConfigReader.parseResolved(alias: "devbox", output: "user alice\nhostname 10.0.0.1\nport 2222\nforwardagent no\n")
        #expect(e == SSHConfigEntry(alias: "devbox", hostname: "10.0.0.1", user: "alice", port: 2222))
        #expect(e.subtitle == "alice@10.0.0.1:2222")
        #expect(SSHConfigEntry(alias: "x").subtitle == nil)
    }
}
