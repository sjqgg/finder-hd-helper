Finder 高清助手首次 GitHub 发行版。在 Finder 原窗口中使用 Shift＋滚轮调整缩略图大小，同时提供高清预览、自动换行和登录启动。

### 下载

- `Finder-HD-Helper-v1.1.2-macOS-arm64.zip`：Apple Silicon 版本。
- `SHA256SUMS.txt`：安装包 SHA-256 校验值。

将解压后的应用放入「应用程序」，允许控制 Finder，并开启辅助功能权限。在图片文件夹按 ⌘1，鼠标放在图片区域，按 Shift＋滚轮缩放。

最低构建目标为 macOS 13；实机验证为 macOS 26.5.1 / Apple Silicon。较早系统及 Intel Mac 尚未实机验证。本发行包为本地临时签名，未经 Apple Developer ID 签名和公证，首次下载打开可能被系统拦截；安装与恢复步骤见 README。

该版本保留 1.1.1 的功能，并修正构建脚本的最低系统目标。图片处理在本地完成，原图数据和 EXIF 不重新压缩；Finder 图标属性可恢复。LinearMouse 无需同时运行。
