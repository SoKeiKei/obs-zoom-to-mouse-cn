# OBS 鼠标缩放脚本架构文档

> 版本：2.0（中文增强版）
> 文件：`obs-zoom-to-mouse-cn.lua`
> 原作者：BlankSourceCode
> 二次开发：SoKei

---

## 目录

1. [脚本概述](#1-脚本概述)
2. [文件结构](#2-文件结构)
3. [核心变量](#3-核心变量)
4. [主要函数](#4-主要函数)
5. [事件流程](#5-事件流程)
6. [快捷键定义](#6-快捷键定义)
7. [设置项说明](#7-设置项说明)
8. [常见问题定位](#8-常见问题定位)

---

## 1. 脚本概述

此脚本实现将 OBS 显示器捕获源缩放到鼠标位置的功能，支持：
- 平滑缩放动画
- 鼠标跟随
- 鼠标静止自动缩小
- 键盘输入检测
- 远程鼠标监听（可选）

---

## 2. 文件结构

```
脚本行数：约 1850 行
主要代码段分布：

行号范围     内容
-----------  ----------------------------------------------------
1-100       变量声明区
101-120     平台特定函数（Windows/Linux/macOS 鼠标获取）
121-400     核心工具函数（lerp, clamp, log 等）
401-600     源和场景项管理函数
601-800     裁剪滤镜管理函数
801-920     目标位置计算函数
921-1050    定时器回调和鼠标跟踪逻辑
1051-1200   套接字服务器代码（远程鼠标）
1201-1400   键盘输入检测函数
1401-1600   脚本属性 UI 定义
1601-1700   脚本加载/卸载
1701-1850   设置保存/更新/默认值
```

---

## 3. 核心变量

### 3.1 状态变量（第 28-54 行）

| 变量名 | 类型 | 说明 |
|--------|------|------|
| `source_name` | string | 选定的缩放源名称 |
| `source` | obs_source_t* | 源对象引用 |
| `sceneitem` | obs_sceneitem_t* | 场景项引用 |
| `crop_filter` | obs_source_t* | 裁剪滤镜对象 |
| `monitor_info` | table | 显示器信息 |

### 3.2 缩放信息（第 41-48 行）

```lua
zoom_info = {
    source_size = { width = 0, height = 0 },    -- 源尺寸
    source_crop = { x = 0, y = 0, w = 0, h = 0 }, -- 源裁剪
    source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }, -- 滤镜裁剪
    zoom_to = 2  -- 目标缩放倍数
}
```

### 3.3 缩放状态（第 100-107 行）

```lua
ZoomState = {
    None = 0,        -- 无缩放
    ZoomingIn = 1,   -- 正在放大
    ZoomingOut = 2,  -- 正在缩小
    ZoomedIn = 3,    -- 已放大
}
zoom_state = ZoomState.None
```

### 3.4 热键 ID（第 51-53 行）

| 变量名 | 热键名称 | 说明 |
|--------|----------|------|
| `hotkey_zoom_id` | toggle_zoom_hotkey | 切换鼠标缩放 |
| `hotkey_follow_id` | toggle_follow_hotkey | 切换缩放时跟随鼠标 |
| `hotkey_auto_zoom_out_id` | toggle_auto_zoom_out_hotkey | 切换鼠标静止自动缩小 |

### 3.5 鼠标静止自动缩小（第 89-98 行）

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `use_auto_zoom_out` | false | 是否启用自动缩小 |
| `auto_zoom_out_delay` | 3.0 | 静止延迟（秒） |
| `mouse_idle_timer` | 0 | 鼠标静止计时器 |
| `last_mouse_pos` | nil | 上次鼠标位置 |
| `is_mouse_idle` | false | 是否处于静止状态 |
| `was_auto_zoomed_out` | false | 是否由自动缩小触发 |

### 3.6 键盘输入检测（第 95-100 行）

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `use_detect_typing` | false | 是否检测键盘输入（包含滚轮） |
| `typing_pause_delay` | 2.0 | 输入/滚轮暂停延迟（秒） |
| `last_keyboard_time` | 0 | 上次键盘输入时间 |
| `last_wheel_time` | 0 | 上次滚轮操作时间 |
| `is_typing` | false | 是否正在输入 |

**注意**：滚轮检测与键盘输入共用同一个开关和延迟设置

### 3.7 跟随设置（第 51-57 行）

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `use_auto_follow_mouse` | true | 自动跟随鼠标 |
| `use_follow_outside_bounds` | false | 边界外跟随 |
| `is_following_mouse` | false | 是否正在跟随 |
| `follow_speed` | 0.18 | 跟随速度（0.001-1） |
| `follow_border` | 0 | 跟随边界（%） |
| `follow_safezone_sensitivity` | 10 | 锁定灵敏度 |
| `use_follow_auto_lock` | false | 反向自动锁定 |
| `use_smooth_follow` | true | 启用平滑跟随 |
| `smooth_factor` | 0.5 | 平滑系数（0.1-1） |
| `mouse_velocity_buffer` | {x=0, y=0} | 鼠标速度缓冲 |
| `smoothed_mouse_pos` | nil | 平滑后的鼠标位置 |

---

## 4. 主要函数

### 4.1 平台特定函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `get_mouse_pos()` | ~200 | 获取鼠标屏幕坐标（跨平台） |
| `is_key_pressed()` | ~280 | 检测键盘按键（跨平台） |
| `is_user_typing()` | ~231 | 检测键盘输入和滚轮活动 |
| `process_mouse_position()` | ~390 | 处理鼠标位置（平滑 + 速度预测） |
| `smoothstep()` | ~378 | 缓动函数（用于平滑跟随） |

### 4.2 工具函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `lerp(a, b, t)` | ~330 | 线性插值 |
| `clamp(min, max, val)` | ~340 | 数值限制 |
| `log(msg)` | ~350 | 脚本日志输出 |
| `update_aspect_ratio()` | ~380 | 更新动态宽高比 |

### 4.3 源管理函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `refresh_sceneitem(force)` | ~450 | 刷新场景项引用 |
| `release_sceneitem()` | ~550 | 释放场景项引用 |
| `populate_zoom_sources(list)` | ~580 | 填充缩放源列表 |
| `get_monitor_info(src)` | ~620 | 获取显示器信息 |

### 4.4 裁剪滤镜函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `get_or_create_crop_filter()` | ~680 | 获取或创建裁剪滤镜 |
| `ensure_crop_filter()` | ~720 | 确保滤镜存在 |
| `release_crop_filter()` | ~750 | 释放裁剪滤镜 |
| `set_crop_settings(crop)` | ~780 | 应用裁剪设置 |

### 4.5 目标计算函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `get_target_position(zoom)` | ~850 | 计算缩放目标位置 |

### 4.6 热键回调函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `on_toggle_zoom(pressed, force_value)` | 931 | 切换缩放状态 |
| `on_toggle_follow(pressed)` | 916 | 切换跟随鼠标 |
| `on_toggle_auto_zoom_out(pressed)` | 932 | 切换自动缩小 |

### 4.7 定时器回调

| 函数 | 行号 | 说明 |
|------|------|------|
| `on_timer()` | ~980 | 主定时器回调（每帧执行） |

### 4.8 脚本生命周期函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `script_defaults(settings)` | ~1680 | 设置默认值 |
| `script_properties()` | 1458 | 创建属性 UI |
| `script_load(settings)` | 1593 | 脚本加载 |
| `script_save(settings)` | 1751 | 脚本保存 |
| `script_update(settings)` | 1767 | 设置更新 |
| `script_unload()` | 1687 | 脚本卸载 |
| `script_description()` | 1454 | 脚本描述 |

### 4.9 事件处理函数

| 函数 | 行号 | 说明 |
|------|------|------|
| `on_frontend_event(event)` | ~1650 | OBS 前端事件回调 |
| `on_settings_modified(props, p, s)` | ~1350 | 设置修改回调 |
| `on_print_help()` | 1416 | 打印帮助信息 |

---

## 5. 事件流程

### 5.1 脚本启动流程

```
script_load()
  ├── 注册热键（3 个）
  ├── 加载热键配置
  ├── 加载其他设置
  ├── 添加前端事件回调
  └── 初始化平台特定代码

script_defaults()
  └── 设置所有属性默认值

script_properties()
  └── 创建 UI 属性控件
```

### 5.2 缩放激活流程

```
用户按下热键
  └── on_toggle_zoom(pressed=true)
      ├── 重置鼠标计时器
      ├── 判断当前状态
      ├── 计算目标位置 (get_target_position)
      ├── 设置 zoom_state = ZoomingIn
      └── 启动定时器 (obs.timer_add)

定时器回调 on_timer()
  ├── 更新 zoom_time
  ├── 根据 zoom_state 执行：
  │   ├── ZoomingIn: 放大动画
  │   ├── ZoomingOut: 缩小动画
  │   └── ZoomedIn: 检查跟随/自动缩小
  ├── 应用裁剪设置 (set_crop_settings)
  └── 检查鼠标静止自动缩小
```

### 5.3 鼠标静止自动缩小流程

```
每帧检查 (on_timer 中，第 1002-1030 行)
  └── 如果 zoom_state == ZoomedIn 且 use_auto_zoom_out
      ├── 获取当前鼠标位置
      ├── 计算位移 (dx, dy)
      ├── 如果 dx < 3 且 dy < 3 (鼠标静止)
      │   ├── 如果正在输入 (is_user_typing)
      │   │   └── 重置计时器
      │   └── 否则
      │       ├── 增加计时器
      │       └── 如果 timer >= delay
      │           ├── is_mouse_idle = true
      │           ├── was_auto_zoomed_out = true
      │           └── on_toggle_zoom(true, false) 触发缩小
      └── 否则 (鼠标移动)
          └── 重置计时器和 idle 状态
```

### 5.4 键盘输入检测流程

```
每帧检查 (is_user_typing 函数)
  └── 检测常见输入按键
      ├── 字母键、数字键、功能键等
      ├── 如果检测到按键
      │   ├── 更新 last_keyboard_time
      │   └── is_typing = true
      └── 如果超过 typing_pause_delay
          └── is_typing = false
```

---

## 6. 快捷键定义

| 热键 ID | 内部名称 | 显示名称 | 回调函数 | 行号 |
|---------|----------|----------|----------|------|
| `hotkey_zoom_id` | toggle_zoom_hotkey | 切换鼠标缩放 | on_toggle_zoom | 1600 |
| `hotkey_follow_id` | toggle_follow_hotkey | 切换缩放时跟随鼠标 | on_toggle_follow | 1603 |
| `hotkey_auto_zoom_out_id` | toggle_auto_zoom_out_hotkey | 切换鼠标静止自动缩小 | on_toggle_auto_zoom_out | 1611 |

### 热键配置存储

```lua
-- 保存在脚本配置中的键名
"obs_zoom_to_mouse.hotkey.zoom"        -- 缩放热键
"obs_zoom_to_mouse.hotkey.follow"      -- 跟随热键
"obs_zoom_to_mouse.hotkey.auto_zoom_out" -- 自动缩小热键
```

---

## 7. 设置项说明

### 7.1 基本设置

| 设置键 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `source` | string | "" | 缩放源名称 |
| `zoom_value` | double | 2 | 缩放倍数 (1-5) |
| `zoom_speed` | double | 0.1 | 缩放速度 (0.01-1) |

### 7.2 跟随设置

| 设置键 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `follow` | bool | true | 自动跟随鼠标 |
| `follow_outside_bounds` | bool | false | 边界外跟随 |
| `follow_speed` | double | 0.18 | 跟随速度（0.001-1） |
| `follow_border` | int | 0 | 跟随边界 (%) |
| `follow_safezone_sensitivity` | int | 10 | 锁定灵敏度 |
| `follow_auto_lock` | bool | false | 反向自动锁定 |
| `use_smooth_follow` | bool | true | 启用平滑跟随 |
| `smooth_factor` | double | 0.5 | 平滑系数 (0.1-1) |

### 7.3 自动缩小设置

| 设置键 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `auto_zoom_out` | bool | false | 鼠标静止自动缩小 |
| `auto_zoom_out_delay` | double | 3.0 | 静止延迟 (秒) |
| `detect_typing` | bool | false | 检测键盘输入/滚轮（共用） |
| `typing_pause_delay` | double | 2.0 | 输入/滚轮暂停延迟 (秒) |

### 7.4 其他设置

| 设置键 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `auto_start` | bool | false | OBS 启动时自动缩放 |
| `keep_shape` | bool | false | 动态宽高比 |
| `allow_all_sources` | bool | false | 允许任意缩放源 |
| `use_monitor_override` | bool | false | 手动源位置 |
| `use_socket` | bool | false | 启用远程鼠标监听 |
| `socket_port` | int | 12345 | 远程监听端口 |
| `socket_poll` | int | 10 | 轮询延迟 (ms) |
| `debug_logs` | bool | false | 启用调试日志 |

---

## 8. 常见问题定位

### 8.1 缩放不工作

**检查点：**
1. 源是否正确设置（第 1462 行 `source` 属性）
2. 场景项是否正确获取（`refresh_sceneitem` 函数 ~450 行）
3. 裁剪滤镜是否创建成功（`get_or_create_crop_filter` ~680 行）

**调试方法：**
- 启用 `debug_logs` 查看详细日志
- 点击"刷新缩放源"按钮重新获取源

### 8.2 鼠标位置不正确

**检查点：**
1. 平台特定鼠标函数（`get_mouse_pos` ~200 行）
2. 显示器信息是否正确（`get_monitor_info` ~620 行）
3. 是否启用了远程鼠标（`use_socket` 第 152 行）

**平台特定代码：**
- Windows: 使用 `GetCursorPos` (第 120-130 行)
- Linux: 使用 X11 `XQueryPointer` (第 131-145 行)
- macOS: 使用 CGEvent (第 146-170 行)

### 8.3 自动缩小不触发

**检查点：**
1. `use_auto_zoom_out` 是否启用（第 89 行）
2. `auto_zoom_out_delay` 设置是否合理（第 90 行）
3. `use_detect_typing` 是否干扰（第 96 行）

**相关代码：**
- 鼠标静止检测：第 1030-1055 行
- 键盘/滚轮输入检测：`is_user_typing` 函数 ~231 行

### 8.4 跟随鼠标不工作

**检查点：**
1. `use_auto_follow_mouse` 是否启用
2. `is_following_mouse` 状态（第 53 行）
3. 跟随边界设置（`follow_border` 第 55 行）

**相关代码：**
- 跟随逻辑：第 1046-1120 行
- 锁定区域检测：第 1063-1085 行

### 8.5 热键不响应

**检查点：**
1. 热键是否正确注册（`script_load` 第 1593 行）
2. 热键配置是否加载（第 1606-1624 行）
3. OBS 热键冲突检查

**热键相关行号：**
- 注册：第 1600-1612 行
- 加载：第 1606-1624 行
- 保存：第 1751-1770 行
- 注销：第 1697-1700 行

### 8.6 脚本崩溃

**常见原因：**
1. 场景项引用失效（检查 `release_sceneitem` 调用）
2. 滤镜对象为空（检查 `ensure_crop_filter`）
3. OBS API 版本兼容性（第 108-111 行版本检测）

---

## 附录

### A. 重要常量

```lua
VERSION = "2.0"                          -- 脚本版本
CROP_FILTER_NAME = "obs-zoom-to-mouse-crop" -- 滤镜名称
```

### B. 代码修改建议

**添加新功能时：**
1. 在变量声明区添加新变量（第 28-100 行附近）
2. 在 `script_defaults` 中添加默认值
3. 在 `script_properties` 中添加 UI 控件
4. 在 `script_load` 中注册热键（如需要）
5. 在 `script_save` 中保存配置
6. 在 `script_update` 中读取设置

**修改现有功能时：**
1. 使用本文档定位相关函数
2. 注意相关变量的联动
3. 修改后更新本文档

---

*文档最后更新：2026-03-04*
