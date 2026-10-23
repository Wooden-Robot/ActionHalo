# Android Telegram 搜索入口

核验日期：2026-10-10。使用 Telegram 官方仓库固定提交
[`f2908b14133bbffbf7ab04f641ecb5bfaf533242`](https://github.com/DrKLO/Telegram/commit/f2908b14133bbffbf7ab04f641ecb5bfaf533242)，
该提交的 [gradle.properties](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/gradle.properties#L19)
声明版本 12.10.6（7112），与用户报告的 Telegram 版本一致。

## 可用路由

`ACTION_VIEW` 打开 `tg://search?query=<经过一次 UTF-8 URL 编码的关键词>`，并显式指定
`org.telegram.messenger` 或 `org.telegram.messenger.web`。保留关键词中的中文、emoji、换行、百分号、加号；不拼接未经编码的选文。

官方代码依据：

- [LaunchActivity 解析 search/query](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/LaunchActivity.java#L2631)。Telegram 自身会 trim 关键词首尾空白。
- [将关键词交给主会话列表搜索](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/LaunchActivity.java#L2960)。
- [从聊天页切回主列表](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/LaunchActivity.java#L3054)，以及[初始化搜索文本](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/LaunchActivity.java#L3305)。
- [Manifest 导出 Activity 并注册 tg URI](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/AndroidManifest.xml#L211)。

该入口不修改剪贴板，不模拟输入，不使用分享/消息草稿深链，也不发送消息。无需借用无障碍权限填写 Telegram 的搜索框。

## 与 PC 的差异和边界

本仓库 macOS 端使用 `tg://chats/search` 后检查搜索框并输入文字。
[官方通用深链文档](https://core.telegram.org/api/links#chat-list-links)也列出这个打开全局搜索的入口，
但没有给出关键词参数；核验的 Android 12.10.6 `LaunchActivity` 未实现此路径，而是实现上面的 `tg://search?query=`。
该 Activity 和 Manifest 同样未发现 `ACTION_SEARCH` 处理，不将它当作兼容入口。

Android 尝试第一个官方包失败时可尝试第二个；两者均不可用时明确提示无法打开 Telegram。
不把关键词自动改投网页搜索，不通过 `tg://resolve?...&text=` 之类的消息草稿入口代替搜索。

`startActivity` 返回只说明系统接受了打开请求。Telegram 未登录时会进入登录流程，锁定时会先显示密码页；
搜索内容和结果仍由 Telegram 决定，ActionHalo 不据此声称已经取得搜索结果。
这里的证据是官方 12.10.6 源码和本地 URI 边界测试，尚未验证已登录的 Telegram 真机行为。
