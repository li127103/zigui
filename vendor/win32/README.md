# vendor/win32 — Windows 交叉编译导入库

本目录下的导入库（`.a`）用于让 Zig（其自带 mingw-w64）在 Linux 上交叉编译
到 `x86_64-windows-gnu` 目标时能链接到 Windows 系统 DLL 的导入桩。

Zig 0.16 自带的 mingw-w64 已经通过 `.def` 文件提供了大部分 Windows DLL 的
导入库（d3d11 / d3d12 / dxgi / d2d1 / dwrite / dwmapi / shcore / user32 /
gdi32 / ole32 / shell32 / windowscodecs / uuid 等），但有两种情况缺失：

1. **`d3dcompiler`**：Zig 自带 mingw 只有版本化的 `d3dcompiler_47.def`，
   按通用名 `d3dcompiler` 查找时找不到。这里放的是系统 mingw 的 `libd3dcompiler.a`
   （对应运行时的 `d3dcompiler_47.dll`，Windows 自带）。
2. **`vulkan-1`**：Zig 自带 mingw 完全没有 vulkan 的导入库。
   `libvulkan-1.a` 由本机 Linux 的 Vulkan loader（`/usr/lib/libvulkan.so.1`）
   导出的全部 `vk*` 符号生成，与 Windows 上的 `vulkan-1.dll`（Vulkan 运行时/显卡驱动提供）
   导出集合一致。

`build.zig` 在 `configureModule` 的 Windows 分支里通过
`mod.addLibraryPath(b.path("vendor/win32/lib"))` 把这些库加入链接搜索路径。

## 重新生成

```bash
# 1) d3dcompiler（来自系统 mingw）
cp /usr/x86_64-w64-mingw32/lib/libd3dcompiler.a ./lib/

# 2) vulkan-1（由 Linux loader 的导出符号生成）
V=/usr/lib/libvulkan.so.1
nm -D --defined-only "$V" \
  | awk '$2=="T" && $3 ~ /^vk/ { s=$3; sub(/@.*/,"",s); print s }' \
  | sort -u > /tmp/vk_exports.txt
{ echo "LIBRARY vulkan-1"; echo "EXPORTS"; cat /tmp/vk_exports.txt; } > ./lib/vulkan-1.def
x86_64-w64-mingw32-dlltool -d ./lib/vulkan-1.def -l ./lib/libvulkan-1.a -m i386:x86-64
```

> 注意：这些 `.a` 只是导入桩（不含实现），真正的实现在目标机 Windows 的系统 DLL 中。
> 默认（D3D11）构建只需要 `libd3dcompiler.a`；`-Dvulkan` 构建额外需要 `libvulkan-1.a`。
