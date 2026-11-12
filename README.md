# SafariLinkRouter

Safari 越狱插件：拦截那些 **系统里没有任何 App 能打开** 的链接（`magnet:`、`ed2k:`、`thunder:`、`ftp:` …），
不再弹「Safari 浏览器打不开该网页，因为网址无效」，而是给你一个可操作的菜单。

## 能力

- **JS 层拦截**：注入到每个 `WKWebView`，在 click / auxclick / `window.open` 阶段阻止导航，链接不会再去尝试打开。
- **Native 兜底**：hook `UIApplication canOpenURL:` / `openURL:`，即使 JS 没拦住（脚本跳转等），也不会弹那个错误框。
- **首次点击可选 App 并记住**：弹出动作面板 →「复制并用指定 App 打开…」→ 从已安装 App 里选一个 →
  链接写入剪贴板并唤起该 App（迅雷、Documents、iTorrent 这类"粘链接下载"的 App 直接可用）。
- **已记住的 scheme 直接执行**，不再打扰。
- 系统本来就能处理的 scheme（http/tel/mailto/微信/支付宝…）完全不碰。

## 安装

- rootless（Dopamine / palera1n 等）：`rootless-deb`
- RootHide：`roothide-deb`

装完执行 `killall MobileSafari`（或重启手机），然后去点一个磁力链接试试。

## 配置

路径（二选一，先找到哪个存在）：

```
/var/mobile/Library/Preferences/com.xiaofeifei.safarilinkrouter.plist
/var/jb/var/mobile/Library/Preferences/com.xiaofeifei.safarilinkrouter.plist
```

默认值（文件不存在时）：

```xml
<key>enabled</key>          <true/>          <!-- 总开关 -->
<key>interceptUnknown</key> <true/>          <!-- 拦截"没 App 能打开"的任意 scheme -->
<key>schemes</key>          <array><string>magnet</string><string>ed2k</string><string>thunder</string><string>ftp</string><string>xl</string></array>
<key>rules</key>            <dict/>          <!-- 规则，由 App 选择器自动写入 -->
```

规则格式：

```xml
<key>magnet</key>
<dict>
  <key>action</key><string>copyOpen</string>     <!-- copyOpen / copy / open / template -->
  <key>bundleID</key><string>com.xunlei.thunder</string>
</dict>
```

`template` 动作支持占位符：`{url}`（URL 编码后的完整链接）、`{raw}`（原样）、`{hash}`（磁力 btih）。

```xml
<dict>
  <key>action</key><string>template</string>
  <key>template</key><string>myapp://add?magnet={url}</string>
</dict>
```

想重新选择 App：删掉 `rules` 里对应的那一条（或整个 plist）。

## 说明

- 只 hook `com.apple.mobilesafari` 与 `com.apple.SafariViewService`。
- 需要 `mobilesubstrate` 或 `ellekit`。
