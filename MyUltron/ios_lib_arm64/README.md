# ios_lib_arm64 — libimobiledevice 静态库与头文件

为 arm64 iOS 交叉编译的 libimobiledevice 生态库，提供与 iOS 设备通信的完整 C API。

## 结构概览

```
ios_lib_arm64/
├── lib/
│   ├── libimobiledevice.a       # 主库 — iOS 设备通信协议
│   ├── libimobiledevice-glue.a  # 工具库 — socket/thread/collection/sha 等
│   ├── libplist.a               # plist 序列化/反序列化（Apple 二进制 plist）
│   ├── libusbmuxd.a             # USB multiplexing daemon 通信
│   ├── libssl.a                 # OpenSSL SSL/TLS
│   └── libcrypto.a              # OpenSSL 加密
└── include/
    ├── libimobiledevice/        # 25 个服务模块头文件
    ├── libimobiledevice-glue/   # 底层工具头文件
    ├── plist/                   # plist 数据结构（Node/Array/Dict/Data/Date 等）
    └── openssl/                 # OpenSSL 头文件
```

## 核心库：libimobiledevice（25 个服务模块）

| 模块 | 服务名 | 功能 |
|------|--------|------|
| **libimobiledevice** | — | 设备发现、连接建立、SSL、原始数据收发 |
| **lockdown** | `com.apple.mobile.lockdown` | 配对验证、会话管理、启动其他服务（核心入口） |
| **afc** | `com.apple.afc` | 设备文件系统读写（目录列表、文件打开/读/写/删/改名/截断） |
| **installation_proxy** | `com.apple.mobile.installation_proxy` | App 安装/卸载/升级/归档/恢复、已装应用浏览、bundle path 查询 |
| **screenshotr** | `com.apple.mobile.screenshotr` | 获取设备截屏（返回 TIFF 数据，需挂载开发者镜像） |
| **debugserver** | `com.apple.debugserver` | 远程调试（LLDB 通信），支持启动 app、设置环境变量、发送调试命令 |
| **diagnostics_relay** | `com.apple.mobile.diagnostics_relay` | 诊断信息获取（WiFi/GasGauge/NAND）、重启/关机、查询 MobileGestalt/IORegistry |
| **mobilebackup2** | `com.apple.mobilebackup2` | iOS 4+ 全量备份/恢复（DL 消息协议、版本协商、原始数据传输） |
| **mobilebackup** | `com.apple.mobilebackup` | 旧版备份/恢复 |
| **syslog_relay** | `com.apple.syslog_relay` | 实时抓取设备 syslog 输出（字符回调流式接收） |
| **heartbeat** | `com.apple.mobile.heartbeat` | 心跳保活，允许通过 WiFi 维持服务连接 |
| **house_arrest** | `com.apple.mobile.house_arrest` | 访问指定 App 的沙盒目录（VendContainer/VendDocuments → 返回 AFC 客户端） |
| **webinspector** | `com.apple.webinspector` | Safari WebKit 远程调试（plist 协议收发） |
| **sbservices** | `com.apple.springboardservices` | SpringBoard 管理 — 图标布局获取/设置、App 图标 PNG、壁纸 PNG、屏幕方向 |
| **notification_proxy** | `com.apple.mobile.notification_proxy` | 系统通知收发（设备名变更、App 安装/卸载、同步状态等，支持异步回调） |
| **mobile_image_mounter** | `com.apple.mobile.mobile_image_mounter` | 挂载开发者磁盘镜像（DeveloperDiskImage），截图等服务的前置条件 |
| **mobilesync** | — | 数据同步（通讯录、日历等） |
| **misagent** | — | 安装/移除 Provisioning Profile |
| **mobileactivation** | — | 设备激活/反激活 |
| **preboard** | — | 预启动服务 |
| **companion_proxy** | — | Companion Link 代理 |
| **file_relay** | — | 批量文件收集（如崩溃日志） |
| **restore** | — | 恢复模式通信 |
| **service** | — | 底层服务抽象 |
| **property_list_service** | — | 基于 plist 的服务通信基类 |

## 辅助库：libimobiledevice-glue

| 模块 | 功能 |
|------|------|
| `socket.h` | 跨平台 socket 抽象 |
| `thread.h` | 线程创建/管理 |
| `collection.h` | 动态数组/哈希表 |
| `sha.h` | SHA-1/224/256/384/512 |
| `tlv.h` | Type-Length-Value 编解码 |
| `nskeyedarchive.h` | NSKeyedArchiver 格式解析 |
| `opack.h` | opack 编码格式 |
| `cbuf.h` | 环形缓冲区 |
| `termcolors.h` | 终端颜色 |
| `utils.h` | 通用工具函数 |

## 典型使用链路

以截屏为例的调用链：

```
lockdownd_client_new_with_handshake()   // 配对 + 建立加密会话
  → lockdownd_start_service("com.apple.mobile.screenshotr")
    → screenshotr_client_new()
      → screenshotr_take_screenshot()   // 返回 TIFF 数据
```

`mobile_image_mounter` 是截图、调试等高级服务的前置条件 — 需先挂载 DeveloperDiskImage。
