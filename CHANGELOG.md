# Changelog

## v0.1.0
- 新增 GitHub Releases 更新检测，发现新版本弹窗提示并提供下载/跳转。
- 菜单新增“检查更新…”与“自动检查更新”开关（默认开启）。
- 手动检查支持“已是最新版本”和更友好的网络错误提示，失败可重试。
- 新增 UpdateChecker 相关测试。

- Added GitHub Releases update checking with prompts and download/open link.
- Added “Check for Updates...” and “Auto Check Updates” toggle in the menu (default on).
- Manual checks show “Up to date” and friendlier network error messages with retry.
- Added UpdateChecker tests.
 
## v0.1.1
- 修复更新检查请求指向错误仓库导致的解析失败问题。
- 当服务器响应非 200 时给出更明确的错误提示。

- Fix update check failing due to incorrect repository owner.
- Show clearer error when server response is not 200.
