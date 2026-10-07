#!/bin/bash

# 1. 確保 LaunchServices 註冊 Smai.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Library/Input Methods/Smai.app"

# 2. 透過 Carbon TIS 註冊、啟用並切換至思脈注音
swift -e '
import Carbon
import Foundation

let appURL = URL(fileURLWithPath: "/Library/Input Methods/Smai.app")
let regStatus = TISRegisterInputSource(appURL as CFURL)
if regStatus != 0 {
    print("ℹ️ TISRegisterInputSource 回傳: \(regStatus)")
}

guard let sources = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
    print("❌ 無法取得系統輸入法清單")
    exit(1)
}

var targetSource: TISInputSource?
var targetID = ""

for s in sources {
    let idPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
    let id = idPtr != nil ? Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String : ""
    
    // 匹配思脈注音主模式
    if id.contains("Smai") && (id.hasSuffix("Bopomofo") && !id.contains("Plain")) {
        targetSource = s
        targetID = id
        break
    }
}

if let target = targetSource {
    let enableErr = TISEnableInputSource(target)
    let selectErr = TISSelectInputSource(target)
    if enableErr == 0 {
        print("✅ 已成功啟用思脈注音！(\(targetID))")
        if selectErr == 0 {
            print("🎯 已自動切換至思脈注音，請查看螢幕右上角輸入法圖示！")
        } else {
            print("💡 請在右上角輸入法選單或按 Control+Space 切換至思脈注音！")
        }
    } else {
        print("⚠️ 啟用失敗 (錯誤碼: \(enableErr))")
    }
} else {
    print("❌ 未能在 TIS 清單中找到思脈注音。目前系統相關來源：")
    for s in sources {
        let idPtr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID)
        let namePtr = TISGetInputSourceProperty(s, kTISPropertyLocalizedName)
        let id = idPtr != nil ? Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String : ""
        let name = namePtr != nil ? Unmanaged<CFString>.fromOpaque(namePtr!).takeUnretainedValue() as String : ""
        if id.contains("Smai") || id.contains("McBopomofo") || name.contains("思脈") || name.contains("注音") {
            print("  - [\(name)] ID: \(id)")
        }
    }
}
'
