import Foundation

/// Versions, release parsing, request and cache rules, presentation, install guards, and the install steps on a copy of
/// this bundle (skipped outside an .app). No network.
func runUpdaterChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    var skipped = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append("Updater: " + description) }
    }
    func failure(_ body: () throws -> Void) -> UpdateFailure? {
        do { try body(); return nil } catch { return error as? UpdateFailure }
    }
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let suite = "dev.seuput.TokenCat.UpdaterCheck.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return ["Updater: could not create an isolated defaults domain"] }
    defer { defaults.removePersistentDomain(forName: suite) }

    // Versions: numeric parts, "v" prefix, suffix ignored, missing parts are 0.
    func version(_ text: String) -> AppVersion? { AppVersion(text) }
    check(version("v0.9.1")! > version("0.9.0")! && version("0.10.0")! > version("0.9.9")! && version("1.0.0")! > version("0.99")!,
          "numeric version order")
    check(version("0.9.1-beta.2") == version("0.9.1") && version("1.0") == version("1.0.0") && !(version("1.0")! < version("1.0.0")!)
          && version("V2.0")?.description == "2.0", "suffix and missing parts")
    check(["", "v", "abc", "1..2", "1.x", "-1"].allSatisfy { version($0) == nil }, "unreadable versions are rejected")

    // Release JSON: only the fields TokenCat uses; drafts and prereleases are never offered.
    let digest = String(repeating: "AB", count: 32)
    let zipAsset: [String: Any] = ["name": "TokenCat.zip", "size": 5_242_880, "digest": "sha256:" + digest,
                                   "browser_download_url": "https://github.com/SeuPut0705/TokenCat/releases/download/v0.9.1/TokenCat.zip"]
    func json(tag: String = "v0.9.1", draft: Bool = false, prerelease: Bool = false, assets: [[String: Any]]? = nil) -> Data {
        var object: [String: Any] = ["tag_name": tag, "html_url": "https://github.com/SeuPut0705/TokenCat/releases/tag/\(tag)",
                                     "draft": draft, "prerelease": prerelease, "name": "TokenCat \(tag)", "id": 1]
        if let assets { object["assets"] = assets }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
    // `try?` flattens: nil for a withheld release and for an error alike.
    func parse(_ data: Data) -> UpdateRelease? { try? UpdateRelease.parse(data) }
    func withheld(_ data: Data) -> Bool {
        if case .success(nil) = Result(catching: { try UpdateRelease.parse(data) }) { return true }
        return false
    }
    let release = parse(json(assets: [["name": "TokenCat.zip.sha256", "size": 1, "browser_download_url": "https://example.invalid/a"], zipAsset]))
    check(release?.version == "0.9.1" && release?.tag == "v0.9.1"
          && release?.page.absoluteString == "https://github.com/SeuPut0705/TokenCat/releases/tag/v0.9.1"
          && release?.asset?.size == 5_242_880 && release?.asset?.sha256 == digest.lowercased()
          && release?.asset?.url.lastPathComponent == "TokenCat.zip", "a release with TokenCat.zip and its digest")
    let bare = parse(json())
    var noDigest = zipAsset
    noDigest["digest"] = nil
    let undigested = parse(json(assets: [noDigest]))
    var other = zipAsset
    other["digest"] = "sha512:" + digest
    check(bare != nil && bare?.asset == nil && failure { _ = try bare?.installable() } == .noAsset
          && parse(json(assets: [["name": "TokenCat-0.9.1.zip", "size": 1, "browser_download_url": "https://example.invalid/b"]]))?.asset == nil,
          "a release without TokenCat.zip parses but cannot be installed")
    check(undigested?.asset != nil && undigested?.asset?.sha256 == nil && failure { _ = try undigested?.installable() } == .noDigest
          && parse(json(assets: [other]))?.asset?.sha256 == nil, "an asset without a SHA-256 digest cannot be installed")
    check(withheld(json(draft: true, assets: [zipAsset])) && withheld(json(prerelease: true, assets: [zipAsset])) && !withheld(json(assets: [zipAsset])),
          "drafts and prereleases are not offered")
    check(failure { _ = try UpdateRelease.parse(Data("{}".utf8)) } == .invalidResponse
          && failure { _ = try UpdateRelease.parse(json(tag: "latest")) } == .invalidResponse
          && failure { _ = try UpdateRelease.parse(Data("<html>".utf8)) } == .invalidResponse, "unreadable answers are errors")

    // Digests: "sha256:<64 hex>" only; the file check catches a wrong size or a wrong hash.
    check(UpdateRelease.sha256(fromDigest: "sha256:" + digest) == digest.lowercased() && UpdateRelease.sha256(fromDigest: nil) == nil
          && UpdateRelease.sha256(fromDigest: "sha256:abc") == nil && UpdateRelease.sha256(fromDigest: "sha256:" + String(repeating: "g", count: 64)) == nil
          && UpdateRelease.sha256(fromDigest: digest) == nil, "digest parsing")
    let sample = FileManager.default.temporaryDirectory.appendingPathComponent("TokenCat-digest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: sample) }
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let written = (try? Data("abc".utf8).write(to: sample)) != nil
    check(written && (try? UpdateInstaller.digest(of: sample)) == abc && failure { try UpdateInstaller.verify(sample, size: 3, sha256: abc) } == nil
          && failure { try UpdateInstaller.verify(sample, size: 4, sha256: abc) } == .sizeMismatch
          && failure { try UpdateInstaller.verify(sample, size: 3, sha256: String(repeating: "0", count: 64)) } == .digestMismatch,
          "SHA-256 of sample bytes, size and hash mismatches")

    // HTTP answers: ETag, 304, 404 and the rate-limit headers.
    func answer(_ status: Int, _ headers: [String: String] = [:], _ body: Data = Data()) -> UpdateResponse {
        let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        return UpdateResponse.interpret(status: status, header: { lowered[$0.lowercased()] }, body: body, now: at)
    }
    let latest = release ?? UpdateRelease(version: "0.9.1", tag: "v0.9.1", page: UpdateClient.releases)
    check(answer(200, ["etag": "W/\"abc\""], json(assets: [zipAsset])) == .release(latest, etag: "W/\"abc\"")
          && answer(200, [:], json(draft: true)) == .none && answer(200, [:], Data("nope".utf8)) == .failed(.invalidResponse)
          && answer(304) == .notModified && answer(404) == .none, "200, 304 and 404 answers")
    check(answer(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000600"]) == .rateLimited(until: at.addingTimeInterval(600))
          && answer(429, ["Retry-After": "120"]) == .rateLimited(until: at.addingTimeInterval(120))
          && answer(403, ["Retry-After": "30", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000600"]) == .rateLimited(until: at.addingTimeInterval(30))
          && answer(403) == .failed(.server(403)) && answer(403, ["X-RateLimit-Remaining": "12"]) == .failed(.server(403))
          && answer(500) == .failed(.server(500)), "403/429 pause on Retry-After or an exhausted limit; other errors back off")
    // GitHub's clock 6 h behind this Mac: the reset is 10 minutes after the response's Date, not 6 h 10 min from now.
    let served = UpdateResponse.httpDate("Fri, 15 Jan 2027 02:00:00 GMT")
    check(served == at.addingTimeInterval(-21_600)
          && answer(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1799979000", "Date": "Fri, 15 Jan 2027 02:00:00 GMT"])
            == .rateLimited(until: at.addingTimeInterval(600))
          && answer(429, ["Retry-After": "inf"]) == .failed(.server(429)) && answer(429, ["Retry-After": "nan"]) == .failed(.server(429))
          && answer(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "inf"]) == .failed(.server(403)),
          "the reset is measured on GitHub's clock; non-finite values do not pause")

    // Schedule: backoff 1, 2, 4, 8 then 15 min; a rate limit pauses everything until it resets (at least a minute).
    check((0...6).map(UpdateThrottle.backoff) == [900, 60, 120, 240, 480, 900, 900], "backoff schedule")
    var throttle = UpdateThrottle()
    let delays = (0..<3).map { _ in throttle.record(.failed(.network), now: at) }
    let waits = !throttle.allowsAutomatic(at: at.addingTimeInterval(239), lastAttempt: at) && throttle.allowsAutomatic(at: at.addingTimeInterval(240), lastAttempt: at)
    // A wake 60 s into the 4-minute backoff waits the remaining 3 minutes, not 15 s.
    let wakeWait = throttle.backoffRemaining(at: at.addingTimeInterval(60), lastAttempt: at)
    let regular = throttle.record(.notModified, now: at)
    check(delays == [60, 120, 240] && waits && wakeWait == 180 && regular == 900 && throttle.failures == 0
          && throttle.allowsAutomatic(at: at, lastAttempt: at) && throttle.backoffRemaining(at: at, lastAttempt: at) == 0,
          "errors back off and automatic triggers, wake included, wait it out; an answer resets it")
    let paused = throttle.record(.rateLimited(until: at.addingTimeInterval(600)), now: at)
    check(paused == 600 && !throttle.allows(at: at.addingTimeInterval(599)) && throttle.allows(at: at.addingTimeInterval(600))
          && !throttle.allowsAutomatic(at: at.addingTimeInterval(300), lastAttempt: at), "a rate limit pauses until its reset")
    check(throttle.record(.rateLimited(until: at.addingTimeInterval(-30)), now: at) == 60 && throttle.pausedUntil == at.addingTimeInterval(60),
          "a reset already past still pauses a minute")
    check(throttle.record(.rateLimited(until: at.addingTimeInterval(86_400 * 30)), now: at) == 3_600 && throttle.pausedUntil == at.addingTimeInterval(3_600),
          "a reset far away (a wrong clock) pauses at most an hour")

    // Requests: fixed headers (a fixed language, so macOS does not add the person's), If-None-Match only with a cached
    // release; a 304 reuses it. The download sends the same identity.
    let client = UpdateClient(version: "0.9.0")
    let plain = client.request(etag: nil)
    let conditional = client.request(etag: "W/\"abc\"")
    var download = URLRequest(url: UpdateClient.releases)
    UpdateClient.identify(&download, version: "0.9.0")
    check(plain.url == UpdateClient.latest && plain.httpMethod == "GET" && plain.value(forHTTPHeaderField: "If-None-Match") == nil
          && plain.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json"
          && plain.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28"
          && plain.value(forHTTPHeaderField: "User-Agent") == "TokenCat/0.9.0" && plain.value(forHTTPHeaderField: "Accept-Language") == "en"
          && plain.httpBody == nil
          && Set(plain.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) == ["accept", "x-github-api-version", "user-agent", "accept-language"]
          && download.allHTTPHeaderFields == ["User-Agent": "TokenCat/0.9.0", "Accept-Language": "en"]
          && conditional.value(forHTTPHeaderField: "If-None-Match") == "W/\"abc\"", "request headers")
    let configuration = UpdateClient.configuration()
    check(configuration.urlCache == nil && configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies
          && configuration.urlCredentialStorage == nil && configuration.timeoutIntervalForRequest == 15,
          "ephemeral session without cache, cookies or credentials, 15 s timeout")
    let store = UpdateStore(defaults: defaults)
    let noCache = store.etagToSend == nil
    let first = store.resolve(.release(latest, etag: "W/\"abc\""))
    let sendsETag = store.etagToSend == "W/\"abc\""
    let reused = store.resolve(.notModified)
    let limited = store.resolve(.rateLimited(until: at))
    check(noCache && first == .success(latest) && sendsETag && reused == .success(latest) && limited == .failure(.rateLimited(until: at))
          && store.release == latest, "a 304 reuses the cached release; a rate limit keeps the cache")
    let gone = store.resolve(.none)
    let orphan = store.resolve(.notModified)
    check(gone == .success(nil) && store.release == nil && store.etag == nil && store.etagToSend == nil && orphan == .failure(.invalidResponse),
          "404 clears the cache; a 304 without a cached release is an error")

    // Presentation and ✕ per version.
    let newer = UpdateRelease(version: "0.9.2", tag: "v0.9.2", page: UpdateClient.releases)
    var state = UpdateState(check: .done, checkedAt: at.addingTimeInterval(-180), available: latest)
    check(state.notice(dismissed: nil) == UpdateNotice(kind: .available, text: "새 버전 0.9.1", help: "내려받아 설치한 뒤 TokenCat을 다시 엽니다", version: "0.9.1")
          && state.notice(dismissed: "0.9.1") == nil, "the new-version notice hides for the dismissed version")
    state.available = newer
    check(state.notice(dismissed: "0.9.1")?.text == "새 버전 0.9.2", "a newer version shows again after a dismissal")
    state.available = latest
    state.install = .downloading(0.456)
    check(state.notice(dismissed: "0.9.1")?.text == "업데이트 내려받는 중 45%" && state.status(now: at).title == "업데이트 내려받는 중 45%"
          && state.quickMenuTitle == nil && !state.canCheck && !state.canInstall, "download progress")
    state.install = .installing
    check(state.notice(dismissed: nil)?.text == "설치 중…" && state.notice(dismissed: nil)?.kind == .installing, "installing")
    state.install = .failed(.network)
    let failed = state.notice(dismissed: nil)
    state.install = .failed(.translocated)
    let blocked = state.notice(dismissed: nil)
    // A failure that trying again cannot fix is not offered the install again; the quick menu opens the release page.
    let blockedInstall = [UpdateFailure.translocated, .notWritable, .noDigest, .relaunchFailed].contains { failure in
        var copy = state
        copy.install = .failed(failure)
        return copy.canInstall || copy.quickMenuTitle != "업데이트 0.9.1 릴리스 페이지…" || copy.quickMenuCommand != .openReleasePage
    }
    state.install = .failed(.network)
    check(failed?.text == "업데이트 실패" && failed?.detail == "네트워크 오류" && failed?.kind == .failed(retryable: true)
          && blocked?.kind == .failed(retryable: false) && blocked?.detail == "임시 위치에서 실행 중"
          && UpdateState(install: .failed(.translocated)).status(now: at) == ("업데이트 실패", "임시 위치에서 실행 중", true)
          && !blockedInstall && state.canInstall && state.quickMenuTitle == "업데이트 0.9.1 설치…" && state.quickMenuCommand == .install,
          "failures: short reason, retry only when it can help; a blocked install offers the release page instead")
    // A newer release than the failed one can be installed again; the same release keeps the failure.
    var blockedState = state
    blockedState.install = .failed(.notWritable)
    blockedState.receive(available: latest)
    let sameKept = !blockedState.canInstall && blockedState.installFailure == .notWritable
    blockedState.receive(available: newer)
    var downloading = state
    downloading.install = .downloading(0.1)
    downloading.receive(available: newer)
    check(sameKept && blockedState.canInstall && blockedState.installFailure == nil && blockedState.quickMenuTitle == "업데이트 0.9.2 설치…"
          && downloading.install == .downloading(0.1), "a newer release clears a blocking failure; a download in progress is untouched")
    state.install = .none
    check(state.status(now: at) == ("새 버전 0.9.1", "3분 전 확인", false) && state.quickMenuTitle == "업데이트 0.9.1 설치…",
          "Settings line and quick menu item with a new version")
    state.available = nil
    check(state.status(now: at) == ("최신 버전입니다 · 3분 전 확인", nil, false)
          && UpdateState(checkedAt: at.addingTimeInterval(-20)).status(now: at).title == "최신 버전입니다 · 방금 확인"
          && UpdateState().status(now: at).title == "아직 확인하지 않았습니다"
          && UpdateState(check: .checking).status(now: at).title == "확인 중…" && !UpdateState(check: .checking).canCheck
          && UpdateState(check: .failed(.network)).status(now: at) == ("확인하지 못했습니다", UpdateFailure.network.text, true)
          && UpdateState(disabled: "앱 번들(.app)로 실행할 때만 업데이트를 확인합니다").status(now: at).title == "앱 번들(.app)로 실행할 때만 업데이트를 확인합니다"
          && state.quickMenuTitle == nil, "Settings status lines")
    check(UpdateState(updatedTo: "0.9.1").notice(dismissed: nil)?.text == "0.9.1로 업데이트했습니다"
          && UpdateState.updated("0.9.10") == "0.9.10으로 업데이트했습니다" && UpdateState.updated("1.3") == "1.3으로 업데이트했습니다"
          && UpdateState.updated("0.9.7") == "0.9.7로 업데이트했습니다", "the one-time note after an update")
    check(UpdateFailure.rateLimited(until: Calendar.current.date(bySettingHour: 14, minute: 5, second: 0, of: at)!).text.contains("14:05")
          && [UpdateFailure.network, .noAsset, .noDigest, .digestMismatch, .notWritable, .translocated, .invalidBundle("x")].allSatisfy { !$0.text.isEmpty && !$0.short.isEmpty },
          "failure texts")
    AppLanguage.with(.en) {
        var english = UpdateState(check: .done, checkedAt: at.addingTimeInterval(-180), available: latest)
        let available = english.status(now: at) == ("New version 0.9.1", "Checked 3m ago", false)
            && english.notice(dismissed: nil)?.text == "New version 0.9.1" && english.quickMenuTitle == "Install Update 0.9.1…"
        english.install = .downloading(0.456)
        let progress = english.notice(dismissed: nil)?.text == "Downloading update 45%"
        english.install = .failed(.translocated)
        let blocked = english.notice(dismissed: nil).map { [$0.text, $0.detail ?? ""] } == ["Update failed", "Running from a temporary location"]
            && english.quickMenuTitle == "Update 0.9.1 Release Page…"
        check(available && progress && blocked
              && UpdateState(checkedAt: at.addingTimeInterval(-20)).status(now: at).title == "Up to date · Checked just now"
              && UpdateState(updatedTo: "0.9.10").notice(dismissed: nil)?.text == "Updated to 0.9.10"
              && UpdateFailure.invalidBundle("x").text == "Couldn't verify the new app, so it wasn't installed: x.",
              "English status lines, notices and quick menu items")
    }

    // Install guards, before any download.
    let writable: (String) -> Bool = { _ in true }
    check(UpdateInstaller.blocker(for: URL(fileURLWithPath: "/Applications/TokenCat.app"), isWritable: writable) == nil
          && UpdateInstaller.blocker(for: URL(fileURLWithPath: "/private/var/folders/xy/abc/T/AppTranslocation/0A1B/d/TokenCat.app"), isWritable: writable) == .translocated
          && UpdateInstaller.blocker(for: URL(fileURLWithPath: "/work/.build/release/TokenCat"), isWritable: writable) == .notBundle
          && UpdateInstaller.blocker(for: URL(fileURLWithPath: "/Applications/TokenCat.app"), isWritable: { $0 != "/Applications" }) == .notWritable
          && UpdateInstaller.blocker(for: URL(fileURLWithPath: "/Applications/TokenCat.app"), isWritable: { $0 == "/Applications" }) == .notWritable,
          "install guards: translocated, not an .app, not writable")

    // The controller without the network: disabled copies make no request; discovery and the update note happen once.
    let raw = Updater(bundleURL: URL(fileURLWithPath: "/work/.build/release/TokenCat"), version: "0.9.0", defaults: defaults)
    raw.start(automatic: true)
    raw.checkNow()
    raw.install()
    check(raw.state.disabled != nil && raw.state.check == .idle && raw.state.install == .none, "a raw binary never checks or installs")
    raw.stop()
    store.installedVersion = "0.9.0"
    store.release = newer
    let app = Updater(bundleURL: URL(fileURLWithPath: "/Applications/TokenCat.app"), version: "0.9.0", defaults: defaults)
    var discovered: [String] = []
    app.onDiscovered = { discovered.append($0.version) }
    app.start(automatic: false)
    let restored = app.state.updatedTo == "0.9.0" && store.installedVersion == nil && app.state.available == newer
    app.apply(latest: latest)
    app.apply(latest: latest)
    let once = discovered == ["0.9.1"] && app.state.available == latest
    app.apply(latest: UpdateRelease(version: "0.8.0", tag: "v0.8.0", page: UpdateClient.releases))
    let older = app.state.available == nil
    app.apply(latest: nil)
    check(restored && once && older && app.state.available == nil && app.state.check == .done, "cache at launch, one discovery per version, older ignored")
    app.stop()
    store.installedVersion = "0.8.0"
    store.pausedUntil = Date().addingTimeInterval(30 * 86_400)
    let stale = Updater(bundleURL: URL(fileURLWithPath: "/Applications/TokenCat.app"), version: "0.9.0", defaults: defaults)
    stale.start(automatic: false)
    check(stale.state.updatedTo == nil && store.installedVersion == nil, "a note for another version is dropped")
    check(store.pausedUntil == nil, "a stored pause longer than an hour (a wrong clock) is dropped at launch")
    stale.stop()

    // The swap finished but the old copy could not be deleted (an undeletable folder inside it): installed, not "기존 앱은 그대로".
    let swapRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TokenCat-swap-check-\(UUID().uuidString)", isDirectory: true)
    let oldApp = swapRoot.appendingPathComponent("Applications/TokenCat.app", isDirectory: true)
    let newApp = swapRoot.appendingPathComponent("staging/TokenCat.app", isDirectory: true)
    let locked = oldApp.appendingPathComponent("Contents/locked", isDirectory: true)
    func fakeBundle(_ url: URL, version: String) -> Bool {
        (try? FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)) != nil
            && NSDictionary(dictionary: ["CFBundleShortVersionString": version]).write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
    }
    let swapReady = fakeBundle(oldApp, version: "0.9.0") && fakeBundle(newApp, version: "0.9.1")
        && (try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)) != nil
        && FileManager.default.createFile(atPath: locked.appendingPathComponent("file").path, contents: Data())
        && (try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)) != nil
    let swapped = try? UpdateInstaller.replace(oldApp, with: newApp, version: "0.9.1")
    let swappedVersion = NSDictionary(contentsOf: oldApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    // The old copy is left where the new one was staged; unlock it so the folder can go.
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newApp.appendingPathComponent("Contents/locked").path)
    try? FileManager.default.removeItem(at: swapRoot)
    check(swapReady && swapped == oldApp && swappedVersion == "0.9.1"
          && failure { _ = try UpdateInstaller.replace(swapRoot.appendingPathComponent("missing.app"), with: newApp, version: "0.9.1") } == .replaceFailed,
          "a swap that only failed to delete the old copy counts as installed; any other failure does not")

    // The install steps on a copy of this bundle, zipped the way releases are.
    let bundle = Bundle.main.bundleURL
    if bundle.pathExtension == "app" {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TokenCat-update-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("release/TokenCat.app", isDirectory: true)
        let installed = root.appendingPathComponent("Applications/TokenCat.app", isDirectory: true)
        let zip = root.appendingPathComponent("TokenCat.zip")
        let prepared = UpdateInstaller.run("/usr/bin/ditto", [bundle.path, source.path]) == 0
            && UpdateInstaller.run("/usr/bin/ditto", [bundle.path, installed.path]) == 0
            && UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, zip.path]) == 0
        let size = ((try? fm.attributesOfItem(atPath: zip.path))?[.size] as? NSNumber)?.intValue ?? 0
        let sha = (try? UpdateInstaller.digest(of: zip)) ?? ""
        check(prepared && size > 0 && failure { try UpdateInstaller.verify(zip, size: size, sha256: sha) } == nil
              && failure { try UpdateInstaller.verify(zip, size: size + 1, sha256: sha) } == .sizeMismatch
              && failure { try UpdateInstaller.verify(zip, size: size, sha256: String(repeating: "0", count: 64)) } == .digestMismatch,
              "the release zip verifies by size and SHA-256")
        let staged = try? UpdateInstaller.extract(zip, into: root.appendingPathComponent("staging", isDirectory: true))
        check(staged != nil && failure { try staged.map { try UpdateInstaller.validate($0, version: AppInfo.version) } } == nil
              && failure { try staged.map { try UpdateInstaller.validate($0, version: "99.0.0") } } == .invalidBundle("앱 버전이 릴리스와 다릅니다"),
              "extract yields one TokenCat.app with this identity, version, CPU and a valid signature")
        let tampered = root.appendingPathComponent("tampered/TokenCat.app", isDirectory: true)
        let edited = staged.map { UpdateInstaller.run("/usr/bin/ditto", [$0.path, tampered.path]) == 0 } == true
            && (try? FileHandle(forWritingTo: tampered.appendingPathComponent("Contents/Resources/LICENSE"))).map { handle in
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data("\n".utf8))
                return true
            } == true
        check(edited && failure { try UpdateInstaller.validate(tampered, version: AppInfo.version) } == .invalidBundle("코드 서명을 확인하지 못했습니다"),
              "a modified bundle fails the signature check")
        let doubled = root.appendingPathComponent("doubled", isDirectory: true)
        let twoApps = UpdateInstaller.run("/usr/bin/ditto", [source.path, root.appendingPathComponent("two/TokenCat.app").path]) == 0
            && (try? fm.copyItem(at: source, to: root.appendingPathComponent("two/Other.app"))) != nil
            && UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", root.appendingPathComponent("two").path, root.appendingPathComponent("two.zip").path]) == 0
        check(twoApps && failure { _ = try UpdateInstaller.extract(root.appendingPathComponent("two.zip"), into: doubled) }
                == .invalidBundle("압축 파일에 TokenCat.app 하나만 있어야 합니다"), "an archive with more than TokenCat.app is refused")
        let marker = installed.appendingPathComponent("Contents/old-copy")
        let marked = fm.createFile(atPath: marker.path, contents: Data())
        let replaced = staged.flatMap { try? UpdateInstaller.replace(installed, with: $0, version: AppInfo.version) }
        let version = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        check(marked && replaced != nil && !fm.fileExists(atPath: marker.path) && staged.map { !fm.fileExists(atPath: $0.path) } == true
              && version == AppInfo.version && UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.path]) == 0,
              "replace swaps the bundle in place and the result still verifies")
    } else {
        skipped += 1
    }

    print("Updater checks: \(checks - failures.count) PASS / \(failures.count) FAIL / \(skipped) SKIP")
    return failures
}
