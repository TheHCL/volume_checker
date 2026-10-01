# Volume Checker 🎙

一個 macOS 小工具，透過（外接）麥克風持續監控環境音量。適合住在馬路邊、想知道車聲到底有多吵、什麼時段最吵的人。

## 功能

- **選擇輸入裝置**：可指定外接 USB 麥克風／音效卡，插拔會自動偵測；監控中拔掉麥克風，重新插上會自動恢復。
- **即時音量**：大字顯示目前 dB、彩色音量條、平均 Leq、最大值、超過門檻的時間比例。
- **最近 5 分鐘圖表**，標示門檻線。
- **吵雜事件偵測**：音量連續超過門檻 N 秒才算一次事件（避免一聲喇叭就觸發），記錄開始時間、持續時間、最大音量。
- **提醒**：macOS 系統通知和／或提示音（每分鐘最多提醒一次）。
- **選單列常駐**：選單列即時顯示 dB，關掉主視窗仍持續監控。
- **長時間紀錄**：每分鐘把 Leq／最小／最大寫入 CSV，事件也另存一份，可用 Excel 或 Numbers 畫出一整天的噪音變化；吵雜事件也可以匯出 CSV。
- 監控時防止 App Nap 和系統閒置睡眠，適合整夜監控。

> 音訊只在本機計算音量，**不會錄音、不會上傳**。

## 系統需求

- macOS 13 Ventura 以上
- Xcode 15 以上，或 Command Line Tools（`xcode-select --install`）

## 編譯與執行

```bash
git clone https://github.com/TheHCL/volume_checker.git
cd volume_checker
./scripts/build_app.sh
open build/VolumeChecker.app
```

想放進「應用程式」資料夾：`cp -R build/VolumeChecker.app /Applications/`

第一次按「開始監控」時，macOS 會詢問麥克風權限，請按「允許」。
若不小心拒絕，到「系統設定 › 隱私權與安全性 › 麥克風」開啟 VolumeChecker。

開發時也可以直接 `swift run`，但這種方式無法發送系統通知（需要 .app 才有 bundle identifier），麥克風權限會算在終端機 App 上。

也可以用 Xcode 開啟：`open Package.swift`，然後按 ⌘R。

## 使用建議

1. 把外接麥克風放在窗邊（面向馬路），接上 Mac，在上方選單選擇該麥克風。
2. **校正**：麥克風只能量到相對音量（dBFS），App 會加上「校正值」換算成近似的 dB。
   拿手機分貝計 App 放在麥克風旁邊，調整校正值讓兩邊數字接近即可。
3. 設定門檻與持續秒數，例如「65 dB、持續 3 秒」。
4. 開著讓它跑，之後點「開啟紀錄資料夾」查看 CSV。

常見音量參考（約略值）：

| 音量 | 情境 |
| --- | --- |
| 30 dB | 安靜的臥室夜間 |
| 40 dB | 安靜的住宅區 |
| 50 dB | 安靜的辦公室 |
| 60 dB | 一般對話 |
| 70 dB | 車多的馬路邊 |
| 85 dB 以上 | 長時間暴露可能傷害聽力 |

## 紀錄檔

位置：`~/Library/Application Support/VolumeChecker/`

| 檔案 | 內容 |
| --- | --- |
| `levels-YYYY-MM-DD.csv` | 每分鐘一列：時間、平均音量 Leq、最小、最大 |
| `events.csv` | 每個吵雜事件一列：開始、結束、持續秒數、最大、平均 |

## 限制

- 這不是經過認證的噪音計，數值是近似值，準確度取決於麥克風與校正。
- 沒有做 A 加權（dB(A)），量到的是未加權的音量；低頻的車輛引擎聲數值會比法規用的 dB(A) 偏高一些。
- Mac 闔上螢幕（非外接螢幕模式）時會進入睡眠，監控會暫停。

## 專案結構

```
Package.swift                       Swift Package 設定（macOS 13+）
Sources/VolumeChecker/
  VolumeCheckerApp.swift            App 進入點、選單列
  ContentView.swift                 主視窗介面
  AudioMonitor.swift                音訊擷取、音量計算、事件偵測、通知
  AudioDevices.swift                CoreAudio 輸入裝置列舉與插拔監聽
  LevelLogger.swift                 CSV 紀錄
Support/Info.plist                  .app 的 Info.plist（含麥克風權限說明）
scripts/build_app.sh                打包成 .app
```
