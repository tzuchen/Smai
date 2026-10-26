// Copyright (c) 2022 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Cocoa
import FSEventStreamHelper
import InputMethodKit

private let kCheckUpdateAutomatically = "CheckUpdateAutomatically"
private let kNextUpdateCheckDateKey = "NextUpdateCheckDate"
private let kUpdateInfoEndpointKey = "UpdateInfoEndpoint"
private let kUpdateInfoSiteKey = "UpdateInfoSite"
private let kNextCheckInterval: TimeInterval = 86400.0
private let kTimeoutInterval: TimeInterval = 60.0

struct VersionUpdateReport {
    var siteUrl: URL?
    var packageDownloadUrl: URL?
    var packageName: String = ""
    var packageSize: Int = 0
    var currentShortVersion: String = ""
    var currentVersion: String = ""
    var remoteShortVersion: String = ""
    var remoteVersion: String = ""
    var versionDescription: String = ""
}

enum VersionUpdateApiResult {
    case shouldUpdate(report: VersionUpdateReport)
    case noNeedToUpdate
    case ignored
}

enum VersionUpdateApiError: Error, LocalizedError {
    case connectionError(message: String)

    var errorDescription: String? {
        switch self {
        case .connectionError(let message):
            return String(
                format: NSLocalizedString(
                    "There may be no internet connection or the server failed to respond.\n\nError message: %@",
                    comment: ""), message)
        }
    }
}

struct VersionUpdateApi {
    private static let githubApiEndpoint = "https://api.github.com/repos/tzuchen/Smai/releases/latest"

    static func isRemoteVersionNewer(current: String, remote: String) -> Bool {
        let curParts = current.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").compactMap { Int($0) }
        let remParts = remote.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").compactMap { Int($0) }
        let maxLen = max(curParts.count, remParts.count)
        for i in 0..<maxLen {
            let c = i < curParts.count ? curParts[i] : 0
            let r = i < remParts.count ? remParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    static func check(
        forced: Bool, callback: @escaping (Result<VersionUpdateApiResult, Error>) -> Void
    ) -> URLSessionTask? {
        AFMDevLogger.shared.log("VERSION UPDATE API: checking endpoint: \(githubApiEndpoint), currentVersion=\(SmaiVersion.current), forced=\(forced)")
        guard let url = URL(string: githubApiEndpoint) else {
            return nil
        }

        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: kTimeoutInterval)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Smai-Input-Method/\(SmaiVersion.current)", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AFMDevLogger.shared.log("VERSION UPDATE API: response received, status=\(statusCode), error=\(error?.localizedDescription ?? "none")")
            if let error = error {
                DispatchQueue.main.async {
                    forced
                        ? callback(
                            .failure(
                                VersionUpdateApiError.connectionError(
                                    message: error.localizedDescription)))
                        : callback(.success(.ignored))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                }
                return
            }

            // 404 means no releases published yet on repository -> up to date
            if httpResponse.statusCode == 404 {
                DispatchQueue.main.async {
                    forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                }
                return
            }

            guard (200..<300).contains(httpResponse.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async {
                    forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                }
                return
            }

            let rawTagName = json["tag_name"] as? String ?? ""
            let remoteShortVersion = rawTagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let releaseUrlString = json["html_url"] as? String ?? "https://github.com/tzuchen/Smai/releases"
            let siteUrl = URL(string: releaseUrlString)
            let body = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let currentShortVersion = SmaiVersion.current
            let isNewer = isRemoteVersionNewer(current: currentShortVersion, remote: remoteShortVersion)

            if !isNewer {
                DispatchQueue.main.async {
                    forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                }
                return
            }

            var packageDownloadUrl: URL? = nil
            var packageName: String = ""
            var packageSize: Int = 0
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".pkg"),
                       let urlStr = asset["browser_download_url"] as? String,
                       let url = URL(string: urlStr) {
                        packageDownloadUrl = url
                        packageName = name
                        packageSize = asset["size"] as? Int ?? 0
                        break
                    }
                }
            }

            var report = VersionUpdateReport(siteUrl: siteUrl)
            report.packageDownloadUrl = packageDownloadUrl
            report.packageName = packageName
            report.packageSize = packageSize
            report.currentShortVersion = currentShortVersion
            report.currentVersion = SmaiVersion.build
            report.remoteShortVersion = remoteShortVersion
            report.remoteVersion = rawTagName
            report.versionDescription = body.isEmpty ? "" : "\n\n更新說明：\n" + body

            DispatchQueue.main.async {
                callback(.success(.shouldUpdate(report: report)))
            }
        }
        task.resume()
        return task
    }
}

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate, NonModalAlertWindowControllerDelegate {

    @IBOutlet weak var window: NSWindow?
    private var preferencesWindowController: PreferencesWindowController?
    private var checkTask: URLSessionTask?
    private var updateNextStepURL: URL?
    private var latestReport: VersionUpdateReport?
    private var updateDownloadTask: URLSessionDownloadTask?
    private var fsStreamHelper: FSEventStreamHelper?
    private var serviceProvider = ServiceProvider()
    private var serviceProviderHelper = ServiceProviderInputHelper()

    func updateUserPhrases() {
        LanguageModelManager.loadUserPhrases(
            enableForPlainBopomofo: Preferences.enableUserPhrasesInPlainBopomofo)
        LanguageModelManager.loadUserPhraseReplacement()

        fsStreamHelper?.delegate = nil
        fsStreamHelper?.stop()
        fsStreamHelper = FSEventStreamHelper(
            path: LanguageModelManager.dataFolderPath, queue: DispatchQueue(label: "User Phrases"))
        fsStreamHelper?.delegate = self
        _ = fsStreamHelper?.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LanguageModelManager.setupDataModelValueConverter()
        updateUserPhrases()

        if UserDefaults.standard.object(forKey: kCheckUpdateAutomatically) == nil {
            UserDefaults.standard.set(true, forKey: kCheckUpdateAutomatically)
            UserDefaults.standard.synchronize()
        }

        if UserDefaults.standard.object(forKey: kBeepUponInputErrorKey) == nil {
            UserDefaults.standard.set(true, forKey: kBeepUponInputErrorKey)
            UserDefaults.standard.synchronize()
        }

        NotificationCenter.default.addObserver(
            forName: .userPhraseLocationDidChange, object: nil, queue: OperationQueue.main
        ) { notification in
            self.updateUserPhrases()
        }

        serviceProvider.delegate = (serviceProviderHelper as! any ServiceProviderDelegate)
        NSApp.servicesProvider = serviceProvider

        enableBopomofoFontAnnotationSupportMenuItemIfRelevantFontsInstalled()

        checkForUpdate()
    }

    @MainActor
    @objc func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showAndActivate()
    }

    @objc(checkForUpdate)
    func checkForUpdate() {
        checkForUpdate(forced: false)
    }

    @objc(sharedInstance)
    static private(set) var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    @objc(checkForUpdate:)
    func checkForUpdate(_ sender: Any?) {
        checkForUpdate(forced: true)
    }

    @objc(checkForUpdateForced:)
    func checkForUpdate(forced: Bool) {
        AFMDevLogger.shared.log("APPDELEGATE CHECK FOR UPDATE: forced=\(forced), checkTaskBusy=\(checkTask != nil)")
        if checkTask != nil {
            // busy
            return
        }

        // time for update?
        if !forced {
            if UserDefaults.standard.bool(forKey: kCheckUpdateAutomatically) == false {
                return
            }
            let now = Date()
            let date = UserDefaults.standard.object(forKey: kNextUpdateCheckDateKey) as? Date ?? now
            if now.compare(date) == .orderedAscending {
                return
            }
        }

        let nextUpdateDate = Date(timeInterval: kNextCheckInterval, since: Date())
        UserDefaults.standard.set(nextUpdateDate, forKey: kNextUpdateCheckDateKey)

        checkTask = VersionUpdateApi.check(forced: forced) { result in
            defer {
                self.checkTask = nil
            }
            switch result {
            case .success(let apiResult):
                switch apiResult {
                case .shouldUpdate(let report):
                    self.updateNextStepURL = report.siteUrl
                    self.latestReport = report
                    var contentParts: [String] = []
                    contentParts.append("💡 發現新版本：\(report.remoteShortVersion)")
                    contentParts.append("📌 目前版本：\(report.currentShortVersion) (Build \(report.currentVersion))")
                    if !report.versionDescription.isEmpty {
                        contentParts.append(report.versionDescription)
                    }
                    if report.packageDownloadUrl != nil {
                        contentParts.append("\n👉 點擊下方「一鍵自動更新」，系統將自動下載並完成就地安裝（需輸入密碼或 Touch ID 授權）。")
                    } else {
                        contentParts.append("\n點擊下方「前往下載」即可前往 GitHub 下載安裝套件。")
                    }
                    let content = contentParts.joined(separator: "\n")
                    NonModalAlertWindowController.shared.dismissOnConfirm = (report.packageDownloadUrl == nil)
                    NonModalAlertWindowController.shared.show(
                        title: "發現思脈注音新版本",
                        content: content,
                        confirmButtonTitle: report.packageDownloadUrl != nil ? "一鍵自動更新" : "前往下載",
                        cancelButtonTitle: "稍後再說",
                        cancelAsDefault: false, delegate: self)
                case .noNeedToUpdate:
                    NonModalAlertWindowController.shared.dismissOnConfirm = true
                    NonModalAlertWindowController.shared.show(
                        title: "版本檢查完成",
                        content: "思脈注音已是最新版本 (\(SmaiVersion.displayString))。",
                        confirmButtonTitle: "好",
                        cancelButtonTitle: nil, cancelAsDefault: false, delegate: self)
                case .ignored:
                    break
                }
            case .failure(let error):
                switch error {
                case VersionUpdateApiError.connectionError(let message):
                    let title = "檢查新版失敗"
                    let content = "無法連接至伺服器或網路連線中斷。\n\n錯誤訊息：\(message)"
                    let buttonTitle = "關閉"
                    NonModalAlertWindowController.shared.dismissOnConfirm = true
                    NonModalAlertWindowController.shared.show(
                        title: title, content: content, confirmButtonTitle: buttonTitle,
                        cancelButtonTitle: nil, cancelAsDefault: false, delegate: nil)
                default:
                    break
                }
            }
        }
    }

    func nonModalAlertWindowControllerDidConfirm(_ controller: NonModalAlertWindowController) {
        guard let report = latestReport, let pkgUrl = report.packageDownloadUrl else {
            if let updateNextStepURL = updateNextStepURL {
                NSWorkspace.shared.open(updateNextStepURL)
            }
            updateNextStepURL = nil
            latestReport = nil
            controller.window?.orderOut(self)
            return
        }

        AFMDevLogger.shared.log("AUTO UPDATE: starting download from \(pkgUrl)")
        controller.setWorkingStatus(
            title: "正在下載思脈注音 \(report.remoteShortVersion)...",
            message: "正在自 GitHub 下載最新安裝套件 (\(report.packageName.isEmpty ? "Smai.pkg" : report.packageName))...\n\n下載完成後系統將呼叫安裝器，請於彈出視窗以 Touch ID 或密碼授權完成就地更新。"
        )

        let session = URLSession(configuration: .default)
        let downloadTask = session.downloadTask(with: pkgUrl) { [weak self] tempLocalUrl, response, error in
            guard let self = self else { return }

            if let error = error {
                AFMDevLogger.shared.log("AUTO UPDATE: download failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    controller.dismissOnConfirm = true
                    controller.show(
                        title: "下載更新失敗",
                        content: "無法下載安裝套件：\(error.localizedDescription)\n\n是否改由瀏覽器開啟 GitHub 網頁手動下載？",
                        confirmButtonTitle: "開啟網頁",
                        cancelButtonTitle: "關閉",
                        cancelAsDefault: false,
                        delegate: self
                    )
                    self.latestReport = nil
                }
                return
            }

            guard let tempLocalUrl = tempLocalUrl else {
                DispatchQueue.main.async {
                    controller.dismissOnConfirm = true
                    controller.show(
                        title: "下載更新失敗",
                        content: "下載之檔案為空或無效。\n\n是否改由瀏覽器開啟 GitHub 網頁手動下載？",
                        confirmButtonTitle: "開啟網頁",
                        cancelButtonTitle: "關閉",
                        cancelAsDefault: false,
                        delegate: self
                    )
                    self.latestReport = nil
                }
                return
            }

            let tempTargetDir = NSTemporaryDirectory()
            let finalPkgPath = (tempTargetDir as NSString).appendingPathComponent("Smai-AutoUpdate.pkg")
            try? FileManager.default.removeItem(atPath: finalPkgPath)
            do {
                try FileManager.default.moveItem(at: tempLocalUrl, to: URL(fileURLWithPath: finalPkgPath))
            } catch {
                AFMDevLogger.shared.log("AUTO UPDATE: move file failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    controller.dismissOnConfirm = true
                    controller.show(
                        title: "安裝套件存檔失敗",
                        content: "無法儲存下載的套件檔案：\(error.localizedDescription)",
                        confirmButtonTitle: "前往 GitHub",
                        cancelButtonTitle: "關閉",
                        cancelAsDefault: false,
                        delegate: self
                    )
                    self.latestReport = nil
                }
                return
            }

            DispatchQueue.main.async {
                controller.setWorkingStatus(
                    title: "正在安裝思脈注音 \(report.remoteShortVersion)...",
                    message: "套件已成功下載。\n請在系統即將彈出的認證視窗中，使用 Touch ID 或密碼確認授權。\n\n安裝完成後輸入法將自動重新啟動生效。"
                )
            }

            // 3. Execute installer with administrator privileges in background
            DispatchQueue.global(qos: .userInitiated).async {
                let scriptSource = """
                do shell script "/usr/sbin/installer -pkg '\(finalPkgPath)' -target /" with administrator privileges
                """
                var errorDict: NSDictionary?
                let appleScript = NSAppleScript(source: scriptSource)
                let output = appleScript?.executeAndReturnError(&errorDict)
                AFMDevLogger.shared.log("AUTO UPDATE: installer script executed, result=\(output?.stringValue ?? "nil"), error=\(String(describing: errorDict))")

                DispatchQueue.main.async {
                    if let errorDict = errorDict {
                        let errNum = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
                        let errMsg = errorDict[NSAppleScript.errorMessage] as? String ?? "未知錯誤"
                        controller.dismissOnConfirm = true
                        if errNum == -128 {
                            // User cancelled authorization
                            controller.show(
                                title: "安裝授權已取消",
                                content: "您取消了 Touch ID 或密碼授權。\n思脈注音尚未安裝新版，隨時可再次檢查更新。",
                                confirmButtonTitle: "前往 GitHub",
                                cancelButtonTitle: "關閉",
                                cancelAsDefault: false,
                                delegate: self
                            )
                        } else {
                            controller.show(
                                title: "自動安裝失敗",
                                content: "安裝器執行失敗 (\(errNum))：\(errMsg)\n\n建議前往 GitHub 下載安裝套件手動安裝。",
                                confirmButtonTitle: "前往 GitHub",
                                cancelButtonTitle: "關閉",
                                cancelAsDefault: false,
                                delegate: self
                            )
                        }
                        self.latestReport = nil
                    } else {
                        // Success! Postinstall script terminates old instance and relaunches new instance.
                        controller.window?.orderOut(self)
                        self.latestReport = nil
                        self.updateNextStepURL = nil
                    }
                }
            }
        }
        self.updateDownloadTask = downloadTask
        downloadTask.resume()
    }

    func nonModalAlertWindowControllerDidCancel(_ controller: NonModalAlertWindowController) {
        updateDownloadTask?.cancel()
        updateDownloadTask = nil
        latestReport = nil
        updateNextStepURL = nil
    }
}

extension AppDelegate: FSEventStreamHelperDelegate {
    func helper(_ helper: FSEventStreamHelper, didReceive events: [FSEventStreamHelper.Event]) {
        DispatchQueue.main.async {
            LanguageModelManager.loadUserPhrases(
                enableForPlainBopomofo: Preferences.enableUserPhrasesInPlainBopomofo)
            LanguageModelManager.loadUserPhraseReplacement()
        }
    }
}

extension AppDelegate {
    private func open(userFileAt path: String) {
        func checkIfUserFilesExist() -> Bool {
            if !LanguageModelManager.checkIfUserLanguageModelFilesExist() {
                let content = String(
                    format: NSLocalizedString(
                        "Please check the permission of the path at \"%@\".", comment: ""),
                    LanguageModelManager.dataFolderPath)
                NonModalAlertWindowController.shared.show(
                    title: NSLocalizedString("Failed to Create the User Phrase File", comment: ""),
                    content: content, confirmButtonTitle: NSLocalizedString("OK", comment: ""),
                    cancelButtonTitle: nil, cancelAsDefault: false, delegate: nil)
                return false
            }
            return true
        }

        if !checkIfUserFilesExist() {
            return
        }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    @objc func openUserPhrases(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.userPhrasesDataPathMcBopomofo)
    }

    @objc func openUserPhrasesPlainBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.userPhrasesDataPathPlainBopomofo)
    }

    @objc func openExcludedPhrasesPlainBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.excludedPhrasesDataPathPlainBopomofo)
    }

    @objc func openExcludedPhrasesMcBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.excludedPhrasesDataPathMcBopomofo)
    }

    @objc func openPhraseReplacementMcBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.phraseReplacementDataPathMcBopomofo)
    }
}

extension AppDelegate {
    private func enableBopomofoFontAnnotationSupportMenuItemIfRelevantFontsInstalled() {
        guard !Preferences.bopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1
        else {
            return
        }

        Preferences.bopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1 = true

        let supportedFontNames = [
            "BpmfGenRyuMin-B",
            "BpmfGenRyuMin-EL",
            "BpmfGenRyuMin-H",
            "BpmfGenRyuMin-L",
            "BpmfGenRyuMin-M",
            "BpmfGenRyuMin-R",
            "BpmfGenRyuMin-SB",
            "BpmfGenSekiGothic-B",
            "BpmfGenSekiGothic-H",
            "BpmfGenSekiGothic-L",
            "BpmfGenSekiGothic-M",
            "BpmfGenSekiGothic-R",
            "BpmfGenSenRounded-B",
            "BpmfGenSenRounded-EL",
            "BpmfGenSenRounded-H",
            "BpmfGenSenRounded-L",
            "BpmfGenSenRounded-M",
            "BpmfGenSenRounded-R",
            "BpmfGenWanMin-EL",
            "BpmfGenWanMin-L",
            "BpmfGenWanMin-M",
            "BpmfGenWanMin-R",
            "BpmfGenWanMin-SB",
            "BpmfGenYoGothic-B",
            "BpmfGenYoGothic-EL",
            "BpmfGenYoGothic-H",
            "BpmfGenYoGothic-L",
            "BpmfGenYoGothic-M",
            "BpmfGenYoGothic-N",
            "BpmfGenYoGothic-R",
            "BpmfGenYoMin-B",
            "BpmfGenYoMin-EL",
            "BpmfGenYoMin-H",
            "BpmfGenYoMin-L",
            "BpmfGenYoMin-M",
            "BpmfGenYoMin-R",
            "BpmfGenYoMin-SB",
            "BpmfHuninn-Regular",
            "BpmfIansui-Regular",
            "BpmfZihiBox-R",
            "BpmfZihiKaiStd-Regular",
            "BpmfZihiOnly-R",
            "BpmfZihiSans-Bold",
            "BpmfZihiSans-ExtraLight",
            "BpmfZihiSans-Heavy",
            "BpmfZihiSans-Light",
            "BpmfZihiSans-Medium",
            "BpmfZihiSans-Regular",
            "BpmfZihiSerif-Bold",
            "BpmfZihiSerif-ExtraLight",
            "BpmfZihiSerif-Heavy",
            "BpmfZihiSerif-Light",
            "BpmfZihiSerif-Medium",
            "BpmfZihiSerif-Regular",
            "BpmfZihiSerif-SemiBold",
        ]

        var hasSupportingFont = false
        let allFonts = Set(NSFontManager.shared.availableFonts)
        for fontName in supportedFontNames {
            if allFonts.contains(fontName) {
                hasSupportingFont = true
                break
            }
        }

        if hasSupportingFont {
            Preferences.showBopomofoFontAnnotationSupportItemInInputMenu = true
        }
    }
}
