# 生成「可签名 / 已签名」IPA — iOS 签名指南

DebianTerminal 的 CI（GitHub Actions）已经能编译 iOS App 并打包 IPA。
本文件说明：**如何让 CI 产出「用你的开发者证书签名的、能装到 iPhone/iPad 上的 IPA」**。

## 1. 先说结论（为什么 iOS 必须签名）

- iOS **拒绝安装未签名的 App**（`Code signature invalid` / 无法安装）。
- JIT 运行 QEMU 还需要合法签名 + 设备开启「开发者模式（Developer Mode）」。
- **签名在苹果的体系中只能由你的 Apple Developer 证书完成**——任何第三方（包括本 CI）都无法绕过；CI 只能拿到你提供的证书后替你完成 codesign。

所以，「开发者证书签名的 IPA」= **CI 全自动编译 + 你提供 4 个签名 Secrets**。

## 2. 你需要准备的 4 个 Secret（任何人都替代不了）

| Secret 名称 | 内容 | 示例 |
|---|---|---|
| `APPLE_TEAM_ID` | Apple 开发者团队 ID（10 位字母数字） | `ABCDE12345` |
| `APPLE_CERT_P12_BASE64` | 开发者证书 `.p12`，base64 编码 | (超长字符串) |
| `APPLE_CERT_P12_PASSWORD` | 导出 `.p12` 时设置的密码（没有则为空） | `my-p12-pw` |
| `APPLE_PROVISIONING_BASE64` | 匹配的描述文件 `.mobileprovision`，base64 编码 | (超长字符串) |

> 需要 Apple Developer Program 付费账号（¥688/年 或 $99/年），用免费账号无法签发用于真机的证书。

> **⚠️ 免费账号有例外——本项目场景可用**：UTM（iOS 上跑 QEMU 的权威项目）官方文档明确，
> 「For stock iOS devices, you can sign with either a free developer account or a paid
> developer account. Free accounts have a 7 day expire time and must be re-signed every
> 7 days.」即**免费个人账号（Personal Team）也能签名带 JIT entitlement 的构建**，只是
> 描述文件 7 天过期，需用 SideStore/AltStore 每 7 天自动重新签名。若你没有付费账号：
> 用 Xcode 的「Personal Team」+ 自动签名在**你自己的 Mac** 上跑 `Scripts/package-ipa.sh`
> 即可（或取 Xcode 自动生成到 `~/Library/MobileDevice/Provisioning Profiles/` 的
> `.mobileprovision` + Keychain 里 `Apple Development:` 证书导出 `.p12` 喂给 CI）。

### 在 Mac 上导出这些内容（一次性操作）

1. **证书**：钥匙串访问（Keychain Access）→ 登录 → 证书（Certificates）→ 找到
   `Apple Development: 你的名字 (TEAMID)` → 右键导出 → 存成 `.p12`（设置密码）。
   转 base64：
   ```bash
   base64 -i cert.p12     # 复制输出 → 粘贴到 APPLE_CERT_P12_BASE64
   ```

2. **描述文件**：developer.apple.com → Certificates, Identifiers & Profiles → Profiles
   → 下载 `.mobileprovision`（必须是 Development 且包含你的设备 UDID，以及
   `com.apple.security.cs.allow-unsigned-executable-memory` 等 entitlements 可用的真机描述文件）。
   转 base64：
   ```bash
   base64 -i YourProfile.mobileprovision    # 复制输出 → 粘贴到 APPLE_PROVISIONING_BASE64
   ```

3. **Team ID**：developer.apple.com → Membership → Team ID（10 位），或 Xcode →
   Accounts → 你的账号详情里的 Team ID。

## 3. 把 Secrets 放进仓库

GitHub 网页操作：

1. 打开仓库 `https://github.com/xngfhghfgd/DebianTerminal`
2. **Settings → Secrets and variables → Actions → New repository secret**
3. 依次建立：`APPLE_TEAM_ID`、`APPLE_CERT_P12_BASE64`、`APPLE_CERT_P12_PASSWORD`、`APPLE_PROVISIONING_BASE64`
   （粘贴时**小心别带换行/空格**；base64 默认会换行，用上面的 `base64 -i` 输出通常没问题，但若失败请用 `base64 -i file | tr -d '\n'`）。

## 4. 触发签名构建

- 有 Secrets 后，每次 push 到 `main`、或手动 **Actions → Build IPA → Run workflow**，
  流程会自动走「签名分支」：
  - 把 `.p12` 导入临时 keychain
  - 安装 `.mobileprovision`
  - `xcodebuild archive`（自动签名，`DEVELOPMENT_TEAM=$APPLE_TEAM_ID`）
  - `xcodebuild -exportArchive`（`ExportOptions.plist`，method=development 保留 JIT entitlement）
- 产出：**`DebianTerminal.ipa`**（artifact：`DebianTerminal-ipa`）。

## 5. 安装到设备

1. iPhone/iPad → 设置 → 隐私与安全性 → 开发者模式 → 打开（需要重启）。
2. 用**侧载工具安装**（SideStore / AltStore / 爱思助手 / Xcode 均可）。开发者证书签名 +
   描述文件包含该设备 UDID → 可直接信任。
3. 安装后把 `debian12.img`（8 GiB）等运行资源按 README 放入 App 的
   `Documents/Debian/`（磁盘镜像太大，不适合塞进 IPA / git）。

## 6. 没有 Secrets 时 CI 会怎样？

会构建**未签名 IPA**（`DebianTerminal-unsigned.ipa`），验证编译链路，但**无法安装到真机**。
这属于「证明能编译」，不是「可用的签名 IPA」。

---

## 常见问题

- **Q：免费 Apple ID 行不行？** A：可以（本场景）。UTM 官方确认免费账号可签名带 JIT 的
  构建，但描述文件 **7 天过期**，需 SideStore/AltStore 周期重签（首次需要用电脑安装
  SideStore/AltStore 并信任）。付费账号（¥688/年）则描述文件最长 1 年、日常省心。
  注意免费 Personal Team 一条 App ID 最多 10 台设备、且 Xcode 自动签名的描述文件
  默认只对 1 台设备有效——为多台设备需要手动创建 App Group/多设备描述文件。
- **Q：CI 的 macOS runner 是免费的吗？** A：本仓库是 public，GitHub 为 public 仓库提供
  免费 macOS runner 分钟数；private 仓库在免费套餐**没有** macOS runner（开不了 iOS 构建）。
- **Q：导出 archive 时报 "no profiles"？** A：Team ID 或描述文件不匹配（bundle id 应为
  `dev.debianterminal.app`）、设备 UDID 未加入描述文件、证书不是 Development 类型。