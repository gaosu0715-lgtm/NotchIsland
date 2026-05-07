# NotchIsland

NotchIsland 是一个 Swift + SwiftUI/AppKit 的本地 macOS 浮层模板，把 MacBook Air 顶部刘海区域模拟成 iPhone Dynamic Island 风格的 Apple Music 播放岛。

当前版本只实现 Apple Music 播放展示，不显示系统通知、音量、亮度或其他系统状态。

## 功能

- 顶部居中黑色浮层，使用 `NSPanel` 最前端显示，不修改系统菜单栏或系统文件。
- 收起态贴合刘海/摄像头外壳区域，中间留空避让真实刘海。
- 左侧显示正方形专辑封面，右侧显示动态声波；暂停或未播放时封面略微变暗，右侧变为静止点阵。
- 展开态顶部中间刘海区域保持纯黑，所有音乐信息整体下移，避免被真实刘海遮住。
- 声波颜色使用专辑封面的 RGB k-means 主色聚类结果，保留黑白灰等中性色，只做黑底可读性亮度修正。
- 播放中浮层会轻微扩展，暂停或未播放时回到更小的静态状态。
- 点击浮层展开/收起，展开后显示歌曲、歌手、专辑、播放进度和上一首/播放暂停/下一首按钮。
- 右键菜单支持打开 Apple Music、播放/暂停、刷新当前播放、退出。
- 使用公开 API：`MediaPlayer` / `MPNowPlayingInfoCenter`、`DistributedNotificationCenter` 和 Apple Events。

## 关于 Apple Music 数据来源

macOS 上 `MPNowPlayingInfoCenter` 是公开 API，但它通常更适合当前进程或系统可见的 Now Playing 信息。为了让 Apple Music 展示更稳定，本模板同时使用：

- `MPNowPlayingInfoCenter`：读取公开的 Now Playing 信息。
- `DistributedNotificationCenter`：监听 Music.app 的公开播放状态通知。
- Apple Events：在用户授权后读取 Apple Music 的封面、进度，并执行播放/暂停/上一首/下一首。

不使用私有 API。首次使用 Apple Events 控制 Music 时，系统可能会提示允许 NotchIsland 控制“音乐”。

## 刘海位置和尺寸策略

Apple 公开规格中，13 英寸 MacBook Air M4/M5 机身模具对应 13.6 英寸 Liquid Retina 显示屏，分辨率为 2560×1664、224 ppi。Apple 不公开每个机型/显示缩放模式下刘海的精确像素宽高，因此代码优先使用 `NSScreen.auxiliaryTopLeftArea` / `NSScreen.auxiliaryTopRightArea` 反推摄像头外壳左右边界，再用 `NSScreen.safeAreaInsets.top` 估计顶部遮挡高度。

如果在你的显示缩放模式下位置还想更贴边，可以调整：

```swift
private func updateFrame(animated: Bool)
```

其中 `visibleBelowNotch` 控制收起态露出刘海下边缘的高度。

当前尺寸以 `1710×1112` 显示缩放为设计基准。高度按当前内置显示器等比例缩放；横向会保留额外刘海避让宽度，避免 `1280×832` 下封面和声波被摄像头外壳两侧遮住。

```swift
idleCompact = 176×40 pt
idleCompact = 242×44 pt
playingCompact = 304×44 pt
expanded = 570×226 pt
```

在 `1280×832` 下的实际窗口约为：

```text
idleCompact ≈ 218×33 pt
playingCompact ≈ 274×33 pt
expanded ≈ 490×169 pt
```

外层 `NSPanel` 始终保持展开态大小并固定在刘海中心；点击展开/收起只改变内部胶囊形态，不改变窗口锚点。

## 环境要求

- macOS 13 Ventura 或更新版本。
- Xcode 15 或更新版本，或 Xcode Command Line Tools。
- 带刘海的 MacBook Air / MacBook Pro 视觉效果最好；非刘海屏也会显示在屏幕顶部中央。

## 项目结构

```text
.
├── Package.swift
├── README.md
├── Resources
│   └── Assets.xcassets
│       └── DefaultArtwork.imageset
├── Sources
│   └── NotchIsland
│       └── main.swift
└── scripts
    └── package_app.sh
```

## 编译运行

命令行：

```bash
swift build
swift run NotchIsland
```

Xcode：

```bash
open Package.swift
```

然后选择 `NotchIsland` scheme，点击 Run。

## 打包 .app

```bash
scripts/package_app.sh
open dist/NotchIsland.app
```

运行后不会出现在 Dock 中，因为 `Info.plist` 设置了 `LSUIElement=true`。退出方式：右键点击浮层，选择 `Quit NotchIsland`。

## 授权 Apple Music 控制

如果系统提示允许 NotchIsland 控制“音乐”，请选择允许。也可以手动检查：

1. 打开 `系统设置`。
2. 进入 `隐私与安全性`。
3. 打开 `自动化`。
4. 确认 `NotchIsland` 可以控制 `音乐`。

授权后可以显示更完整的专辑封面、播放进度，并使用展开态的播放控制按钮。

## 扩展入口

主要代码都在 `Sources/NotchIsland/main.swift`：

- `IslandPanelController`：负责浮层尺寸和刘海区域定位。
- `IslandRootView`、`CompactMusicIslandView`、`ExpandedMusicIslandView`：负责 Dynamic Island 风格 UI。
- `WaveformView`：负责右侧动态声波。
- `AppleMusicNowPlayingProvider`：负责读取当前 Apple Music 播放信息。
- `AppleMusicController`：负责打开 Music、播放/暂停、上一首、下一首和读取封面。

如果以后要加入 Spotify 或其他播放器，建议新增一个 provider，最终转换成 `MusicSnapshot` 后调用：

```swift
model.updateMusic(snapshot)
```

## 参考资料

- [MacBook Air (13-inch, M4, 2025) - Tech Specs](https://support.apple.com/en-euro/122209)
- [MacBook Air (13-inch, M5) - Tech Specs](https://support.apple.com/en-mide/126320)
- [NSScreen.safeAreaInsets - Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)
