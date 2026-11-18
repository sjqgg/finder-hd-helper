<p align="center"><img src="Assets/FinderHDHelper.png" width="128" alt="Finder HD Helper icon"></p>

# Finder HD Helper · Finder 高清助手

在 **Finder 原窗口**中，用 **Shift＋滚轮**调整缩略图大小，生成高清预览，并按窗口宽度自动换行。

A small native macOS menu bar utility for Shift-scroll thumbnail zoom, high-resolution image previews, and automatic wrapping in Finder. No separate image browser or LinearMouse process is required.

## 功能

- **Shift＋滚轮缩放**：鼠标位于前台 Finder 图标视图的内容区域时，向上放大、向下缩小；可反转方向。
- **高清预览**：从原图生成最高 1024 像素的 Finder 图标，保持图片比例；照片数据与 EXIF 不重新编码。
- **自动换行**：开启 Finder 持续排序。窗口变窄时，单张图标会自动缩小到可用宽度内，减少横向拖动。
- **可恢复**：修改前保存原有图标属性；可按文件夹恢复，保留用户已有的自定义图标。
- **登录启动**：可在助手面板开启。所有处理在本机完成，没有上传、账户登录或网络服务。

## 下载与使用

在本仓库 **Releases** 页面下载 `Finder-HD-Helper-v1.1.2-macOS-arm64.zip`，解压后将「Finder高清助手.app」放入「应用程序」再打开。

1. 在系统提示中允许助手控制 **Finder**。
2. 在「系统设置 → 隐私与安全性 → 辅助功能」开启 **Finder高清助手**。
3. 打开图片文件夹，按 **⌘1** 切换到图标视图。
4. 将鼠标放在图片区域，按住 **Shift** 滚动鼠标滚轮。菜单栏图标可打开设置和恢复操作。

当前发行包是 **Apple Silicon（arm64）** 版本，最低构建目标为 **macOS 13**。实机验证环境为 **macOS 26.5.1 / Apple Silicon**；较早系统和 Intel Mac 尚未实机验证。界面为中文，自动排序菜单支持简体中文、繁体中文与英文 Finder。

发行包使用本地临时签名，**未经过 Apple Developer ID 签名和公证**。macOS 下载后可能拦截首次打开，请先核对来源，再按 [Apple 官方的应用打开说明](https://support.apple.com/en-us/102445) 操作；也可以从源码自行构建。

如果 LinearMouse 正在运行，助手会暂停内置缩放以避免重复处理；退出 LinearMouse 后自动接管。

## 数据和已知限制

助手写入图片文件的 Finder 图标扩展属性和资源叉，会增加磁盘占用；照片数据本身保持不变。恢复记录保存到：

```text
~/Library/Application Support/FinderClear/IconBackups
```

- 仅处理当前文件夹中的本地图片，不递归处理子文件夹。
- 支持 JPG/JPEG、PNG、HEIC/HEIF、WebP、TIFF、BMP。系统无法解码的格式会报错或跳过。
- 符号链接、未下载的 iCloud 占位图片以及用户已有的自定义图标会跳过；只读文件可能无法处理。
- 自动换行会将自由排列或吸附网格改为按名称排序；已有名称、日期、大小等有效排序会保留。
- 单张图片超过窗口可用宽度时，自动适配可能需要约 0.5–2 秒。
- 恢复记录使用原文件路径。移动、重命名图片前，建议先恢复原有预览。
- 退出助手不会移除已生成的图标；卸载前可先在相关文件夹执行「恢复此文件夹的预览」。
- 本地签名版本升级后可能需要在辅助功能列表移除旧记录，再添加应用程序中的新版助手。

## 从源码构建

安装 Xcode Command Line Tools，然后在仓库目录运行：

```sh
bash build.sh
open .build.noindex
```

产物为 `.build.noindex/Finder高清助手.app`。构建脚本默认使用当前 Mac 的架构，并明确设置 macOS 13 部署目标。可通过 `FINDER_CLEAR_ARCH=arm64` 或 `FINDER_CLEAR_ARCH=x86_64` 指定架构；发布的预编译包仅提供已在 Apple Silicon 上运行验证的 arm64 版本。

运行现有的滚轮逻辑校验：

```sh
'.build.noindex/Finder高清助手.app/Contents/MacOS/FinderClear' --self-test-wheel
```

高清图标生成与恢复测试只处理输入照片的副本：

```sh
'.build.noindex/Finder高清助手.app/Contents/MacOS/FinderClear' \
  --self-test /path/to/a-test-photo.jpg .build.noindex/icon-tests
```

测试覆盖缩放方向、滚动防抖、横轴兼容、惯性过滤、普通快捷键放行，以及图标生成、重复执行、已有图标保留、恢复和照片字节一致性。

## 实现与致谢

- Swift / SwiftUI / AppKit，无第三方运行时依赖。
- 图片预览使用 ImageIO 和 `NSWorkspace.setIcon`；Finder 排序与缩放使用辅助功能 API，当前文件夹查询使用 Apple Events。
- 滚轮方向、防抖和事件监听参考并改编自 MIT 许可的 [LinearMouse](https://github.com/linearmouse/linearmouse)，完整许可证随源码和应用提供。
- 本项目与 Apple、LinearMouse 没有隶属关系。

源码采用 [MIT 许可](LICENSE)。第三方代码和图标说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
