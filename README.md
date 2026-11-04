# WatchMouse 原型

用戴在手腕上的 Apple Watch 控制 Mac 光标。手表读取手腕转动，通过蓝牙发给 Mac 菜单栏应用。目前有光标移动和手势采集，还没有手势点击。

需要 macOS 14、watchOS 11、Xcode 和 XcodeGen。

```bash
swift test
```

```bash
./scripts/build-app.sh
```

```bash
open build/WatchMouse.app
```

```bash
./scripts/install-watch.sh <手表 UDID>
```

手表 UDID 用 `xcrun devicectl list devices` 查看。签名用的是个人免费团队，描述文件约 7 天过期，过期后重新运行安装脚本。

## 使用

1. 打开 Mac 应用，允许蓝牙。菜单栏显示 `⌚️ –`。
2. 打开手表应用，等它显示“已连接 Mac”，点“开始光标”。菜单栏应显示每秒收到的包数。
3. 在 Mac 菜单里打开“控制光标”，第一次需要授予辅助功能权限。

暂停有两种方式：手表上双指互点，或在 Mac 上按 `⌃⌥⌘P`。手转到极限时先暂停、回正，再继续。

## 运动映射

- 用重力判断方向，手心朝下或侧立时，向右转都是光标向右。
- 手表发送角度增量，Mac 再换算成像素，所以灵敏度和方向反转都在 Mac 菜单里调，不用重装手表应用。

## 日志

日志在 `~/Library/Logs/WatchMouse/`：`packets-*.csv` 是每个收到的包，`status-*.log` 每秒记录频率、丢包和最大间隔。

## 已知限制

- 手表保持运行靠 `physical-therapy` 延长运行会话，只适合自用，上架需要重新选择方案。

## 手势采集

用来判断抓握、连续抓握和张开手能否识别。这一步只采集和离线分析，还不会触发点击。

1. 在手表应用的光标页向下滑到采集页。
2. 依次录完列表里的每一轮：手势轮和“只震动”约 2 到 3 分钟，“只移动” 3 分钟，“日常操作”最长 30 分钟，可以提前结束。
3. 震动后默数一下再做手势，太快的样本会被丢弃。做错了点“作废”。

```bash
./scripts/pull-captures.sh <手表 UDID>
```

```bash
uv run analysis/analyze.py data/captures
```

采集文件只留在本地，`data/` 不进 Git。分析工具的自检：

```bash
uv run analysis/test_analyze.py
```

自检用的是合成数据，只说明工具没有算错，不代表真实识别率。

## TestFlight

Release 配置使用团队 `DLKMC3ZRZQ`，Bundle ID 是 `com.gptsmotion.watchmouse`（手表应用加 `.watchkitapp`），不包含采集功能。Debug 配置继续用个人团队。

```bash
./scripts/release-testflight.sh
```

运行前要在 Xcode 的 Settings > Accounts 登录该团队的账号，并在 App Store Connect 创建对应的应用记录。重新上传前先递增 `project.yml` 的 `CURRENT_PROJECT_VERSION`。

TestFlight 只分发手表应用，Mac 菜单栏应用要另外安装。

## 实测结论（2026-11-04，Apple Watch Series 10）

- 连接时约 49 Hz，累计约 258 秒、12678 包，日志没有记录到丢包。
- 测试时打开了“控制光标”，灵敏度调到 2.0。
- 旧版锁屏后断开，约 84 秒才恢复。改为直连上次设备并同时扫描后，用户复测重连在 3 秒内。
- 未验证：手感是否达标、断开是手表锁屏还是 Mac 锁屏引起的、长时间运行、耗电、小目标定位精度。
