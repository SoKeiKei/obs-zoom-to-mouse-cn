# OBS 鼠标缩放脚本 - 多显示器 Bug 检查文档

## 问题描述

**反馈来源**：用户反馈 + 开发者自测

**现象**：
- 主屏（显示器采集1）缩放正常
- 副屏（显示器采集2）X 轴缩放位置错乱
- 测试环境：两个相同 2K 分辨率显示器，缩放均为 100%

---

## 问题定位

### 核心代码位置

文件：`obs-zoom-to-mouse-cn.lua`
函数：`get_monitor_info()` (第 654-744 行)

### 问题根源

显示器信息是通过解析 OBS 属性列表中的显示器**名称字符串**获取的：

```lua
-- 第 693-700 行
-- OBS 显示器名称格式示例："U2790B: 3840x2160 @ -1920,0 (Primary Monitor)"
log("Parsing display name: " .. found)
local x, y = found:match("(-?%d+),(-?%d+)")      -- 提取坐标
local width, height = found:match("(%d+)x(%d+)")  -- 提取分辨率
```

### 可能的 Bug 原因（待验证）

1. **中文环境下 OBS 显示器名称格式不同**
   - OBS 中文版可能显示：`"显示器: 2560x1440 @ 2560,0"` 或其他格式
   - 正则表达式可能无法正确匹配

2. **正则表达式匹配逻辑问题**
   - `(-?%d+),(-?%d+)` 匹配逗号分隔的数字
   - 如果名称中有多个逗号分隔的数字组合，可能匹配到错误的值
   - Lua `string.match` 从字符串开头搜索，返回第一个匹配

3. **副屏坐标解析错误**
   - 主屏坐标通常是 `0,0`，即使解析错误也影响不大
   - 副屏坐标可能是 `2560,0`（在主屏右边），解析错误会导致 X 轴偏移

---

## 排查步骤

### 步骤 1：查看 OBS 脚本日志

1. OBS 菜单 → 工具 → 脚本
2. 选择 `obs-zoom-to-mouse-cn.lua`
3. 查看日志窗口，找到以下输出：
   ```
   Parsing display name: [这里显示 OBS 返回的显示器名称]
   Parsed the following display information
   x = ?
   y = ?
   width = ?
   height = ?
   ```

4. 对比两个显示器采集源的日志输出，确认解析是否正确

### 步骤 2：手动验证显示器名称格式

在 OBS 中创建两个显示器采集源，查看源属性中的显示器下拉列表：
- 记录每个显示器显示的完整名称
- 确认名称格式是否包含坐标信息

### 步骤 3：测试手动源位置

启用"设置手动源位置"，填写正确的副屏参数：
- X = 副屏起点 X（如主屏右边则填主屏宽度）
- Y = 0（通常）
- 宽度/高度 = 副屏分辨率
- 缩放X/Y = 1
- 显示器宽度/高度 = 副屏分辨率

如果手动参数能正常工作，则确认是自动解析的问题。

---

## 原作者已知限制

原代码注释（第 693-696 行）：

```lua
-- This works for my machine as the monitor names are given as "U2790B: 3840x2160 @ -1920,0 (Primary Monitor)"
-- I don't know if this holds true for other machines and/or OBS versions
-- TODO: Update this with some custom FFI calls to find the monitor top-left x and y coordinates
```

翻译：作者明确表示不确定在其他机器/OBS版本上是否有效，计划用 FFI 调用替代，但一直未实现。

---

## 修复方案（建议）

### 方案 A：改进正则表达式

使用更精确的模式匹配，确保只匹配坐标部分：

```lua
-- 改进：匹配 "@ X,Y" 格式的坐标
local x, y = found:match("@%s*(-?%d+),(-?%d+)")
```

### 方案 B：使用 Windows API 直接获取显示器坐标

通过 FFI 调用 `EnumDisplayMonitors` 或 `GetMonitorInfo` 获取准确的显示器位置，不依赖 OBS 名称解析。

### 方案 C：增加调试日志和错误提示

- 输出完整的显示器名称字符串，方便用户排查
- 检测解析失败时，提示用户使用手动源位置

---

## 下一步行动

1. **收集用户日志**：请用户提供 OBS 脚本日志中的显示器名称解析输出
2. **验证中文格式**：在中文 OBS 环境下测试显示器名称格式
3. **实现修复**：根据收集的信息选择合适的修复方案

---

*文档创建时间：2026-04-01*
*问题状态：待验证*