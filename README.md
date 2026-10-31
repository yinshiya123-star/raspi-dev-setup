# raspi-dev-setup

树莓派开发环境一键安装脚本，以及讲述它诞生经过的短片《再加一键》。

> **状态：** 脚本还没有在真实的树莓派上运行过。已做的检查只有语法检查，以及用模拟接口测试节点切换和订阅导入逻辑。

## 安装内容

- 美国时区（默认 `America/Los_Angeles`）
- Git、VS Code
- C++（`g++`、`gdb`、`cmake`、`ninja`、`clang`）、Python 3、Java（OpenJDK、Maven）
- Clash Verge Rev、Claude Code、Claude Desktop（Linux 版为 beta）、Pi-Apps 应用商店
- `us_on` 和 `clash-us`：一键切换到全局模式和延迟最低的美国节点

## 要求

- 64 位 Raspberry Pi OS（Bookworm 或更新版本），建议桌面版
- 用普通用户运行，不要加 `sudo`

## 用法

```bash
chmod +x raspi-dev-setup.sh
./raspi-dev-setup.sh
```

脚本开始时会提示粘贴 Clash 订阅链接，可留空跳过。链接保存在 `~/.config/clash-us/subscription`，权限为 600。**不要把订阅链接提交到仓库。**

| 选项 | 作用 |
| --- | --- |
| `--timezone <时区>` | 指定时区，例如 `America/New_York` |
| `--proxy <地址>` | 安装过程使用的代理 |
| `--clash-deb <路径>` | 使用本地的 Clash Verge `.deb` |
| `--sub-file <路径>` | 从文件读取订阅链接 |

安装后在树莓派桌面的终端中运行：

```bash
source ~/.bashrc
us_on
```

| 命令 | 作用 |
| --- | --- |
| `us_on` | 启动 Clash、按需导入订阅、切到美国节点，并让当前终端走代理 |
| `clash-us --list` | 查看美国节点和延迟 |
| `clash-us --rule` | 恢复规则模式 |
| `proxy_off` | 当前终端不再走代理 |

## 已知限制

- Clash Verge、VS Code、Claude Desktop 和 Pi-Apps 都是图形程序，需要桌面环境。
- Claude Desktop 官方只正式支持 Ubuntu 和 Debian，Raspberry Pi OS 未经官方测试。
- 美国节点按名称识别，`clash-us` 会查询 ipinfo.io 确认实际出口国家。
- 如果 Clash Verge 里已有配置，导入的新订阅不会自动启用，需要在“配置”页选中。
- 代理和时区不会改变 Anthropic 对账号地区的要求，请先确认所在地区在官方支持范围内。

## 短片《再加一键》

72 秒的剪纸风动画，内容取自写这个脚本的真实经过，个别情节的先后有改编。

- [film/zaijia-yijian.mp4](film/zaijia-yijian.mp4)：视频文件
- [film/zaijia-yijian.html](film/zaijia-yijian.html)：可交互的网页原版，下载后用浏览器打开（需联网加载字体）
