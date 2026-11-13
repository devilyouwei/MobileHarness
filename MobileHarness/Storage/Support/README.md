# Common Storage Mechanisms

## 职责与边界

StorageCore 编译 [Contracts](Contracts/README.md)、[Memory](Memory/README.md) 和模块根的 [StorageFailure.swift](../StorageFailure.swift)。Contracts 定义共享标识、结构化状态、持久化和错误值。Memory 提供有界流、拥有者租约与接纳门。Cache、Files 和数据库仓库复用这些机制。

## 统一容器异常通道

StorageFailureReporter 向宿主的注入回调传递结构化 StorageFailure，保留组件、操作、原始错误和清理失败。取消证据保留在原错误中。报告器由调用方提供有界、非阻塞实现。运行时事实、持久化策略和恢复由实际能力拥有者决定。

[Storage](../README.md)
