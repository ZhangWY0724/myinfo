# AiKaid

一个基于原生 `HTML/CSS/JavaScript` 与 `WebGL` 的个人主页项目。

页面以全屏流体动效为背景，展示个人品牌信息，并提供几个常用项目入口链接。项目为纯静态结构，无构建步骤，适合直接部署到静态站点服务。

## 二开说明

本项目基于现有流体动效主页做了二次开发，保留原有的单页展示形态，并补充了更贴近个人站点运营的内容：

- 增加备案号展示，满足站点合规信息露出需求
- 增加公安备案图标展示，按要求放置在公安备案编号之前
- 增加子网站穿透入口，用主页统一承接各个子站访问
- 调整页脚信息与项目链接，作为个人站点导航首页使用

## 功能特点

- 全屏 `WebGL` 流体交互背景
- 简洁的个人主页文案展示
- 页脚集成外部项目导航入口
- 响应式布局，兼容桌面端与移动端

## 项目结构

```text
.
├─ index.html        # 页面入口
└─ assets
   ├─ 1774427150840_d.png # 公安备案图标
   ├─ script.js      # WebGL 动效脚本
   ├─ dat.gui.min.js # 调试依赖
   └─ LDR_LLL1_0.png # 动效资源
```

## 本地运行

由于是静态页面，直接打开 `index.html` 即可预览。

如果你更希望通过本地服务访问，也可以使用任意静态服务器，例如：

```powershell
python -m http.server 8080
```

然后访问 `http://localhost:8080`。

## 安全排查脚本

仓库内附带了一个 Windows PowerShell 自查脚本，可用于排查本机 `Apifox` 是否残留与公开 IOC 相关的本地痕迹。

执行方式：

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\Check-ApifoxCompromise.ps1"
```

脚本会扫描以下内容：

- `AppData\Roaming\apifox\Local Storage\leveldb` 中的 `_rl_headers`、`_rl_mc`、`common.accessToken`
- `Apifox` 用户数据目录下的 `state` / `Preferences` / `Network` 类文件
- `%USERPROFILE%\.ssh` 文件清单
- `APIFOX` 与 `TASKLIST` 的 `Prefetch` 记录

执行完成后，脚本会在当前目录生成一份文本报告。

## 部署建议

可直接部署到 `GitHub Pages`、`Vercel`、`Netlify` 或任意支持静态资源托管的平台。
