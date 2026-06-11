# 产品截图

`docs/screenshots/` 中的 PNG 均为**真实应用界面**截屏，用于 README 与 [官网](https://empty-78c.pages.dev)。

## 重新生成

### macOS

```bash
# 书库
open /path/to/Empty.app
osascript -e 'tell application "Empty" to activate'
sleep 1
screencapture -x -R0,33,1512,865 docs/screenshots/mac-library.png

# 阅读器（自动打开最近在读）
pkill -x Empty
/path/to/Empty.app/Contents/MacOS/Empty -OpenReader &
sleep 5
osascript -e 'tell application "Empty" to activate'
screencapture -x -R0,33,1512,865 docs/screenshots/mac-reader.png
```

窗口坐标因显示器而异；可用 System Events 查询 `position` / `size` 后调整 `-R`。

### iOS 模拟器

```bash
SIM_ID="<iPhone 17 UDID>"
xcodebuild -scheme Empty \
  -destination "platform=iOS Simulator,id=$SIM_ID" build

xcrun simctl install $SIM_ID …/Empty.app
xcrun simctl launch $SIM_ID davirian.Empty -ScreenshotSeed
sleep 6
xcrun simctl io $SIM_ID screenshot docs/screenshots/ios-library.png

xcrun simctl terminate $SIM_ID davirian.Empty
xcrun simctl launch $SIM_ID davirian.Empty -ScreenshotSeed -OpenReader
sleep 8
xcrun simctl io $SIM_ID screenshot docs/screenshots/ios-reading.png
```

`-ScreenshotSeed` 在书库为空时导入演示 EPUB「思维之书」；Mac 截图使用本机真实书库数据。

更新后同步到官网资源：

```bash
cp docs/screenshots/*.png website/assets/screenshots/
cd website && wrangler pages deploy . --project-name=empty --branch=main
```