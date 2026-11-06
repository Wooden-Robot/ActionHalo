# 0.6.0 Telegram 复制助手验证记录

日期：2026-10-10。环境为 Android 15 / API 35 临时模拟器，宿主是明确标注为 Telegram copy fixture 的独立合成应用，无账户、无聊天数据。这里记录的是模拟器结果，没有在用户 vivo X200s 或真实 Telegram 中验证。

## 最终合成宿主结果

| 场景 | 观察结果 | 本机证据 |
| --- | --- | --- |
| `animator-copy`，动画比例 1 | 用户点助手后 `copy_calls=1`、`writes=1`，完整工具条销毁后 GTA 圆环稳定显示 | [事件](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-scale1/events.log)、[截图](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-scale1/screen-after.png) |
| `animator-copy`，动画比例 0 | `copy_calls=1`、`writes=1`，圆环稳定显示 | [事件](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-scale0/events.log)、[Activity](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-scale0/activity-after.txt) |
| `nonfocusable` 原生事件对照 | 助手请求保留为 `TELEGRAM_COPY_ASSISTED`，没有被随后原生 Copy 事件覆盖 | [事件](../build/diagnostics/telegram-copy-0.6.0/final-nonfocusable-scale1/events.log)、[Activity](../build/diagnostics/telegram-copy-0.6.0/final-nonfocusable-scale1/activity-after.txt) |
| `animator-copy-no-write` | Copy 调用不写剪贴板，`writes=0`，没有圆环并返回 fixture | [事件](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-no-write-scale1/events.log)、[截图](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-no-write-scale1/screen-after.png) |
| `animator-copy-menu-stale` | 菜单打开后预置旧内容，本次 Copy 不写入，`writes=0`，没有圆环并返回 fixture | [事件](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-menu-stale-scale1/events.log)、[截图](../build/diagnostics/telegram-copy-0.6.0/final-animator-copy-menu-stale-scale1/screen-after.png) |

菜单交互检查也通过：Translate 不触发复制圆环；点菜单外取消后助手消失；点“×”后当前菜单持续保持收起，新菜单可再次显示助手；切换应用移除助手；未知标题不显示助手。相关状态记录：[Translate](../build/diagnostics/telegram-copy-0.6.0/menu-cleanup/translate.txt)、[外部取消](../build/diagnostics/telegram-copy-0.6.0/menu-cleanup/outside-cancel.txt)、[收起](../build/diagnostics/telegram-copy-0.6.0/menu-cleanup/dismiss-x.txt)、[保持收起](../build/diagnostics/telegram-copy-0.6.0/menu-cleanup/dismiss-stays-hidden.txt)、[切换应用](../build/diagnostics/telegram-copy-0.6.0/menu-cleanup/switch-app.txt)、[未知标题](../build/diagnostics/telegram-copy-0.6.0/menu-cleanup/unknown-label.txt)。

早前在 GTA 圆环中点击 Copy，再返回宿主核对剪贴板的手动往返验证得到 `exact_selected_fragment=true`，见 [manual-exact-roundtrip.log](../build/diagnostics/telegram-copy-0.6.0/manual-exact-roundtrip.log)。

## 旧任务复用问题与修正

负例测试发现，内部 `ClipboardHaloActivity` 只使用 `NEW_TASK` 时可能复用旧圆环任务，使界面显示此前请求的文字；[修正前 no-write 记录](../build/diagnostics/telegram-copy-0.6.0/helper-animator-copy-no-write-scale1/activity-after.txt)保留了当时的 Activity 状态。现统一内部请求使用 `NEW_TASK | CLEAR_TASK`，替换旧任务并重新处理本次请求。修正后重新运行上表两个负例，均拒绝旧剪贴板，返回 fixture，没有显示圆环。

## 其他验证与边界

42 项 JVM 单元测试通过；Lint 0 错误、5 项原有警告。设备回归最终覆盖 29 项通过，6 项另需参数启用的选文诊断未运行：剪贴板 8 项、GTA 7 项、豆瓣 3 项、集成 5 项、权限导航 6 项。

首轮整套运行的第一个权限导航测试及其清理失败：启动 instrumentation 杀掉原进程后，系统把此前已启用的测试服务保留在 crashed 列表，写回相同名单不会重新绑定。测试现先保存原状态，再停用自身测试组件并等待系统移除，由各用例重新启用；生产代码没有为此修改。其余设备用例通过；修正初始化后单独重跑 6 项导航全部通过。见 [首轮记录](../build/diagnostics/telegram-copy-0.6.0/instrumentation.txt)和[导航重跑](../build/diagnostics/telegram-copy-0.6.0/navigation-final.txt)。这不解释或修复 vivo 手动进入无障碍总列表后关闭的问题。

安装包为 `android/build/ActionHalo-0.6.0-debug.apk`，versionCode 8，minSdk 26，targetSdk 36，与此前版本使用相同调试签名。SHA-256：`4ac54a30381084d21df134842d3d6911ba57c61485d46369777c7f935070b7ab`。`build/` 下是本机生成的安装包及证据文件，不保证随源码分发。

原生 Copy 按钮的事件缺失仍然存在；这里验证的是用户点击新增“复制并弹出”（英文 `Copy + halo`）后的独立路径。结果不能用于宣称 vivo 服务自动关闭已修复，也不能宣称真实 Telegram 已通过。更多范围说明见 [Telegram 兼容性核对](telegram-compatibility.md)。
