# Universal CA Cert Installer

该模块用于将 CA 证书安装到系统证书库，并在 Android 14 上通过 APEX 目录挂载使其生效。

## 目录结构

- `system/etc/security/cacerts/`：已按 `hash.N` 命名的系统证书文件。
- `system/etc/security/cacerts-raw/`：可选目录，放置未命名的 PEM 证书，安装时会自动转换为 `hash.N` 并复制到 `cacerts/`。

## 使用说明

1. 如果你的证书已经是 `hash.N` 命名，请直接放入 `system/etc/security/cacerts/`。
2. 如果证书未命名，请放入 `system/etc/security/cacerts-raw/`，模块安装时会自动生成对应的 `hash.N` 文件。
3. 安装时如果检测到旧模块证书，会提示是否导入：音量+ 导入，音量- 跳过；导入后可选择“复制并替换”或“复制并保留两个证书”。默认等待超时后会跳过导入。

## 注意事项

- 证书需为 PEM 格式。
- 安装后脚本会将证书目录挂载到系统证书库（Android 14 为 APEX 目录）。
- KernelSU 需要安装元模块（例如 meta-overlayfs）才能挂载模块文件。
