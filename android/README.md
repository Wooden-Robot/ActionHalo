# ActionHalo for Android

ActionHalo 的原生 Android 版（当前版本 0.11.5），支持 **Android 8.0 / API 26 及以上**。使用 Kotlin 和原生 Android View，保留圆环的「点击执行」与「按住、滑动、松开执行」交互。

统一提供 **Android 8.0 及以上通用 APK**，包括 vivo X200s 在内的设备无需再区分安装包架构。0.8.1 已移除浮窗翻译、ML Kit 和架构相关原生库，按架构拆包不再节省体积，因此取消分架构产物。圆环按实际窗口尺寸和屏幕密度适配，新系统 API 按版本判断并保留旧系统路径。`targetSdk 36` 不代表最低需要 Android 16，最低安装版本由 `minSdk 26` 决定，见 [Android 版本兼容规则](https://developer.android.com/guide/topics/manifest/uses-sdk-element)。

通用打包不等于所有品牌和所有应用的自动弹出均已验证。跨版本模拟器回归和跳过项见[兼容回归记录](diagnostics/compatibility-regression.md)；不同厂商的无障碍、后台管理和选文菜单差异需要真机验证。保留系统选文菜单、分享和剪贴板快捷磁贴入口，兼容边界见下文「自动模式与兼容范围」。

**0.9.0** 完成十项使用体验优化：按应用设置触发方式和固定动作组合；键盘避让及左右手初始位置；首页恢复入口与圆环内失败重试；配置备份；固定在外观页面上方的实时预览；动作指定打开方式；临时暂停快捷磁贴；编辑选文；删除、批量关闭和重置的短时撤销。仍提供 Android 8+ 单一通用 APK。见 [0.9.0 实现与验证](diagnostics/experience-0.9.0.md)。

### 0.11.5 拖动选文时隐藏圆环

拖动选文手柄时，自动圆环暂时隐藏并停止接收触摸；来源应用的选文菜单恢复后，复用圆环显示最新选文，保留当前页和首次触摸状态。尚未主动操作圆环时不打开 GTA 背景，第一次点功能仍在同一次松手执行。

圆环尺寸按屏幕和键盘空间初始化，不再因为手柄或复制工具栏挤占空间而缩小。只给真实手柄和选区端点让出操作区；完整尺寸无法避开手柄时暂时隐藏，空间恢复后继续显示。原生控件没有可读菜单时，沿用已有的选区稳定检查，不能保证获得真实松手时刻。见 [实现与验证](diagnostics/handle-hide-0.11.5.md)。

### 0.11.4 选文手柄优先

修复手柄进入圆环透明窗口边缘后，被当成首次定位、圆环移到手指下面的问题。选文期间根据选区两端、手柄和复制菜单的位置避让整个触摸窗口；原位没有冲突时保持不动，重叠时让出手柄操作区，必要时适配可用空间。开始主动操作圆环后位置固定。

原生选文、通用标准菜单和没有选区事件的菜单共用保护逻辑。没有增加中间按钮或触发倒计时；调整选区不会误开 GTA 背景，主动点选和首次定位规则保持可用。见 [实现与验证](diagnostics/handle-touch-0.11.4.md)。

### 0.11.3 调整选文时保持圆环位置

同一个文字控件内调整选区时，只更新选文和动作可用状态，保留圆环窗口、位置、当前页和首次触摸状态。复制菜单随手柄拖动重建时，更新复制目标而不重建圆环；选择功能仍使用当前菜单和最新选文。

尚未操作圆环时，选文手柄的触摸交给原应用，不再当作关闭圆环的外部点击。取消选文、离开来源和撤销授权仍会清理圆环；开始操作圆环后的远处点击退出保持可用。见 [实现与验证](diagnostics/anchor-0.11.3.md)。

### 0.11.2 恢复仅有复制菜单的正文入口

修复 0.11.1 去掉中间按钮后，没有选区变化事件的应用也被静默拦截的问题。仅提供可用复制菜单时，直接显示圆环，不再要求「打开圆环」按钮；真实提供选区变化事件时，仍保持初选静默、调整后松手弹出。长按节点能提供范围，不再被当作必然支持后续选区事件。

圆环先使用不遮罩、不抢焦点的有限窗口，原选文手柄仍可调整，开始操作圆环后才展开 GTA 背景。用户选择动作后才复制和执行。Telegram 保留独立开关；ChatGPT 等其他应用的标准选文菜单使用「通用选文菜单兼容」，不自动扩大现有授权范围。见 [实现与验证](diagnostics/menu-fallback-0.11.2.md)。

### 0.11.1 去掉自动出现的中间按钮（菜单兼容由 0.11.2 修正）

默认初次选文保持静默；调整选区后松手直接显示圆环，不再额外弹出「打开圆环」按钮或轻入口。原生选区、Telegram 与通用菜单兼容共同遵守此规则。只有主动为某个应用选择「按钮模式」时，才提供该按钮。没有公开选区变化的应用仍可使用系统选文菜单、分享或剪贴板手动入口。现有应用快捷设置、复制后保留、动作搜索及配置保持可用。见 [实现与验证](diagnostics/selection-0.11.1.md)。

### 0.11.0 常用操作优化（初选轻入口已由 0.11.1 撤回）

初次选文只显示 48dp 轻入口，点一下即可打开圆环；调整选区后的自动弹出保持原有规则。已确认来源的圆环新增「⋮」快捷设置，可暂停本次应用使用、暂停该 App 10 分钟或永久禁用自动入口；离开来源窗口后结束本次暂停，临时窗口抢焦点不会结束暂停。

「触发与权限 → 复制后保留圆环」为可选开关，默认关闭。开启后可对同一段选文继续选择动作，最多保留 30 秒，关闭、离开或锁屏时清理；后续操作复用首次快照，不重新读取剪贴板。

诊断页提供固定原因和对应处理入口；动作列表支持名称／网址搜索，搜索时不拖拽排序；可复制网站动作为新动作并在编辑器预览测试链接，实际打开测试网址需要明确点按。首页缩小为常用工具入口，演示区仍可展开。见 [实现与验证](diagnostics/daily-0.11.0.md)。

### 0.10.0 圆环与设置体验

八项优化覆盖链接识别、圆环内执行状态、集中应用规则、转动防抖、靠边与小窗口适配、可辨透明图标、设置摘要和配置恢复。首页可直接暂停及进入「应用与规则」；动作列表显示生效范围与打开方式，演示区域可折叠。配置表单在旋转后保留草稿；导入前展示差异，并可恢复导入前配置。

菜单兼容入口尚未取得选文时，「打开链接」可由用户主动选择，取得文字后再严格校验；已知非网址仍禁用。小于 240dp 的窗口临时显示 2／4 项紧凑菜单，不修改保存的每页数量。见 [实现与验证记录](diagnostics/usability-0.10.0.md)。

### 0.9.3 应用名称与图标

禁用应用、生效 App、按应用规则和打开方式的选择列表统一显示应用原始图标及名称，包名使用小号次级文字。图标不额外加背景或染色；读取不到应用名称时使用包名，已卸载的保存项使用默认图标。保留原来的搜索、选择、保存与取消方式，不改变配置。见 [0.9.3 实现与验证](diagnostics/app-icons-0.9.3.md)。

### 0.9.2 禁用应用

在 **首页 → 禁用应用** 或 **触发与权限 → 禁用应用** 中搜索并勾选 App，保存后该 App 的选文和复制不再自动显示圆环或辅助按钮，已等待的自动请求也会取消。其他 App 继续使用原有设置。

取消勾选恢复全局触发设置，保留该 App 的独立动作及排序。列表与“按应用设置触发和动作”的停用模式同步；配置备份自动包含禁用名单。用户主动通过分享、系统选文菜单或剪贴板快捷入口打开 ActionHalo 仍可使用。应用规则合计最多 200 个 App。见 [0.9.2 实现与验证](diagnostics/disabled-apps-0.9.2.md)。

### 0.9.1 生效 App

在 **操作管理 → 动作右侧 ⋮ → 生效 App** 中，选择“全部 App / 仅指定 App / 排除指定 App”，支持搜索应用名称或包名并多选。这里控制选文的来源 App；目标打开程序仍在“打开方式”中设置。未设置的动作默认在全部 App 生效，升级保留原有行为。

生效范围约束各 App 的独立动作组合，不匹配的动作从圆环隐藏。仅指定模式下，来源无法可靠识别的分享 / 手动剪贴板入口不会显示该动作；排除模式只排除能够确认的来源。设置预览与动作管理仍显示完整配置。执行前还会复查当前规则，旧圆环不能绕过后续更改。

配置备份、删除撤销与重置均包含生效 App。新版可导入 0.9.0 配置，缺少该字段时恢复为全部 App；0.9.0 不支持导入含新字段的备份。应用列表使用系统允许查询的可启动 App，并保留已保存的其他包名；每个动作最多指定 200 个 App。见 [0.9.1 实现与验证](diagnostics/action-app-scope-0.9.1.md)。

### 0.9.0 新入口

- **触发与权限 → 按应用设置触发和动作**：为可启动的已安装应用选择“跟随全局 / 调整选区后自动弹出 / 打开圆环按钮 / 停用自动触发入口”，并配置独立的动作及固定顺序。原生选区规则仍需读取选文授权；仅提供复制菜单的应用仍需对应的 Telegram 或通用菜单兼容开关。来源无法可靠识别的分享或剪贴板手动入口使用全局动作。
- **触发与权限 → 临时暂停自动弹出**：暂停 10 分钟或 1 小时，到期恢复，也可立即恢复。可以添加“自动弹出”快捷设置磁贴；暂停期间系统无障碍权限保持开启，分享和手动剪贴板入口仍可使用。
- **圆环外观与触感**：实时预览固定在设置上方，可试点选、拖动、分页和关闭。调整大小、数量、遮罩、GTA 后立即更新；预览只展示动作名称，不执行搜索或复制。完整背景模糊仍以实际圆环显示为准。初始位置可选自动、左下、右下；操作开始后不因布局变化重新定位。
- **操作管理 → 动作的 ⋮ → 打开方式**：网站类动作可选择系统默认处理器或可用应用；豆瓣综合与 Telegram 提供实际支持的 App。指定浏览器无法启动时使用相同网址回退；Telegram 指定客户端失败时保留圆环提示，不构造不存在的网页搜索。豆瓣书籍和电影仍使用分类网址。
- **操作管理 → 编辑选文**：这个新动作默认关闭，启用后可主动修正文字，再进入圆环选择搜索等动作；不会改写原应用的文字。编辑内容只在本次内存会话中保留，旋转屏幕时可继续编辑。
- **首页 → 配置备份与恢复**：使用系统文件选择器保存或读取 JSON，导入前确认替换。包含动作、排序、启用状态、外观、应用规则及打开方式；不包含选文、剪贴板、权限同意、诊断或暂停状态。最多 1 MiB、200 个自定义动作，文件全部校验通过后才替换配置。新手机仍需自行授予系统权限。
- **删除 / 全部停用 / 恢复默认**：提供 15 秒内存撤销。后续修改或离开当前页面会使旧撤销失效，避免覆盖新的配置；外观重置同样可撤销。
- **首页状态与失败恢复**：区分自动功能关闭、临时暂停、系统授权关闭和服务断开，并给出相应恢复或手动剪贴板入口。动作失败时保留圆环和本次选文，可明确点选重试或其他动作；焦点恢复不会自行重复执行失败的动作。

键盘避让使用系统公开的窗口和 Insets 信息；无障碍浮层可识别悬浮键盘矩形，普通 Activity 遇到不报告遮挡范围的悬浮键盘仍可能无法完整避让。应用没有公开选区或标准菜单时，按应用规则也不能补出这些信息。备份由系统文件提供器读写；无效文件不会修改配置，跨偏好文件恢复遭遇进程被强制终止时不保证事务原子性。

**0.8.7** 长按初次选中时不自动弹出圆环；同一控件的选区范围改变后才触发。重复选区事件不触发，取消后重新选字、重新长按另一处文字或切换控件，都重新作为初选处理。原生选区与菜单兼容共同遵守此规则；菜单入口初次只提供小号「打开圆环」按钮，不提供选区变化的应用可以调整完后手动点它。没有增加等待倒计时，原有手动选文、分享、剪贴板入口保留。见 [0.8.7 初选静默与验证](diagnostics/initial-selection-0.8.7.md)。

**0.8.6** 自动选文圆环先以可触摸穿过周围区域的独立窗口显示，保持原页面清晰，继续拖动原应用选区手柄即可改选文字。触摸圆环时才展开完整操作层并启用 GTA 虚化；第一次点图标仍在同一次松手执行。没有新增等待倒计时，手动选文、分享、剪贴板和诊断入口仍直接进入完整圆环。支持时以选区首尾字符坐标避让原生手柄，Telegram/通用菜单入口以已核对的复制菜单位置避让。见 [0.8.6 选区调整及验证](diagnostics/selection-adjustment-0.8.6.md)。

**0.8.5** 为 GTA 模式接入 Android 12+ 的原生跨窗口实时模糊，配合较轻的调暗、灰绿薄雾与暗角，原应用背景虚化而圆环保持清晰。系统在省电等情况下关闭模糊时自动回退，关闭 GTA 后不模糊。正常执行圆环功能时隐藏「继续／取消」过渡卡片，只有持续等待受阻时才显示。见 [0.8.5 背景模糊及验证](diagnostics/gta-blur-0.8.5.md)。

**0.8.4** 按 PC 源码补齐 GTA 视觉层次：上下加深渐变与径向暗角、半透明黑色分区、白色图标的黑色柔影、即时亮白与柔光，以及重字标题和等宽 HUD。12/16 项使用 PC 对应的窄缝隙，编号为 10 sp。投影缓存后复用，外观调整继续回归点选、距离上限、分页和序号间距。见 [0.8.4 PC 对照及验证](diagnostics/gta-pc-0.8.4.md)。

**0.8.3** 为功能选择增加外侧上限：圆环外缘保留 32 dp 缓冲，手指超出后取消高亮，松手关闭且不执行；按住滑回有效范围可继续选择。普通/GTA、手动及自动入口共用按屏幕密度缩放的上限，保留首次空白定位与图标点选不跳位。见 [0.8.3 验证记录](diagnostics/selection-limit-0.8.3.md)。

**0.8.2** 修复首次点选图标导致圆环跳位：首次非分页触摸在圆环内时保持原位，按下预览、松手执行；仅在圆环外空白处首次按下时同步中心。首次触摸后位置固定，取消、翻页和操作重试不再移动，保留中心与远处点击关闭。普通/GTA 以及手动、自动和复制菜单入口共用此规则。见 [0.8.2 验证记录](diagnostics/direct-tap-0.8.2.md)。

**0.8.1** 移除浮窗翻译、语言识别及翻译模型依赖。内置「Google 翻译」恢复为网页入口，选中动作后才将文字交给 Google 翻译网站；不再提供本机或离线翻译。手动选文、分享、无障碍选区和复制菜单入口共用原有网址执行流程。升级后首次打开应用会在后台清理旧版下载的翻译模型，保留动作、排序、开关和外观设置。通用安装包约 1.05 MB，验证结果见 [0.8.1 移除记录](diagnostics/remove-floating-translation-0.8.1.md)。

**0.8.0** 完成首页与设置分层，首页保留服务状态、体验和导航；操作管理、外观与触感、触发与权限、故障诊断、关于与更新各自独立。新增五档圆环大小、0–80% 背景遮罩、普通/GTA 共用的轻震开关及外观重置。所有入口使用同一份外观配置，大小继续按可用屏幕缩小，首次定位和外部点击关闭规则保持不变。

「关于与更新」手动读取公开 GitHub 发布列表，显示 Android 新版本、更新说明和下载入口。仅接受本仓库、非草稿/非预发布、同 debug/release 渠道的版本化 APK；不会把 macOS 发布作为 Android 更新。下载交给浏览器，安装仍由系统处理。本轮未发布 GitHub Release，因此公开仓库没有 Android APK 时会明确提示未找到发布。实现、测试和安装包边界见 [0.8.0 验证记录](diagnostics/settings-translation-updates-0.8.0.md)。

**0.7.12** 兼容旧系统选文工具条：缺少新版外层标识时，识别系统菜单项标识。仍限定前台应用的同包子窗口、明确的系统工具条和唯一复制按钮，普通「复制」弹窗不会触发。旧 WebView 不提供有效选区范围时，可启用「通用选文菜单兼容」直接显示圆环；原生自动选文开关单独使用无法读取这类范围。版本继续使用通用 APK，保留现有配置和签名。

**0.7.11（历史；远处滑动规则已由 0.8.3 调整）** 首次触摸定位后，点击圆环外缘再往外 32 dp 以外的空白处，松手关闭且不执行操作；缓冲范围内仍可选择。远处按下后明显滑动则继续方向选择，不会因拖到圆环外而误退出。分页、取消和多指中断保留原行为。见 [0.7.11 验证记录](diagnostics/outside-tap-0.7.11.md)。

**0.7.10（历史；首次触摸规则已由 0.8.2 调整）** 每次打开圆环后，仅第一次非分页触摸会把圆环中心移到手指下；之后保持位置固定，翻页、手势取消及操作失败重试均不会重新定位，点击中心可关闭。重新打开圆环后可再次首次定位。见 [0.7.10 验证记录](diagnostics/first-touch-anchor-0.7.10.md)。

**0.7.9** GTA 圆环中的序号和图标分为内外两排，按实际字号和图标选中后 1.22 倍尺寸留出间距；小尺寸自动缩放图标，保留圆环外径、分页及按下点同步中心交互。见 [0.7.9 验证记录](diagnostics/slot-spacing-0.7.9.md)。

**0.7.8（历史；定位次数已由 0.7.10 调整）** 在屏幕可用区域按住任意位置，圆环中心立即同步到按下点；围绕该点滑动选择，松手执行，移回该点松手取消。每次起手重新定位，滑动期间中心固定。保留图标短点执行、原生无障碍点击与分页；靠近边缘时圆环可以部分超出屏幕，不偏移按下点。见 [0.7.8 验证记录](diagnostics/anchor-touch-0.7.8.md)。

**0.7.7** 圆环显示后，屏幕可用区域任意位置都能按相对圆环中心的方向选择操作，移动切换、松手执行，不再受圆环外半径限制。普通/GTA、手动及自动入口共用全屏触摸转发；圆环位置、大小和分页不变。点中心或移回中心松手取消；系统栏仍由系统处理。见 [0.7.7 验证记录](diagnostics/anywhere-touch-0.7.7.md)。

**0.7.6** 「打开链接」仅在已知选文是有效 HTTP(S) 网址或可补全的裸域名时启用；普通文字、无效协议置灰；0.10.0 起尚未取得选文的兼容入口可主动点击后校验。保留扇区位置，点击、拖动与键盘焦点均不能选择不可用项。见 [0.7.6 验证记录](diagnostics/open-link-0.7.6.md)。

**0.7.5** 长按首页操作行或右侧「⋮」后拖拽即可排序，拖到屏幕边缘会自动滚动；拖动时预览，松手保存，取消恢复原顺序。应用图标移除深色方形底，圆环外围、中心及扇区间隙透明。见 [0.7.5 验证记录](diagnostics/drag-sort-0.7.5.md)。

**0.7.4** 首页动作行新增「⋮」管理菜单，可上移、下移全部操作，也可编辑网站操作的名称、网址模板和图标。排序包含关闭的操作，圆环按保存顺序显示已启用项；编辑保留操作 ID、位置与启用状态。保留 0.7.3 的 PC 对应矢量图标、0.7.2 的豆瓣分类网址及既有圆环设置。见 [0.7.4 验证记录](diagnostics/action-management-0.7.4.md)。

**0.7.3** 操作图标改为与 PC 语义对应的矢量图形，包括地球、书、胶片、竖排书籍和纸飞机等，圆环与首页动作列表共用。每页 6、8、12、16 项分别使用 32、30、26、22 dp 图标，空间不足时等比缩小，不随系统字号缩放。Android 应用图标也改为 PC SVG 的八扇区圆环造型。豆瓣分类网址与已有操作设置保持不变。见 [0.7.3 验证记录](diagnostics/pc-icons-0.7.3.md)。

**0.7.2** 豆瓣读书、电影直接打开对应的官方分类搜索网页；豆瓣综合搜索继续优先打开 App，未安装或无法启动时回退官方网页。此策略替代 0.7.1 的分类搜索 App 优先策略，圆环外观与每页数量设置保持不变。见 [0.7.2 验证记录](diagnostics/douban-categories-0.7.2.md)。

**0.7.1（历史）** 普通圆环只显示图标，名称在滑动选中时显示于中心；首页「圆环氛围」可选择每页 **6、8、12、16** 项，与 PC 选项一致，默认仍为 8。所有入口共用设置，超出一页继续翻页。当时豆瓣读书、电影改为 App 搜索优先，App 内需手动切换分类；该分类策略已由 0.7.2 替代。见 [0.7.1 验证记录](diagnostics/menu-settings-0.7.1.md)。

**0.7.0** 补齐豆瓣读书、豆瓣电影、NeoDB 书影音、NeoDB 书籍、GitHub 和 Telegram 六个可选搜索；圆环按每页 8 项翻页，普通/GTA 模式统一尺寸与中心方向选择，并新增独立的「通用选文菜单兼容」开关。新搜索和新兼容开关默认关闭，升级保留原有设置。实现依据及验证边界见 [0.7.0 PC 功能对齐记录](diagnostics/pc-parity-0.7.0.md)。

默认开启与桌面版对应的 **GTA 氛围**：HUD 风格圆环、深色背景遮罩与松手交互。「圆环外观与触感」可以切回普通橙色圆环；设置会保存，并同时用于首页体验、选文/分享入口和自动弹出。

## 使用

1. 安装 APK，打开 ActionHalo。首页可以输入文字，点击「呼出圆环」体验。
2. 在支持的应用中长按选中文字，在系统选文菜单（可能位于「更多」中）选择 **ActionHalo**。也可以选择 **分享 → ActionHalo**。
3. 点击圆环图标可执行操作，首次点选不会移动圆环。每次打开后，第一次非分页触摸落在圆环内时保持原位，可直接点选或滑动；落在圆环外空白处时才把中心移到按下点，围绕该点滑动选择，松手执行，移回中心松手取消。后续触摸保持圆环位置固定，点击中心或圆环外缘再往外 32 dp 以外的空白处即可关闭；按住时超出外缘 32 dp 会取消高亮，松手关闭且不执行；滑回范围内可继续选择。重新打开后可再次首次定位。
4. 如需自动弹出，进入「触发与权限」开启该选项、阅读并同意权限说明，然后在系统无障碍设置中启用 **ActionHalo**。只有应用开关、同意状态和系统服务都开启才会监听选区。目标应用只公开选文菜单、未公开选区时，可另行开启下文的「通用选文菜单兼容」。

GTA 模式的选文/分享界面和自动弹出统一使用原生背景模糊、灰绿薄雾、上下渐变和径向暗角；背景柔化而圆环与文字保持清晰。Android 12+ 且系统允许时启用实时模糊，模糊启用时降低调暗强度；旧系统、不支持的设备或省电模式关闭模糊时自动保留较深的遮罩。初次显示时，自动选文圆环尽量避开选区首尾字符与手柄；应用不提供字符坐标时按控件位置避让。Telegram/通用菜单入口按已核对的复制菜单位置避让，手动入口居中显示。普通/GTA 模式在全部入口共用所选的 320、360、400、440 或 480 dp 尺寸上限（默认 400 dp）与相同圆环外径，初始布局按可用屏幕短边缩小，留出系统栏及 8 dp 边距；关闭 GTA 不再改变圆环大小。自动入口初次仅在圆环窗口内接收触摸，周围触摸交给原应用，可继续调整选区；触摸圆环后展开完整操作层。手动入口直接使用完整操作层。两种模式均保持：每次打开后，首次非分页触摸在圆环内保持原位，仅在圆环外空白处按下时整体移到手指位置，大小不变；该次触摸后，后续触摸、翻页、手势取消和操作失败重试均保持该中心，点击中心可关闭。边缘起手时部分圆环可能超出屏幕，向屏幕内滑动仍可选择。分页按钮保留原位点击行为。圆环外缘另留 32 dp 缓冲，缓冲内可继续选择；手指超出此范围时取消高亮，松手关闭且不执行操作，不论起手位置、滑动幅度或历史采样。按住滑回有效范围后恢复方向选择。完整操作层内的触摸不传给原应用，关闭后恢复正常操作。背景遮罩可在「圆环外观与触感」设为 0–80%，设为 0 时 GTA 暗角也完全透明；首次未设置时保留原有模式默认值。背景效果不截取其他应用画面；0% 遮罩只取消调暗与雾层，GTA 的原生模糊继续保留。

GTA 视觉与交互参照桌面源码：半透明黑色分区、带黑色柔影的白色图标、内侧 `01` 槽位编号；选中分区立即亮白并发光、图标放大 1.22 倍，中心显示重字动作名称与等宽 `SLOT 01 READY`。Android 12+ 的模糊由系统合成器实时处理，不做跨应用截图或应用内逐帧模糊；Android 8–11 保留薄雾和暗角回退。普通/GTA 模式都按圆环中心到手指的方向选择，中心保留 16 dp 死区，不必在外圈内触摸，最远可到圆环外缘以外 32 dp。滑动过程中不执行，松手才执行一次；回到中心取消，GTA 扇区缝隙不执行。第二根手指加入或系统取消手势时也不会触发动作。

默认操作：复制、Google 搜索、Google 翻译、打开链接、分享、百度搜索、豆瓣搜索。翻译打开 Google 翻译网页，默认目标语言随应用语言选择中文或英文。

「打开链接」与实际执行共用网址校验：支持 `http://`、`https://` 及 `example.com/path` 等裸域名，普通文字时灰显不可选。Telegram/通用选文菜单兼容入口在尚未获得实际选文时也保持禁用，不为判断网址而提前复制或读取剪贴板；手动复制后通过剪贴板入口取得文本，即可重新判断。

「豆瓣搜索」优先把选中文字直接交给豆瓣 App 的搜索结果页（`com.douban.frodo`），使用豆瓣[官方热搜接口](https://m.douban.com/rexxar/api/v2/chart/hot_search_board)提供的 `douban://douban.com/search/result?q=…` 路由；未安装 App 或系统拒绝启动时，改为官方网页搜索。关键词经过 URL 编码，不会改变路由。自定义网址仍仅接受 HTTP(S)。早期版本为满 8 项的菜单保存的豆瓣关闭状态，升级后仍保留。

六个新增搜索需在「操作管理」按需启用：豆瓣读书、豆瓣电影的默认模板直接打开与 PC 版相同的官方分类搜索网页，分别使用 `https://search.douban.com/book/subject_search?search_text=…` 和 `https://search.douban.com/movie/subject_search?search_text=…`；NeoDB 书影音使用综合搜索，NeoDB 书籍带书籍过滤条件；GitHub 打开网页搜索；Telegram 使用 `tg://search?query=…` 打开官方客户端搜索，不创建或发送消息。Telegram 依次尝试 `org.telegram.messenger` 和 `org.telegram.messenger.web`；均无法启动时提示不可用，不改为发送消息或其他未经选择的操作。没有验证第三方 Telegram 客户端。新增项目默认关闭，不会改变升级前已启用的操作或自定义网址。

使用综合「豆瓣搜索」时，刚安装的豆瓣 App 请先正常打开一次完成首次启动流程。Android 15 模拟器上的豆瓣 7.135.1 已验证可在「仅浏览模式」下从圆环进入带关键词的原生综合搜索结果页；这次测试中，未经首次初始化直接跳转会导致豆瓣自身退出。豆瓣读书、电影的分类网页搜索不需要安装或初始化豆瓣 App。

在「操作管理」启用或停用操作，不再限制启用总数；可在「圆环外观与触感 → 每页显示数量」选择 6、8、12、16 项，默认 8 项，点击圆环下方箭头翻页。可添加包含 `{text}` 的 HTTP(S) 网址，例如：

```text
https://github.com/search?q={text}
https://zh.wikipedia.org/w/index.php?search={text}
```

选中文字会作为 URL 参数编码。新建操作默认启用，超过一页的操作进入后续页面，不会挤掉现有操作。

在「操作管理」长按操作行或右侧「⋮」，拖到目标位置后松手即可排序；拖动到屏幕上下边缘会自动滚动。拖动中仅预览位置，松手才保存；取消或拖到列表外松手会恢复原顺序。每行的「⋮」也保留「上移」「下移」，可调整全部操作（包括关闭项）的顺序；首项不能上移，末项不能下移。圆环按保存顺序显示已启用的操作。

Google、百度、豆瓣读书、豆瓣电影、NeoDB 书影音、NeoDB 书籍、GitHub 和自定义网站操作的「⋮」中提供「编辑操作」。可修改名称、包含 `{text}` 的 HTTP(S) 网址模板，并从 10 种矢量图标中选择；选中文字会自动编码。编辑会保留操作 ID、列表位置与启用状态，不会把关闭项重新启用。取消或保存无效输入均不改变已有数据。自定义网站仍可在「⋮ → 删除」中删除，并保留二次确认。

复制、打开链接、分享、翻译、豆瓣综合 App 搜索和 Telegram 原生命令的名称及执行方式固定，与 PC 的核心操作限制保持一致；这些项目仍可排序、开启或关闭。

## 自动模式与兼容范围

如果首页能显示圆环，但在浏览器里选字后只有系统选文菜单：

1. 确认「触发与权限」中的「自动弹出圆环」和系统无障碍服务都已开启。
2. 进入「故障诊断」，点击「检查自动弹出」。它清零诊断计数，使用固定示例文字测试真正的无障碍浮层，与上方普通体验按钮不同。
3. 关闭示例圆环，到目标应用长按选字，再拖动手柄调整范围，返回「故障诊断」查看「收到选文事件」、非空范围计数、最近非空范围与最近结果。这可区分服务未连接、宿主没有提供选区信息、窗口变化和系统拒绝显示。

诊断仅在当前进程内保留计数、最近非空范围数字和结果类别，不记录选中文字、应用列表或浏览历史。系统选文菜单出现本身并不保证无障碍接口提供同一段选文；不支持时仍可通过「分享 → ActionHalo」或系统选文菜单中的 ActionHalo 手动打开。

0.4.0 修正了一种可复现的选区竞态：先刷新文字控件，再以控件当前范围判断选文，避免迟到的「选区已取消」事件误伤仍然有效的选择。真实折叠的控件仍会取消圆环；控件未提供范围时，保留对当前事件范围的回退。此修复通过受控的事件/控件范围不一致测试验证，尚不能据此宣称用户的 vivo X200s 故障已经修复，仍需该手机安装后确认。

如果**系统无障碍设置里的开关本身变成关闭**，先处理服务启用状态。[vivo 官方问答](https://www.vivo.com/qa/en/support/questionList?categoryId=54313)的“Why is the accessibility switch of the app always turned off automatically?”和“Accessibility is automatically disabled”将应用兼容性及耗电问题列为可能原因，建议允许后台高耗电、自启动，以及加入一键加速白名单。这些是排查建议，不代表已确认本应用在某台设备上的原因；官方国际站的菜单路径也不一定与当前 OriginOS 一致。

可先在系统设置搜索「后台耗电管理」或「后台高耗电」，为 ActionHalo 选择「允许」，重新开启无障碍后只按返回观察。若仍会关闭，再分别检查「自启动」和清理白名单，每次改一项后复测。区分「仅退出设置就关闭」「切换应用后关闭」和「清理后台或锁屏后关闭」，有助于继续定位。应用代码没有调用 `disableSelf()`，也不会写入系统无障碍启用名单。

本次 vivo V2458A / Android 16 的后续对照已确认前后台均正常，用户将触发点定位为**打开系统无障碍总列表**。因此本轮不再沿后台保活方向修改，0.5.2 改为减少应用主动进入该页面的次数，见下方说明。

- 使用 `AccessibilityService` 的选区事件和 `TYPE_ACCESSIBILITY_OVERLAY`，不需要 root 或普通悬浮窗权限。
- 自动模式要求目标控件公开选区信息；不同浏览器、聊天应用、自绘控件存在差异。无法读取选区时，可使用选文菜单或分享入口。系统选文菜单本身也取决于宿主应用支持；Android 11+ 的宿主若未声明第三方文本处理器的包可见性，菜单可能没有 ActionHalo，此时使用分享入口。
- 初次选中保持静默，同一控件调整范围后才自动弹出；按钮模式由用户点击打开。滚动、切换完整应用页面、关闭屏幕、选区取消或停用对应入口时移除圆环。临时小弹窗遮挡时保留最多 30 秒，恢复后重新核对选区；无法判断来源已关闭的小窗口遮挡也只限时等待。
- 跳过本应用、密码输入框及系统标记为敏感的节点。支持最长 32,768 个 UTF-16 code unit 的选文，超长内容不会静默截断。
- 自定义系统或侧载安装可能需要在应用信息中允许「受限制的设置」后，才能启用无障碍服务；请遵循设备上的系统提示。
- 这一版提供文本动作，不包含 macOS 的 Shell、AppleScript、键盘快捷键注入、文件定位、跨应用剪切/粘贴或 `.actionhaloext` 包导入。处理文本入口不回写宿主选区；复制后的文本可自行粘贴。

### 通用选文菜单兼容

0.7.0 新增独立的「通用选文菜单兼容」开关，新安装及升级均默认关闭，不自动扩大原有 Telegram 开关的范围。首页开启并同意说明后，系统无障碍服务已授权时即可使用；普通自动选区、Telegram 菜单和通用菜单可以分别开关。

此入口只识别前台应用提供的标准 Android 浮动选文菜单及其真实复制控件，检测阶段不读取正文。有选区变化事件时，初选保持静默，调整后显示圆环；仅提供可用复制菜单时直接显示圆环。长按节点上的范围不能代替实际选区事件，原生长按标记也不会抢占这条兼容入口。主动为应用设置「按钮模式」时，才显示「打开圆环」按钮。显示按钮或圆环均不复制、不读取文字；用户选定动作后才请求宿主复制准确选文，在可见且取得焦点的操作浮层中核对本次剪贴板，再执行动作。沿用限时等待、原来源核验、取消及旧剪贴板拒绝逻辑。

识别范围限于前台应用的同包子菜单窗口及标准容器 `android:id/floating_popup_container`，不扫描主页面或聊天正文、不做截图识字，也不监听后台剪贴板。自绘菜单、没有公开复制控件、系统/OEM 改造的菜单或屏幕识字界面可能无法识别；不能仅因为看见「复制」字样就保证可用。X、其他真实应用及 vivo 系统上的具体组合仍需实测。未识别时，可用分享入口、系统菜单中的 ActionHalo 或复制后的快捷按钮。

### Telegram 选文圆环

消息正文和底部输入框需要分别判断。对 Telegram 官方 12.10.6 对应源码的检查发现：消息长按先进入消息操作菜单；正文的部分文字选择由 Telegram 自行维护，所检查的实现没有向标准无障碍接口提供字符选区事件和范围，因此普通自动选文模式无法通过这条接口取得精确选文。底部输入框继承 Android `EditText`，保留了标准选区回调，不能用正文的限制解释输入框不弹。用户报告确认安装版本为 12.10.6。详见[固定版本源码与验证边界](diagnostics/telegram-compatibility.md)。

**0.6.1 将此功能改为「Telegram 选文圆环」**：识别菜单后直接显示圆环，选操作后才复制文字。新安装默认关闭，升级沿用 `telegram_copy_popup_enabled` 开关；旧版复制功能已开启，升级后也保持开启。可随时在「触发与权限」关闭。用户随后确认 0.6.1 已可使用；该反馈不等于已验证每种系统弹窗或所有应用，历史复现与模拟器证据仍保留在下文。

1. 在「触发与权限」开启「Telegram 选文圆环」，同意说明，并开启系统无障碍服务。
2. 回 Telegram，在消息正文中选好部分文字。正文没有提供选区变化事件时，识别到可用复制菜单便直接显示圆环，原选文手柄仍可调整。支持选区变化的控件则保持初选静默、调整后弹出。显示圆环不复制、不读取剪贴板；主动设置的按钮模式仍按按钮打开。
3. 在圆环中点击操作，或按住、滑动后松开。ActionHalo 才会请求 Telegram 复制准确选文，核对本次文字后执行已选操作。
4. 其他提示暂时打断时，待执行操作最多保留 30 秒；提示结束后继续，也可点击可见的「继续」或「取消」。切换其他应用、锁屏、关闭权限或超时会取消待执行操作。

菜单识别只检查前台官方 Telegram 包 `org.telegram.messenger` 和 `org.telegram.messenger.web` 的同包子窗口，不扫描聊天正文，不把整条消息朗读文本当成选文。识别使用系统复制标题及支持的中英文标题；自定义语言包、第三方客户端、没有公开复制控件的菜单或系统窗口限制仍可能影响使用。功能开启时，通过 `FLAG_INCLUDE_NOT_IMPORTANT_VIEWS` 读取 Telegram 默认排除在无障碍树外的菜单标题；用户选择圆环操作后才对已核对的真实 Copy 控件执行 `ACTION_CLICK`。

用户对 0.6.0 的真机反馈是菜单消失却没有圆环；诊断重复到达 `HELPER_SHOWN → HELPER_TAPPED → LAUNCH_REQUESTED`，没有 `FOCUSED`，服务仍连接。截图有系统翻译胶囊，但目前不能据此认定它抢占焦点就是根因。0.6.1 改用可见无障碍浮层完成待执行操作，Telegram 选文路径不再启动新的 Activity 打开圆环。原生 Copy 按钮仍可能缺少点击事件，不将此改动描述成修复了 Telegram 原按钮。

如果选文圆环没有出现，可在「触发与权限」点「添加快捷按钮」，把 **复制后圆环** 加入下拉快捷面板。此后在 Telegram 或其他应用正常复制文字，再下拉点击该按钮，即可显示圆环。这条路径无需无障碍服务，也可用首页「使用已复制文字」按钮验证。Android 13 及以上请求系统添加磁贴，较旧系统提供手动添加指引。

Telegram 圆环最初不取得焦点，用户选动作后才显示可取得焦点的操作浮层。只有浮层实际取得焦点时才读取剪贴板，时间戳须属于本次 Copy 操作，旧内容不会作为回退。读取成功后保留本次快照，不因失焦再读取；若首次读取为空，最多允许在真实恢复焦点时再读一次，不轮询、不后台监听。纯文件、多项或过长文本会拒绝处理，关闭后不保留文字。磁贴和首页手动入口仍使用前台窗口一次性读取。系统无障碍关闭时 Telegram 路径停止，快捷按钮仍可使用。

完整验证与边界见 [0.6.1 验证记录](diagnostics/telegram-copy-0.6.1.md)。使用 Android 15 / API 35 模拟器、真实窗口焦点与独立合成宿主，覆盖直接 GTA 圆环、准确选文、临时失焦、来源窗口遮挡、旧剪贴板拒绝与取消；这不能替代 vivo / Android 16 / 真实 Telegram 验证。

### 0.5.1：真机故障诊断

此版用于定位尚未在真机确认原因的 vivo 锁屏关闭与 Telegram 复制无反应问题，不宣称已修复这两项真机故障。补齐 Telegram 的工具条隐藏、取消动画、销毁顺序后，已在合成宿主复现“复制成功但没有点击事件”的失败边界；旧测试未覆盖该顺序。详见[复制事件丢失记录](diagnostics/telegram-copy-fixture/README.md)。

- 首页分别显示系统启用名单、系统服务列表与本进程连接；不会再仅因服务未列出而把授权当作关闭。
- 本机最多保存 12 条连接、解绑、销毁、锁屏与观察开关变化的类别/时间。Android 11+ 读取自身最近进程退出类别、时间与状态，不读取退出描述或堆栈。未得到信息时显示未知。
- Telegram 卡片显示收到的官方客户端点击次数、识别到复制次数、最近处理阶段。复制菜单未观察到、后台启动未获焦点、剪贴板核对失败会分别呈现；最多 8 个阶段仅保留在当前进程。
- 失败后回首页点「复制故障诊断」，可手动提供上述状态、机型、SDK、ActionHalo 与已支持官方 Telegram 的版本；无选文、剪贴板内容、聊天或设备标识，不自动发送。应用开关与诊断分开保存，升级不清除设置。
- 「后台运行设置帮助」提供 vivo 官方建议和标准系统设置入口，不自动调整授权或厂商设置。[无障碍生命周期证据及边界](diagnostics/accessibility-lifecycle.md)。

### 0.5.2：调整无障碍设置入口

- 同意自动弹出或 Telegram 复制功能时，如果系统授权已经开启，就留在首页；不再重复打开系统设置。
- 已授权时点击「管理无障碍权限」，先显示已开启状态；只有另点「打开系统总列表」才进入系统设置。缺少授权时仍使用公开系统入口，方便首次启用。
- 已实测 AOSP 详情直达入口要求普通应用拿不到的系统/安装器权限，因此没有采用隐藏深链。此版本减少重复进入总列表，尚不能修复手动打开 vivo 总列表后关闭的问题。已授权时可在首页查看启用状态与连接状态，无需再进入总列表检查。

此版保留现有 GTA 圆环与豆瓣搜索。Telegram 部分选文复制缺少点击事件的边界仍然存在，本次设置导航改动不解决该问题。[实现依据及测试边界](diagnostics/accessibility-lifecycle.md)。

## 隐私

无账号，不保存或记录收到的选中文字。应用联网用于用户主动检查公开更新；0.8.1 已移除 ML Kit、模型下载和 SDK 指标收集。保存动作配置、开关及最多 12 条本应用服务状态和时间；文字仅为本次操作在内存中处理。Telegram 与通用菜单圆环出现时不读取文字，用户选择动作后才操作真实复制控件，识别菜单时不扫描页面或聊天正文。文字操作窗口取得焦点后才读取本次剪贴板；成功后不再读取，首次为空仅在真实恢复焦点时允许第二次尝试，不监控后台剪贴板。只有用户明确选择搜索、网页翻译、自定义网址或分享时，文字才交给对应浏览器、网站或应用。自动选文、Telegram 选文圆环与通用选文菜单兼容可以分别关闭，手动入口继续可用。

无障碍能力为可选效率工具，声明 `isAccessibilityTool=false`。Google Play 发布前仍需按当时政策完成服务用途申报、披露与审核；当前交付为可安装的 debug APK。

## 构建与安装

需要 JDK 17、Android SDK Platform 36 / Build Tools 36.0.0。Gradle Wrapper 固定 9.3.1 并校验下载 SHA-256，Android Gradle Plugin 固定 9.0.1，使用其内置 Kotlin。

```bash
cd android
# 设置 JAVA_HOME 和 ANDROID_HOME，或在 local.properties 中填写 sdk.dir
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Android Studio 可直接打开本目录。一次构建只生成 `app/build/outputs/apk/debug/app-debug.apk`，交付文件命名为 `ActionHalo-0.9.1-debug.apk`，CI 同样只保留通用包。应用已没有架构相关原生库，无需分包。版本和签名延续现有安装，可覆盖升级。debug 签名仅用于开发与试用；正式发行需配置自行保管的 release 签名密钥。文件大小、校验值与验证范围见 [0.9.1 验证记录](diagnostics/action-app-scope-0.9.1.md)。

连接测试手机或启动 Android 模拟器后：

```bash
./gradlew :app:connectedDebugAndroidTest
```

JVM 测试覆盖 URL 编码和协议限制、选文长度边界、普通/GTA 圆环命中、微死区与远距离方向选择；设备测试覆盖选文/分享入口、复制、圆环外起手、拖动与取消、多指中断、实时中心提示、GTA 设置持久化、首页启动和动作配置。自动模式还应在计划支持的真实应用与厂商系统上逐项验证。

另有仅限模拟器、需要显式启用的[真实长按诊断测试](diagnostics/README.md)，覆盖键盘打开后的准确复制、锁屏清理与解锁后新选文、无障碍断开与重连。GitHub Actions 已配置 API 26–36（Android 8–16）逐版本设备回归，并保存测试报告；见[本机实测结果、跳过项与品牌真机边界](diagnostics/compatibility-regression.md)。配置矩阵不代表所有 CI 任务或品牌真机都已经通过。

## 目录

- `MainActivity.kt`：体验入口、动作管理、权限说明与自动模式设置。
- `HaloActivity.kt`：系统选文和分享入口。
- `ClipboardHaloActivity.kt` / `ClipboardTileService.kt`：前台一次性读取复制文字、下拉快捷入口。
- `TelegramCopyAssistant.kt`：识别前台 Telegram 部分选文菜单或已启用的标准选文菜单，初次提供小按钮，选区调整或主动打开后显示圆环；选择动作后执行真实复制控件。
- `ClipboardHaloOverlay.kt`：可见的文字操作浮层、取得焦点后的剪贴板核对与待执行动作恢复。
- `TelegramCopyPolicy.kt`：Telegram 复制按钮识别及事件/剪贴板时效检查。
- `RadialMenuView.kt` / `RadialGeometry.kt`：圆环绘制、触摸和无障碍按钮。
- `HaloAppearance.kt`：共享外观设置、系统模糊生命周期、背景调暗与暗角。
- `SelectionAccessibilityService.kt`：可选的跨应用选区监听。
- `HaloAction.kt` / `ActionStore.kt` / `ActionExecutor.kt`：动作定义、配置保存与执行。

## English

Version **0.9.1** adds per-action active app scopes: All apps, Only selected apps, or All except selected apps. Configure them from an action’s overflow menu. Scopes filter the source app, take precedence over per-app action lists, and are included in backups and undo. Only-selected actions are hidden when the source cannot be reliably identified. Existing settings default to All apps.

Version **0.9.0** adds per-app trigger modes and ordered action profiles, keyboard-aware initial placement, recovery shortcuts and inline action errors, configuration backup, a pinned live appearance preview, preferred destinations, temporary pause controls and a Quick Settings tile, an optional text editor, and undo for destructive settings changes. The universal APK still supports Android 8+. See the [implementation and verification record](diagnostics/experience-0.9.0.md).

Version **0.8.5** uses Android 12+ native cross-window blur for GTA mode, with softer dimming and a muted haze. The wheel stays sharp. System blur changes are observed while the window is visible, falling back to shading when unavailable; ordinary mode remains unblurred. Normal actions keep the intermediate Continue/Cancel card hidden, revealing it only for a sustained blocked request. See the [0.8.5 verification record](diagnostics/gta-blur-0.8.5.md).

Version **0.8.4** follows the desktop GTA rendering: vertical shading and a radial vignette, translucent black sectors, white icons with cached black shadows, immediate white selection glow, a heavy center title and a monospaced HUD. Dense 12/16-action wheels use the desktop gap angle. Android approximates the macOS frosted composition with native gradients and cached shadows, without screen capture or per-frame blurring. See the [0.8.4 comparison and verification record](diagnostics/gta-pc-0.8.4.md).

Version **0.8.3** bounds action selection to the visible wheel plus a density-scaled 32 dp buffer. Moving beyond it clears the preview; releasing there closes without executing. Moving back within the limit restores selection. First-touch anchoring and stationary icon taps retain the 0.8.2 behavior. See the [0.8.3 verification record](diagnostics/selection-limit-0.8.3.md).

Version **0.8.2** keeps the wheel in place when the first non-pager press lands inside it, including direct icon taps and held selections. Only a first press in blank space outside the wheel moves its center under the finger. That first press fixes the center for later gestures, cancellation, paging and retries. See the [0.8.2 verification record](diagnostics/direct-tap-0.8.2.md).

Version **0.8.1** removes the floating translator, language identification and ML Kit dependencies. Google Translate opens in the browser after an explicit action choice. The text-menu, share, accessibility and Copy-menu paths reuse the existing URL executor. Opening the upgraded app removes obsolete downloaded translation models in the background while preserving action and appearance settings. There are no native libraries left, so builds produce a single universal APK of about 1.05 MB. See the [0.8.1 verification record](diagnostics/remove-floating-translation-0.8.1.md).

Version 0.8.0 introduced separate Home, Actions, Appearance, Triggers, Diagnostics and About pages, five halo sizes, 0–80% dimming, shared haptics and appearance reset. These remain available. About checks public GitHub Android APK releases manually, keeps debug/release channels separate and opens downloads in the browser.

Native Android 8.0+ edition, version **0.8.7**. Select text in a supported app and choose **ActionHalo** from the selection menu, or share plain text to it. The first non-pager touch keeps the wheel in place when inside it; only a first touch outside the wheel moves its center under the finger. Later touches keep the center fixed. Move around it to select and release to execute; tap or return to the center before release to dismiss. After the first non-pager touch, a stationary touch more than 32 dp beyond the visible outer edge dismisses on release. Moving more than 32 dp beyond the visible outer edge clears the action preview; releasing there closes without executing. Moving back within this limit restores selection. Reopening allows a new first-touch anchor. Home offers a text playground and navigation. Manage action toggles and custom HTTP(S) URL templates containing `{text}` under Actions. Enabled actions are no longer capped at eight: choose 6, 8, 12 or 16 per page under Appearance (default eight), with paging arrows below. Standard mode shows icons only; dragging over an action reveals its full title in the center. New custom actions are enabled and added to later pages when needed. See the [0.7.0 PC parity record](diagnostics/pc-parity-0.7.0.md).

Android 8.0+ builds provide one universal APK, including for vivo X200s. Per-ABI packages are no longer produced because the native translation libraries have been removed. Installation eligibility does not establish automatic-selection compatibility with every OEM or source app; see the [compatibility regression record](diagnostics/compatibility-regression.md) for tested emulators and exclusions. The selection-menu, share and Quick Settings entries remain available as alternatives.

Version 0.7.12 recognizes framework menu-item IDs when older selection toolbars omit the newer container ID. Discovery still requires a same-package child window attached to the foreground source and one unambiguous Copy command. The existing opt-in standard-menu mode also covers legacy WebViews that publish no usable selection range. The CI matrix covers API 26–36; configuration alone does not establish that every matrix job or physical OEM device has passed.

Version 0.7.6 enables **Open link** only for known text accepted by the existing HTTP(S) URL normalizer, including bare domains. Other text and unknown selections leave the sector dimmed and unavailable to clicks, dragging and keyboard focus. Telegram and standard-menu compatibility surfaces do not copy or read text just to determine availability; manually opening the clipboard entry provides known text for validation.

Version 0.7.5 supports long-press dragging on action rows or their **⋮** buttons, with automatic scrolling near the screen edges. Moving previews the order; dropping inside the list saves it, while cancellation restores it. The app icon now has a transparent background outside, between and inside its ring sectors.

Version 0.7.4 adds a **⋮** menu to each home action row. Use **Move up** or **Move down** to reorder all actions, including disabled ones; the first and last rows enforce their respective boundaries. The saved order determines the order of enabled actions in the wheel.

**Edit action** is available for Google, Baidu, Douban Book, Douban Movie, NeoDB Search, NeoDB Books, GitHub and custom websites. Change the name, an HTTP(S) URL template containing `{text}`, and one of 10 vector icons. Selected text is encoded automatically. Editing preserves the action ID, position and enabled state. Cancelling or entering invalid data does not change the saved configuration. Custom websites retain **⋮ → Delete** with confirmation.

Copy, Open link, Share, Translate, general Douban app search and native Telegram search remain fixed actions, following the desktop restrictions for core operations. They can still be reordered, enabled or disabled. Version 0.7.4 preserves the vector icons introduced in 0.7.3, the default Douban category URLs from 0.7.2 and existing wheel preferences.

Version 0.7.3 replaces text glyphs with vector icons matching the desktop action meanings, shared by the wheel and home action list. Icons use 32, 30, 26 or 22 dp for 6, 8, 12 or 16 items per page, shrinking to fit available space independently of system font scaling. The Android app icon now uses the desktop SVG's eight-sector wheel design. Douban category URLs and existing action preferences are preserved.

The built-in **Douban search** opens the selected query in the Douban Android app, with official web search as a fallback. Existing full menus keep their enabled actions when upgrading.

Six additional searches are optional and disabled by default: **Douban Book, Douban Movie, NeoDB Search, NeoDB Books, GitHub Search and Telegram Search**. The default Douban Book and Movie templates directly open the same official category search pages used on desktop, preserving the book or movie category. Version 0.7.2 replaces the app-first category strategy introduced in 0.7.1; general Douban search remains app-first, falling back to the official website if the app is missing or cannot launch. NeoDB Books adds the book category filter. Telegram opens a search query in either official Android distribution, trying the second package if the first is unavailable or blocked. It does not compose or send a message; if neither package opens, it reports that search is unavailable without substituting a message or another action. Existing action preferences and custom URLs are preserved.

**Standard selection menu compatibility** is a separate opt-in, disabled for both new and upgraded installations. After consent and accessibility authorization, a supported Copy menu shows the wheel directly when selection-change events are unavailable. Where those events are exposed, the initial selection stays quiet and adjusting it opens the wheel. A readable range on a long-click node alone does not prove event support. Open halo buttons appear only in explicitly chosen per-app button mode. Choosing an action invokes the verified Copy control; a visible focused overlay then validates the new clipboard text before executing. Detection only inspects same-package child menu windows with the standard container, never the main page or message body. It does not perform OCR or monitor the clipboard. Custom menus, OEM changes and unpublished Copy controls may remain unsupported. This does not establish compatibility with X, every real app or every vivo configuration; share and manual clipboard entry remain available.

Version 0.6.1 changed this feature to **Telegram selection halo**, off for new installations and preserving the previous preference on upgrade. Version 0.11.2 restores the direct wheel for recognized menus without selection-change events. Where those events are exposed, the initial selection stays quiet and adjusting it opens the wheel. Only an explicitly chosen per-app button mode offers Open halo. Neither control copies or reads text before an action is chosen. Choosing an action then invokes Telegram’s real Copy control. A visible accessibility overlay takes focus, checks the clipboard timestamp against this Copy operation, and executes the chosen action without launching another Activity to display the halo. Menu detection does not scan message bodies.

A pending action can survive a temporary interruption for up to 30 seconds, with visible Continue and Cancel controls. A successfully read snapshot is retained without rereading; an empty read allows at most one further attempt on a real focus regain, never polling. Replacing the source with a full-screen app, locking the screen, disabling access or timing out cancels the request. Small modal windows may temporarily hide the source from the accessibility window list; the action waits and revalidates the original source when it returns. See the [0.6.1 validation record](diagnostics/telegram-copy-0.6.1.md) for framework, production-window and synthetic-host checks. The user reported a 0.6.0 failure after the launch request but before a focus callback, then confirmed that 0.6.1 worked. That confirmation does not establish compatibility with every system interruption. A visible system translation capsule does not prove the cause of the earlier failure.

The **Copied text halo** Quick Settings tile remains a manual entry without accessibility access: copy text normally, then tap the tile. Neither service monitors or reads the clipboard in the background. The accessibility settings flow retains version 0.5.2 behavior: granting an in-app option while already authorized stays on the home screen, and opening settings while authorized first shows a status dialog. This does not fix permission loss after manually entering vivo’s accessibility list.

If automatic selection does not work, open Diagnostics and use **Check automatic display** resets diagnostic counters and tests the actual accessibility overlay using example text. The launcher distinguishes access enabled from a connected service and shows process-local event counts, the latest nonempty range numbers, and result categories without retaining text or browsing history. A browser's native selection toolbar does not by itself guarantee usable accessibility selection data. Version 0.4.0 refreshes the source before deciding whether a selection is collapsed, preventing a stale event from discarding a fresh nonempty range. Real cancellations still dismiss the overlay.

**GTA mode is on by default**, with a HUD-style wheel and a hazy backdrop, blurred in real time on supported systems. Switch it off under “Appearance” to restore the orange halo. The preference is saved and shared across every entry point. Both styles share the selected 320, 360, 400, 440 or 480 dp menu cap (400 by default) and outer wheel radius, initially fitted to the available screen with system-bar clearance and an 8 dp margin. Version 0.7.9 gives GTA slot numbers and icons separate radial bands, fitting the icons against the actual font height and their 1.22 selected scale to keep them apart. Version 0.8.2 keeps the wheel in place for a first press inside it and moves its center only for a first non-pager press outside it. Later presses, paging, cancelled gestures and external-action retries keep that center fixed. The wheel may clip at screen edges rather than shift away from the finger. Short taps on visible action icons still execute, while pager presses retain their original behavior. A drag executes only on release; the 16 dp center deadzone, disabled actions, GTA sector gaps and interrupted gestures remain non-executing. Manual entries use a full-screen touch surface. Since 0.8.7, the first long-press selection stays quiet and a changed range triggers the automatic circle. Since 0.11.2, menu-only apps show the wheel directly for a supported Copy menu; initial silence remains for controls with selection-change events. Open halo buttons appear only in explicitly chosen per-app button mode. Automatic circles still use the bounded nonmodal window introduced in 0.8.6 so the original selection handles remain available; touching the wheel expands the action surface and activates GTA background effects. Version 0.8.3 bounds selection to a 32 dp buffer beyond the visible outer edge: moving farther out clears the preview, and releasing there dismisses without executing. Moving back inside restores selection, including short movements across the boundary. Tap the center to close as before; closing returns control to the underlying app. Both styles use the selected 0–80% dimming; at 0%, the GTA vignette is also transparent. Unset dimming preserves the original mode defaults. System bars remain controlled by Android. Live blur requires Android 12+ and system support; older or disabled systems retain a shaded fallback. At 0% dimming, native GTA blur remains enabled. No cross-app screenshots are taken.

Automatic selection, Telegram menu detection and standard-menu compatibility are separately optional and require their respective in-app consent plus the Android accessibility service. The selection-event path requires exposed text selection; the menu paths require a supported Copy control. Selected text is not stored or logged; external actions only send it after an explicit user choice. Web translation sends selected text to the translation website only when explicitly selected. Local translation, model downloads and the ML Kit SDK have been removed. Internet permission remains for manual update checks. Desktop scripts and plugin package imports remain unsupported.

Build with JDK 17 and Android SDK 36 using the commands above. Unit tests and Lint run locally and in the dedicated Android CI workflow. Run instrumented tests with a connected device or emulator.
