# Android 0.11.2 正文复制菜单兼容修复

## 问题与修复

用户确认 Telegram 消息正文、ChatGPT 官方 Android App 的「选择文本」页面均不再触发。0.11.1 删除自动按钮后，菜单路径仍要求收到选区调整事件；不提供这些事件的控件因此没有自动入口。另一条原生路径还会把长按时读到的初始范围当成已接管的原生选区，阻止菜单兼容。

- 菜单路径区分真正收到的选区事件与长按节点上的范围。支持事件时保留初选静默、调整后弹出；没有事件但提供已核对的复制菜单时直接显示圆环。
- 只有长按标记时允许菜单路径接管；真实原生选区及已经显示的原生入口继续保持优先级，关闭后不会因菜单兼容重新弹出同一选区。
- 直接圆环仍使用有限、不抢焦点的窗口。选文手柄可继续拖动，开始操作圆环后才展开触摸区域和 GTA 背景。没有增加中间按钮或触发倒计时。
- 显示菜单不复制或读取选文。用户选动作后才按原来源复制准确文本，等待实际焦点、检查时效并执行；保留取消、快照、来源离开和应用禁用规则。
- Telegram 独立开关与通用菜单开关保持原值。ChatGPT 等非 Telegram 应用的标准菜单走「通用选文菜单兼容」，不自动扩大授权。主动选择的按钮模式仍可用。
- 更新中英文说明；最近结果为直接圆环已显示时，诊断显示正常状态。

## 验证

- 修改前两个最小真实窗口用例均失败：复制菜单存在，但未提供选区事件时不出圆环；原生长按范围还会阻断菜单入口。日志 `build/menu-fallback-0.11.2-red-api35.txt`。
- 修复后上述两项及 Telegram 专用路径共 3 项通过。Telegram 使用单独安装的合成 fixture，通用菜单开关关闭，验证非标准、非焦点复制菜单及准确 Unicode 子串；无真实账号或聊天内容。日志 `build/menu-fallback-0.11.2-first-api35.txt`。
- Android 8 / API 26：完整选文套件报告 19 项、0 失败。旧 WebView 原生范围缺失和未安装 Via 各跳过一项；新增的 WebView 菜单无范围直接圆环用例实际执行并通过。日志 `build/menu-fallback-0.11.2-final-api26.txt`。
- Android 15 / API 35：真实手柄拖动覆盖原生、通用菜单、有事件、无事件直接圆环及显式按钮模式。圆环已出现时仍能拖动手柄扩大选区，随后复制的内容与最终范围一致。日志 `build/menu-fallback-0.11.2-handles-api35.txt`。
- Android 15 最终完整 35 项真实窗口回归全部通过，包含 Telegram 独立路径、原生优先、焦点等待、快照、过期剪贴板、取消、应用暂停、首次定位及真实手柄操作。日志 `build/menu-fallback-0.11.2-clean-api35.txt`。
- 早期完整回归有一次翻译用例未显示菜单，以及一次请求选区时外部窗口节点为空。测试现先核对初选静默并等待外部编辑器可访问，再发即时选区请求；未给实际圆环添加延迟。翻译用例的 3 次针对性复测及最终两项初始化检查通过，临时探针已清理。日志 `build/menu-fallback-0.11.2-translation-probe-{1,2,3}.txt`、`build/menu-fallback-0.11.2-settlement-api35.txt`。
- 构建、59 项 JVM 测试通过；Lint 0 错误、7 项既有警告。日志 `build/menu-fallback-0.11.2-final-build.log`、`build/menu-fallback-0.11.2-final-checks.log`。
- 已目视核对固定测试数据截图：`build/menu-fallback-0.11.2-handles-visible-api35.png`、`build/menu-fallback-0.11.2-telegram-direct-api35.png`。图中系统剪贴板提示来自测试的固定剪贴板准备或校验步骤；生产代码仅显示圆环时没有执行复制或读取。

## 安装包

- `ActionHalo-0.11.2-debug.apk`；versionCode 38；minSdk 26；targetSdk 36。
- 1,561,542 字节，约 1.49 MiB；没有架构原生库，保持 Android 8+ 单一通用包。
- SHA-256：`fac47ab5b5f34d3af10bc7da91283d328a3701dbf95f9ba0f6a1cae63f11ea7c`。
- 签名验证通过；证书 SHA-256 为 `58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.11.1 相同。配置和原开关不重置。
- 安装包和 SHA-256 校验文件保存在仓库根目录及 `android/build/`。

未连接 vivo 真机，也未安装或登录真实 Telegram、ChatGPT。上述验证覆盖相应接口模式及合成菜单，不等同于两款实际版本和所有厂商已验证。未提交、推送或发布远程 Release。
