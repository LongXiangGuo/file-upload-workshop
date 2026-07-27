# FileUploadPlus — Architecture Design

## Overview

FileUploadPlus 是一个面向 iOS 全场景的商业级文件传输框架。采用 **模块化 SPM 架构**，支持按需引入，覆盖小/中/大型项目的文件上传、下载场景。

## Module Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     FileUploadPlus (Umbrella)                  │
│                        Re-exports all modules                  │
├────────────┬──────────┬──────────┬──────────┬────────────────┤
│   Core     │  Engine  │ Services │ Pipeline │   Metrics      │
│ (0 deps)   │ (→ Core) │ (→ Core) │ (→ Core) │   (→ Core)     │
├────────────┴──────────┴──────────┴──────────┴────────────────┤
│                      Download (→ Core, Engine)                │
└──────────────────────────────────────────────────────────────┘
```

### Module Dependency Graph

```
FileUploadPlusCore         ← zero dependencies
    ↑
    ├── FileUploadPlusEngine     (upload task orchestration)
    ├── FileUploadPlusServices   (auth, log, validate, sign, encrypt)
    ├── FileUploadPlusPipeline   (pre/post processing stages)
    ├── FileUploadPlusMetrics    (bandwidth, traffic, circuit breaker)
    │
    └── FileUploadPlusDownload   (→ Core + Engine)
            ↑
    FileUploadPlus (umbrella)    ← re-exports everything
```

### 按需引入策略

| 项目规模 | 引入模块 | 说明 |
|---------|---------|------|
| 小项目 | `FileUploadPlusCore` + `FileUploadPlusEngine` | 核心上传能力 |
| 中项目 | + `FileUploadPlusServices` + `FileUploadPlusPipeline` | 加认证、校验、日志、管道 |
| 大项目 | + `FileUploadPlusMetrics` + `FileUploadPlusDownload` | 全功能：可观测性、下载 |

```swift
// 小项目
import FileUploadPlusCore
import FileUploadPlusEngine

// 大项目
import FileUploadPlus  // 一键导入全部
```

## Data Flow

```
User App
    │
    ├─ FileUploadManager.uploadFile(at:)
    │   │
    │   ├── 1. Pipeline.executePreUpload()
    │   │       ├── FileValidation      (文件校验)
    │   │       ├── ImageCompression    (图片压缩)
    │   │       └── Notification        (开始通知)
    │   │
    │   ├── 2. InitUpload with Server   (获取 uploadId)
    │   │
    │   ├── 3. For each chunk:
    │   │       ├── DataProvider.readData()
    │   │       ├── Pipeline.processChunk()
    │   │       │   ├── Checksum        (计算散列)
    │   │       │   └── Encryption      (加密)
    │   │       ├── RequestSigner.sign()
    │   │       ├── Authentication.authenticate()
    │   │       ├── TrafficController.acquireSlot()
    │   │       ├── NetworkClient.uploadChunk()
    │   │       └── TrafficController.releaseSlot()
    │   │
    │   ├── 4. CompleteUpload with Server
    │   │
    │   └── 5. Pipeline.executePostUpload()
    │           ├── Metrics             (记录指标)
    │           └── Notification        (完成/失败通知)
    │
    └─ StreamingUploadHandle
        ├── append(data:)     → write + schedule upload chunks
        └── finish()          → finalize
```

## Design Decisions

### 1. Chunk Size Selection
- **Default**: 2MB (平衡开销与恢复粒度)
- **Adaptive Mode**: 基于文件大小自动计算，目标 100~200 个分片
- **Dynamic Adjust**: TrafficController 根据网络状况动态调整

### 2. 状态持久化
- SQLite + WAL 模式，保证并发读
- 每次分片完成后立即落盘，crash 后可从最近完成分片恢复
- `UploadStateStore` 独立模块，可替换为其他存储后端

### 3. 并发控制
- OperationQueue 管理分片上传并发
- TrafficController 信号量方式控制并发槽位
- 成功时渐进增加并发，失败时减半回退（类 TCP 拥塞控制）

### 4. 断点续传
- SQLite 保存每个分片状态 + offset
- `ChunkCoordinator` 跟踪已上传字节偏移
- 应用重启后自动恢复未完成上传

### 5. 安全设计
- 文件名校验防路径遍历（`..`, `/`, `\`）
- 扩展名白名单 + 黑名单机制
- 分片级加密（AES-GCM / ChaCha20-Poly1305）
- 分片级完整性校验（SHA-256 / MD5）
- 请求签名防篡改（HMAC-SHA256 / 云厂商签名）

### 6. 可靠性模式
- **RetryPolicy**: 指数退避 + 随机抖动（jitter），避免 thundering herd
- **CircuitBreaker**: 连续失败时熔断，恢复期 half-open 探活
- **BandwidthTracker**: 滑动窗口统计实时速率，支持 ETA
- **NWPathMonitor**: 网络可达性监听，自动恢复暂停任务

### 7. 下载模块
- 基于 URLSession downloadTask，系统级后台下载
- 支持 Range 请求实现断点续传
- Resume data 持久化支持 crash 恢复
- 统一进度查询 API（上传 + 下载）

## BAT Cloud Storage Compatibility

| 云厂商 | URLBuilder | RequestSigner |
|--------|------------|---------------|
| 阿里云 OSS | `AliyunOSSUrlBuilder` | `AliyunOSSV2Signer` |
| 腾讯云 COS | `TencentCOSURLBuilder` | `TencentCOSSigner` |
| AWS S3 | `AWSS3URLBuilder` | `HMACSHA256Signer` |
| 自建服务 | `StandardURLBuilder` | `HMACSHA256Signer` |

## Extensibility Points

所有核心协议均可替换自定义实现：

```swift
protocol Auth           → 自定义认证策略
protocol Encryption     → 自定义加密算法
protocol FileValidator  → 自定义校验规则
protocol URLBuilder     → 自定义后端 API
protocol RequestSigner  → 自定义签名算法
protocol LogService     → 自定义日志输出
protocol PipelineStage  → 自定义处理阶段
```

## File Layout

```
FileUploadPlus/
├── Package.swift                    # SPM manifest
├── Makefile                         # Build automation
├── ARCHITECTURE.md                  # This document
├── scripts/
│   ├── open.sh                      # Open in Xcode
│   ├── build.sh                     # Build with SPM or Xcode
│   └── test.sh                      # Run tests
├── Sources/
│   ├── FileUploadPlusCore/          # 基础类型 + 协议
│   ├── FileUploadPlusEngine/        # 上传引擎
│   ├── FileUploadPlusServices/      # 服务实现
│   ├── FileUploadPlusPipeline/      # 管道/拦截器
│   ├── FileUploadPlusMetrics/       # 可观测性
│   ├── FileUploadPlusDownload/      # 下载模块
│   ├── FileUploadPlusUmbrella/      # 聚合导出
│   └── FileUploadPlusDemo/          # 演示 App
├── FileUploadPlus/                  # (legacy) Xcode project sources
│   ├── FileChunkUploader.swift
│   ├── UploadServices.swift
│   ├── UploadPipeline.swift
│   ├── UploadMetrics.swift
│   └── ContentView.swift
├── FileUploadPlus.xcodeproj/        # Demo Xcode project
└── Tests/
    └── FileUploadPlusCoreTests/
```
