--
-- OBS 鼠标缩放 (中文威力加强版)
-- 一个 OBS Lua 脚本，用于将显示器捕获源缩放到鼠标位置。
-- Copyright (c) BlankSourceCode. All rights reserved.
--
-- 二次开发：SoKei https://space.bilibili.com/3546772855064749
-- 版本：2.2
--
-- 核心增强功能：
--   ★ 二级缩放系统
--     - 独立的二级缩放倍数配置（1.1x - 最大倍数）
--     - 支持三级缩放状态切换（原始 → 二级 → 最大）
--     - 独立热键控制，与主缩放互不干扰
--
--   ★ 丝滑移动与缩放算法
--     - 速度预测算法：提前预判鼠标移动趋势
--     - 缓动函数优化：起步柔和，收尾自然
--     - 动态回弹修正：自动校正微小偏移（回弹强度 0.010，上限 28 像素）
--     - 缩放中持续跟随：减少动画结束后的跳变感
--     - 平滑系数可调：0.16 默认值，平衡灵敏与稳定
--
--   ★ 智能自动化功能
--     - 鼠标静止自动缩小（可配置延迟 1-30 秒）
--     - 鼠标移动自动恢复缩放
--     - 键盘/滚轮输入检测（输入时不触发自动缩小）
--     - OBS 启动时自动缩放（无需手动激活）
--
--   ★ 其他增强
--     - 完整中文界面汉化
--     - 动态宽高比适配（竖屏直播/超宽屏幕完美支持）
--     - 4 个自定义热键（主缩放/二级缩放/跟随开关/自动缩小开关）
--
-- 默认参数优化（v2.2 录屏演示风格）:
--   跟随速度：0.18 | 平滑系数：0.16 | 回弹强度：0.010 | 回弹上限：28 | 缩放丝滑度：0.88
--

local obs = obslua
local ffi = require("ffi")
local bit = require("bit")
local VERSION = "2.2"
local CROP_FILTER_NAME = "obs-zoom-to-mouse-crop"

local socket_available, socket = pcall(require, "ljsocket")
local socket_server = nil
local socket_mouse = nil

local source_name = ""
local source = nil
local sceneitem = nil
local sceneitem_info_orig = nil
local sceneitem_info_base = nil
local sceneitem_crop_orig = nil
local sceneitem_info = nil
local sceneitem_crop = nil
local crop_filter = nil
local crop_filter_temp = nil
local crop_filter_settings = nil
local crop_filter_info_orig = { x = 0, y = 0, w = 0, h = 0 }
local crop_filter_info = { x = 0, y = 0, w = 0, h = 0 }
local monitor_info = nil
local zoom_info = {
    source_size = { width = 0, height = 0 },
    source_crop = { x = 0, y = 0, w = 0, h = 0 },
    source_crop_filter = { x = 0, y = 0, w = 0, h = 0 },
    zoom_to = 2
}
local zoom_time = 0
local zoom_target = nil
local locked_center = nil
local locked_last_pos = nil
local hotkey_zoom_id = nil
local hotkey_tier_zoom_id = nil
local hotkey_follow_id = nil
local hotkey_auto_zoom_out_id = nil
local is_timer_running = false

local win_point = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil

local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local is_following_mouse = false
local follow_speed = 0.18
local follow_border = 0
local follow_safezone_sensitivity = 10
local use_follow_auto_lock = false
local use_smooth_follow = true
local smooth_factor = 0.16
local follow_prediction_time = 0.010
local follow_prediction_limit = 28
local mouse_velocity_buffer = { x = 0, y = 0 }
local smoothed_mouse_pos = nil
local last_follow_raw_pos = nil
local zoom_value = 2
local zoom_value_tier = 1.5
local zoom_speed = 0.1
local zoom_smoothness = 0.88
local follow_activation_delay = 0.00
local follow_activation_timer = 0
local pending_auto_follow = false
local composition_bias_x = 0.0
local composition_bias_y = 0.0
local use_tier_zoom = false
local current_zoom_level = "none"
local allow_all_sources = false
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 0
local monitor_override_h = 0
local monitor_override_sx = 0
local monitor_override_sy = 0
local monitor_override_dw = 0
local monitor_override_dh = 0
local use_socket = false
local socket_port = 0
local socket_poll = 1000
local debug_logs = false
local is_obs_loaded = false
local is_script_loaded = false

local use_auto_zoom_out = false
local auto_zoom_out_delay = 3.0
local mouse_idle_timer = 0
local last_mouse_pos = nil
local is_mouse_idle = false
local was_auto_zoomed_out = false
local use_detect_typing = false
local typing_pause_delay = 2.0
local last_keyboard_time = 0
local is_typing = false
local last_wheel_time = 0

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None
local suppress_transform_update = false
local sceneitem_rect_base = { x = 0, y = 0, w = 0, h = 0 }
local zoom_anim_start = nil

local OBS_ALIGN_TOP = 1
local OBS_ALIGN_BOTTOM = 2
local OBS_ALIGN_LEFT = 4
local OBS_ALIGN_RIGHT = 8
local OBS_ALIGN_TOP_LEFT = OBS_ALIGN_TOP + OBS_ALIGN_LEFT

local version = obs.obs_get_version_string()
local m1, m2 = version:match("(%d+%.%d+)%.(%d+)")
local major = tonumber(m1) or 0
local minor = tonumber(m2) or 0

local keep_shape = false
local auto_start = false
local auto_start_running = false
local aspect_ratio_w = 1
local aspect_ratio_h = 1

-- Define the mouse cursor functions for each platform
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
        short GetAsyncKeyState(int vKey);
    ]])
    win_point = ffi.new("POINT[1]")
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
    ]])

    x11_lib = ffi.load("X11.so.6")
    x11_display = x11_lib.XOpenDisplay(nil)
    if x11_display ~= nil then
        x11_root = x11_lib.XDefaultRootWindow(x11_display)
        x11_mouse = {
            root_win = ffi.new("Window[1]"),
            child_win = ffi.new("Window[1]"),
            root_x = ffi.new("int[1]"),
            root_y = ffi.new("int[1]"),
            win_x = ffi.new("int[1]"),
            win_y = ffi.new("int[1]"),
            mask = ffi.new("unsigned int[1]")
        }
    end
elseif ffi.os == "OSX" then
    ffi.cdef([[
        typedef struct {
            double x;
            double y;
        } CGPoint;
        typedef void* SEL;
        typedef void* id;
        typedef void* Method;

        SEL sel_registerName(const char *str);
        id objc_getClass(const char*);
        Method class_getClassMethod(id cls, SEL name);
        void* method_getImplementation(Method);
        int access(const char *path, int amode);
    ]])

    osx_lib = ffi.load("libobjc")
    if osx_lib ~= nil then
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
        end
    end
end

---
-- Get the current mouse position
---@return table Mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if socket_mouse ~= nil then
        mouse.x = socket_mouse.x
        mouse.y = socket_mouse.y
    else
        if ffi.os == "Windows" then
            if win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
                mouse.x = win_point[0].x
                mouse.y = win_point[0].y
            end
        elseif ffi.os == "Linux" then
            if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
                if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                    mouse.x = tonumber(x11_mouse.win_x[0])
                    mouse.y = tonumber(x11_mouse.win_y[0])
                end
            end
        elseif ffi.os == "OSX" then
            if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
                local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
                mouse.x = point.x
                if monitor_info ~= nil then
                    if monitor_info.display_height > 0 then
                        mouse.y = monitor_info.display_height - point.y
                    else
                        mouse.y = monitor_info.height - point.y
                    end
                end
            end
        end
    end

    return mouse
end

---
-- Check if user is currently typing or using mouse wheel (keyboard/mouse activity)
---@return boolean True if typing or wheel activity detected
function is_user_typing()
    if not use_detect_typing then
        return false
    end

    local current_time = os.time()

    -- Check for mouse wheel activity (use same delay as typing)
    if current_time - last_wheel_time < typing_pause_delay then
        return true
    end

    if ffi.os == "Windows" then
        local typing_keys = {
            0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A,
            0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52, 0x53, 0x54,
            0x55, 0x56, 0x57, 0x58, 0x59, 0x5A,
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
            0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0,
            0xDB, 0xDC, 0xDD,
            0x20,
        }

        for _, key_code in ipairs(typing_keys) do
            local state = ffi.C.GetAsyncKeyState(key_code)
            if bit.band(state, 0x8000) ~= 0 or bit.band(state, 0x0001) ~= 0 then
                last_keyboard_time = current_time
                return true
            end
        end

        -- Check mouse middle button (often used while scrolling)
        local mid_state = ffi.C.GetAsyncKeyState(0x04)
        if bit.band(mid_state, 0x8000) ~= 0 then
            last_wheel_time = current_time
            return true
        end
    end

    if current_time - last_keyboard_time < typing_pause_delay then
        return true
    end

    return false
end

---
-- Get the information about display capture sources for the current platform
---@return any
function get_dc_info()
    if ffi.os == "Windows" then
        return {
            source_id = "monitor_capture",
            prop_id = "monitor_id",
            prop_type = "string"
        }
    elseif ffi.os == "Linux" then
        return {
            source_id = "xshm_input",
            prop_id = "screen",
            prop_type = "int"
        }
    elseif ffi.os == "OSX" then
        if major > 29.0 then
            return {
                source_id = "screen_capture",
                prop_id = "display_uuid",
                prop_type = "string"
            }
        else
            return {
                source_id = "display_capture",
                prop_id = "display",
                prop_type = "int"
            }
        end
    end

    return nil
end

---
-- Logs a message to the OBS script console
---@param msg string The message to log
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

---
-- Format the given lua table into a string
---@param tbl any
---@param indent any
---@return string result The formatted string
function format_table(tbl, indent)
    if not indent then
        indent = 0
    end

    local str = "{\n"
    for key, value in pairs(tbl) do
        local tabs = string.rep("  ", indent + 1)
        if type(value) == "table" then
            str = str .. tabs .. key .. " = " .. format_table(value, indent + 1) .. ",\n"
        else
            str = str .. tabs .. key .. " = " .. tostring(value) .. ",\n"
        end
    end
    str = str .. string.rep("  ", indent) .. "}"

    return str
end

---
-- Linear interpolate between v0 and v1
---@param v0 number The start position
---@param v1 number The end position
---@param t number Time
---@return number value The interpolated value
function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t;
end

---
-- Ease a time value in and out
---@param t number Time between 0 and 1
---@return number
function ease_in_out(t)
    t = t * 2
    if t < 1 then
        return 0.5 * t * t * t
    else
        t = t - 2
        return 0.5 * (t * t * t + 2)
    end
end

---
-- Smoothstep interpolation for smoother following
---@param t number Time between 0 and 1
---@return number
function smoothstep(t)
    return t * t * (3 - 2 * t)
end

function smootherstep(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

function ease_in_out_quint(t)
    if t < 0.5 then
        return 16 * t * t * t * t * t
    end

    local inv = -2 * t + 2
    return 1 - (inv * inv * inv * inv * inv) * 0.5
end

function ease_out_expo(t)
    if t >= 1 then
        return 1
    end

    return 1 - math.pow(2, -10 * t)
end

function get_zoom_ease(t)
    local a = smoothstep(t)
    local b = smootherstep(t)
    local c = ease_in_out_quint(t)
    local blended = lerp(a, b, 0.5)
    return lerp(blended, c, zoom_smoothness)
end

function get_follow_lerp_t(current_crop, target_crop)
    local base = smoothstep(clamp(0.01, 1, follow_speed))
    local dx = math.abs(target_crop.x - current_crop.x)
    local dy = math.abs(target_crop.y - current_crop.y)
    local range_x = math.max(1, target_crop.w * 0.35)
    local range_y = math.max(1, target_crop.h * 0.35)
    local distance_ratio = math.max(dx / range_x, dy / range_y)
    local boost = smootherstep(clamp(0, 1, distance_ratio))

    if dx <= 0.75 and dy <= 0.75 then
        return 0
    end

    return clamp(0.02, 0.9, lerp(base, 0.85, boost))
end

function get_crop_center(crop)
    return {
        x = crop.x + crop.w * 0.5,
        y = crop.y + crop.h * 0.5,
    }
end

function copy_crop_rect(crop)
    return {
        x = crop.x,
        y = crop.y,
        w = crop.w,
        h = crop.h,
    }
end

---
-- Process mouse position with smoothing and velocity prediction
---@param raw_pos table Raw mouse position {x, y}
---@return table smoothed_pos Smoothed position with prediction
function process_mouse_position(raw_pos)
    if not use_smooth_follow then
        return raw_pos
    end

    local dt = clamp(1 / 240, 1 / 20, obs.obs_get_frame_interval_ns() / 1000000000.0)

    -- Initialize smoothed position on first call
    if smoothed_mouse_pos == nil or last_follow_raw_pos == nil then
        smoothed_mouse_pos = { x = raw_pos.x, y = raw_pos.y }
        last_follow_raw_pos = { x = raw_pos.x, y = raw_pos.y }
        mouse_velocity_buffer = { x = 0, y = 0 }
        return smoothed_mouse_pos
    end

    local delta_x = raw_pos.x - last_follow_raw_pos.x
    local delta_y = raw_pos.y - last_follow_raw_pos.y

    -- Calculate velocity (for prediction)
    local velocity = {
        x = delta_x / dt,
        y = delta_y / dt
    }

    last_follow_raw_pos.x = raw_pos.x
    last_follow_raw_pos.y = raw_pos.y

    -- Apply exponential smoothing to velocity (reduces jitter)
    mouse_velocity_buffer.x = lerp(mouse_velocity_buffer.x, velocity.x, smooth_factor)
    mouse_velocity_buffer.y = lerp(mouse_velocity_buffer.y, velocity.y, smooth_factor)

    -- Simple prediction: extrapolate based on smoothed velocity
    local predicted_pos = {
        x = raw_pos.x + clamp(-follow_prediction_limit, follow_prediction_limit,
            mouse_velocity_buffer.x * follow_prediction_time),
        y = raw_pos.y + clamp(-follow_prediction_limit, follow_prediction_limit,
            mouse_velocity_buffer.y * follow_prediction_time)
    }

    -- Apply exponential smoothing to position
    smoothed_mouse_pos.x = lerp(smoothed_mouse_pos.x, predicted_pos.x, smooth_factor)
    smoothed_mouse_pos.y = lerp(smoothed_mouse_pos.y, predicted_pos.y, smooth_factor)

    return smoothed_mouse_pos
end

---
-- Clamps a given value between min and max
---@param min number The min value
---@param max number The max value
---@param value number The number to clamp
---@return number result the clamped number
function clamp(min, max, value)
    return math.max(min, math.min(max, value))
end

---
-- Function to calculate GCD (Greatest Common Divisor)
--- @param a number
--- @param b number
function gcd(a, b)
    while b ~= 0 do
        local temp = b
        b = a % b
        a = temp
    end
    return a
end

---
-- Function to convert resolution to aspect ratio
--- @param width number the width of the resolution
--- @param height number the height of the resolution
--- @return number aspect_width, number aspect_height the simplified aspect ratio as two numbers
function resolution_to_aspect_ratio(width, height)
    -- Calculate GCD of width and height
    local divisor = gcd(width, height)
    -- Simplify width and height using GCD
    local aspect_width = width / divisor
    local aspect_height = height / divisor
    return aspect_width, aspect_height
end

function get_alignment_factor(alignment)
    local fx = 0.5
    local fy = 0.5

    if bit.band(alignment, OBS_ALIGN_LEFT) ~= 0 then
        fx = 0
    elseif bit.band(alignment, OBS_ALIGN_RIGHT) ~= 0 then
        fx = 1
    end

    if bit.band(alignment, OBS_ALIGN_TOP) ~= 0 then
        fy = 0
    elseif bit.band(alignment, OBS_ALIGN_BOTTOM) ~= 0 then
        fy = 1
    end

    return fx, fy
end

function get_sceneitem_rect(info, source_width, source_height)
    local draw_w = source_width * info.scale.x
    local draw_h = source_height * info.scale.y
    local box_w = draw_w
    local box_h = draw_h

    if info.bounds_type ~= obs.OBS_BOUNDS_NONE and info.bounds.x > 0 and info.bounds.y > 0 then
        box_w = info.bounds.x
        box_h = info.bounds.y

        if info.bounds_type == obs.OBS_BOUNDS_STRETCH then
            draw_w = box_w
            draw_h = box_h
        elseif info.bounds_type == obs.OBS_BOUNDS_SCALE_INNER then
            local scale = math.min(box_w / source_width, box_h / source_height)
            draw_w = source_width * scale
            draw_h = source_height * scale
        elseif info.bounds_type == obs.OBS_BOUNDS_SCALE_OUTER then
            local scale = math.max(box_w / source_width, box_h / source_height)
            draw_w = source_width * scale
            draw_h = source_height * scale
        elseif info.bounds_type == obs.OBS_BOUNDS_SCALE_TO_WIDTH then
            local scale = box_w / source_width
            draw_w = box_w
            draw_h = source_height * scale
        elseif info.bounds_type == obs.OBS_BOUNDS_SCALE_TO_HEIGHT then
            local scale = box_h / source_height
            draw_w = source_width * scale
            draw_h = box_h
        elseif info.bounds_type == obs.OBS_BOUNDS_MAX_ONLY then
            local scale = math.min(1, math.min(box_w / source_width, box_h / source_height))
            draw_w = source_width * scale
            draw_h = source_height * scale
        else
            draw_w = box_w
            draw_h = box_h
        end
    end

    local align_x, align_y = get_alignment_factor(info.alignment)
    local box_x = info.pos.x - box_w * align_x
    local box_y = info.pos.y - box_h * align_y
    local content_x = box_x
    local content_y = box_y

    if info.bounds_type ~= obs.OBS_BOUNDS_NONE then
        local bounds_align_x, bounds_align_y = get_alignment_factor(info.bounds_alignment)
        content_x = box_x + (box_w - draw_w) * bounds_align_x
        content_y = box_y + (box_h - draw_h) * bounds_align_y
    end

    return {
        x = content_x,
        y = content_y,
        w = draw_w,
        h = draw_h,
    }
end

---
-- Get the size and position of the monitor so that we know the top-left mouse point
---@param source any The OBS source
---@return table|nil monitor_info The monitor size/top-left point
function get_monitor_info(source)
    local info = nil

    -- Only do the expensive look up if we are using automatic calculations on a display source
    if is_display_capture(source) and not use_monitor_override then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            local props = obs.obs_source_properties(source)
            if props ~= nil then
                local monitor_id_prop = obs.obs_properties_get(props, dc_info.prop_id)
                if monitor_id_prop then
                    local found = nil
                    local settings = obs.obs_source_get_settings(source)
                    if settings ~= nil then
                        local to_match
                        if dc_info.prop_type == "string" then
                            to_match = obs.obs_data_get_string(settings, dc_info.prop_id)
                        elseif dc_info.prop_type == "int" then
                            to_match = obs.obs_data_get_int(settings, dc_info.prop_id)
                        end

                        local item_count = obs.obs_property_list_item_count(monitor_id_prop);
                        for i = 0, item_count do
                            local name = obs.obs_property_list_item_name(monitor_id_prop, i)
                            local value
                            if dc_info.prop_type == "string" then
                                value = obs.obs_property_list_item_string(monitor_id_prop, i)
                            elseif dc_info.prop_type == "int" then
                                value = obs.obs_property_list_item_int(monitor_id_prop, i)
                            end

                            if value == to_match then
                                found = name
                                break
                            end
                        end
                        obs.obs_data_release(settings)
                    end

                    -- This works for my machine as the monitor names are given as "U2790B: 3840x2160 @ -1920,0 (Primary Monitor)"
                    -- I don't know if this holds true for other machines and/or OBS versions
                    -- TODO: Update this with some custom FFI calls to find the monitor top-left x and y coordinates if it doesn't work for anyone else
                    -- TODO: Refactor this into something that would work with Windows/Linux/Mac assuming we can't do it like this
                    if found then
                        log("Parsing display name: " .. found)
                        local x, y = found:match("(-?%d+),(-?%d+)")
                        local width, height = found:match("(%d+)x(%d+)")

                        info = { x = 0, y = 0, width = 0, height = 0 }
                        info.x = tonumber(x, 10)
                        info.y = tonumber(y, 10)
                        info.width = tonumber(width, 10)
                        info.height = tonumber(height, 10)
                        info.scale_x = 1
                        info.scale_y = 1
                        info.display_width = info.width
                        info.display_height = info.height

                        log("Parsed the following display information\n" .. format_table(info))

                        if info.width == 0 and info.height == 0 then
                            info = nil
                        end
                    end
                end

                obs.obs_properties_destroy(props)
            end
        end
    end

    if use_monitor_override then
        info = {
            x = monitor_override_x,
            y = monitor_override_y,
            width = monitor_override_w,
            height = monitor_override_h,
            scale_x = monitor_override_sx,
            scale_y = monitor_override_sy,
            display_width = monitor_override_dw,
            display_height = monitor_override_dh
        }
    end

    if not info then
        log("WARNING: Could not auto calculate zoom source position and size.\n" ..
            "         Try using the 'Set manual source position' option and adding override values")
    end

    return info
end

---
-- Check to see if the specified source is a display capture source
-- If the source_to_check is nil then the answer will be false
---@param source_to_check any The source to check
---@return boolean result True if source is a display capture, false if it nil or some other source type
function is_display_capture(source_to_check)
    if source_to_check ~= nil then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            -- Do a quick check to ensure this is a display capture
            if allow_all_sources then
                local source_type = obs.obs_source_get_id(source_to_check)
                if source_type == dc_info.source_id then
                    return true
                end
            else
                return true
            end
        end
    end

    return false
end

---
-- Releases the current sceneitem and resets data back to default
function release_sceneitem()
    if is_timer_running then
        obs.timer_remove(on_timer)
        is_timer_running = false
    end

    zoom_state = ZoomState.None
    current_zoom_level = "none"

    if sceneitem ~= nil then
        toggle_sceneitem_change_listener(false)

        if crop_filter ~= nil and source ~= nil then
            log("Zoom crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end

        if crop_filter_temp ~= nil and source ~= nil then
            log("Conversion crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter_temp)
            obs.obs_source_release(crop_filter_temp)
            crop_filter_temp = nil
        end

        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        if sceneitem_info_orig ~= nil then
            log("Transform info reset back to original")
            suppress_transform_update = true
            obs.obs_sceneitem_set_info2(sceneitem, sceneitem_info_orig)
            suppress_transform_update = false
            sceneitem_info_orig = nil
        end

        sceneitem_info_base = nil
        sceneitem_rect_base = { x = 0, y = 0, w = 0, h = 0 }

        if sceneitem_crop_orig ~= nil then
            log("Transform crop reset back to original")
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop_orig)
            sceneitem_crop_orig = nil
        end

        obs.obs_sceneitem_release(sceneitem)
        sceneitem = nil
    end

    if source ~= nil then
        obs.obs_source_release(source)
        source = nil
    end

    zoom_target = nil
    zoom_anim_start = nil
    crop_filter_info_orig = { x = 0, y = 0, w = 0, h = 0 }
    crop_filter_info = { x = 0, y = 0, w = 0, h = 0 }
end

---
-- Updates the current sceneitem with a refreshed set of data from the source
-- Optionally will release the existing sceneitem and get a new one from the current scene
---@param find_newest boolean True to release the current sceneitem and get a new one
function refresh_sceneitem(find_newest)
    -- TODO: Figure out why we need to get the size from the named source during update instead of via the sceneitem source
    local source_raw = { width = 0, height = 0 }

    if find_newest then
        -- Release the current sceneitem now that we are replacing it
        release_sceneitem()

        -- Quit early if we are using no zoom source
        -- This allows users to reset the crop data back to the original,
        -- update it, and then force the conversion to happen by re-selecting it.
        if source_name == "obs-zoom-to-mouse-none" then
            return
        end

        -- Get a matching source we can use for zooming in the current scene
        log("Finding sceneitem for Zoom Source '" .. source_name .. "'")
        if source_name ~= nil then
            source = obs.obs_get_source_by_name(source_name)
            if source ~= nil then
                -- Get the source size, for some reason this works during load but the sceneitem source doesn't
                source_raw.width = obs.obs_source_get_width(source)
                source_raw.height = obs.obs_source_get_height(source)

                -- Get the current scene
                local scene_source = obs.obs_frontend_get_current_scene()
                if scene_source ~= nil then
                    local function find_scene_item_by_name(root_scene)
                        local queue = {}
                        table.insert(queue, root_scene)

                        while #queue > 0 do
                            local s = table.remove(queue, 1)
                            log("Looking in scene '" .. obs.obs_source_get_name(obs.obs_scene_get_source(s)) .. "'")

                            -- Check if the current scene has the target scene item
                            local found = obs.obs_scene_find_source(s, source_name)
                            if found ~= nil then
                                log("Found sceneitem '" .. source_name .. "'")
                                obs.obs_sceneitem_addref(found)
                                return found
                            end

                            -- If the current scene has nested scenes, enqueue them for later examination
                            local all_items = obs.obs_scene_enum_items(s)
                            if all_items then
                                for _, item in pairs(all_items) do
                                    local nested = obs.obs_sceneitem_get_source(item)
                                    if nested ~= nil then
                                        if obs.obs_source_is_scene(nested) then
                                            local nested_scene = obs.obs_scene_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        elseif obs.obs_source_is_group(nested) then
                                            local nested_scene = obs.obs_group_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        end
                                    end
                                end
                                obs.sceneitem_list_release(all_items)
                            end
                        end

                        return nil
                    end

                    -- Find the sceneitem for the source_name by looking through all the items
                    -- We start at the current scene and use a BFS to look into any nested scenes
                    local current = obs.obs_scene_from_source(scene_source)
                    sceneitem = find_scene_item_by_name(current)
                    toggle_sceneitem_change_listener(true)

                    obs.obs_source_release(scene_source)
                end

                if not sceneitem then
                    log("WARNING: Source not part of the current scene hierarchy.\n" ..
                        "         Try selecting a different zoom source or switching scenes.")
                    toggle_sceneitem_change_listener(false)
                    obs.obs_sceneitem_release(sceneitem)
                    obs.obs_source_release(source)


                    sceneitem = nil
                    source = nil
                    return
                end
            end
        end
    end

    if not monitor_info then
        monitor_info = get_monitor_info(source)
    end

    local is_non_display_capture = not is_display_capture(source)
    if is_non_display_capture then
        if not use_monitor_override then
            log("ERROR: Selected Zoom Source is not a display capture source.\n" ..
                "       You MUST enable 'Set manual source position' and set the correct override values for size and position.")
        end
    end

    if sceneitem ~= nil then
        -- Capture the original settings so we can restore them later
        sceneitem_info_orig = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info_orig)

        sceneitem_crop_orig = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

        sceneitem_info = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info)

        sceneitem_crop = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

        if is_non_display_capture then
            -- Non-Display Capture sources don't correctly report crop values
            sceneitem_crop_orig.left = 0
            sceneitem_crop_orig.top = 0
            sceneitem_crop_orig.right = 0
            sceneitem_crop_orig.bottom = 0
        end

        -- Get the current source size (this will be the value after any applied crop filters)
        if not source then
            log("ERROR: Could not get source for sceneitem (" .. source_name .. ")")
        end

        -- TODO: Figure out why we need this fallback code
        local source_width = obs.obs_source_get_base_width(source)
        local source_height = obs.obs_source_get_base_height(source)

        if source_width == 0 then
            source_width = source_raw.width
        end
        if source_height == 0 then
            source_height = source_raw.height
        end

        if source_width == 0 or source_height == 0 then
            if monitor_info ~= nil and monitor_info.width > 0 and monitor_info.height > 0 then
                log("WARNING: Something went wrong determining source size.\n" ..
                    "         Using source size from info: " .. monitor_info.width .. ", " .. monitor_info.height)
                source_width = monitor_info.width
                source_height = monitor_info.height
            else
                log("ERROR: Something went wrong determining source size.\n" ..
                "       Try using the 'Set manual source position' option and adding override values")
            end
        else
            log("Using source size: " .. source_width .. ", " .. source_height)
        end

        -- Keep the current transform until we finish calculating the visible source size.
        -- We normalize to a top-left Transform model after crop information is resolved.

        -- Get information about any existing crop filters (that aren't ours)
        zoom_info.source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }
        local found_crop_filter = false
        local filters = obs.obs_source_enum_filters(source)
        if filters ~= nil then
            for k, v in pairs(filters) do
                local id = obs.obs_source_get_id(v)
                if id == "crop_filter" then
                    local name = obs.obs_source_get_name(v)
                    if name ~= CROP_FILTER_NAME and name ~= "temp_" .. CROP_FILTER_NAME then
                        found_crop_filter = true
                        local settings = obs.obs_source_get_settings(v)
                        if settings ~= nil then
                            if not obs.obs_data_get_bool(settings, "relative") then
                                zoom_info.source_crop_filter.x =
                                    zoom_info.source_crop_filter.x + obs.obs_data_get_int(settings, "left")
                                zoom_info.source_crop_filter.y =
                                    zoom_info.source_crop_filter.y + obs.obs_data_get_int(settings, "top")
                                zoom_info.source_crop_filter.w =
                                    zoom_info.source_crop_filter.w + obs.obs_data_get_int(settings, "cx")
                                zoom_info.source_crop_filter.h =
                                    zoom_info.source_crop_filter.h + obs.obs_data_get_int(settings, "cy")
                                log("Found existing non-relative crop/pad filter (" ..
                                    name ..
                                    "). Applying settings " .. format_table(zoom_info.source_crop_filter))
                            else
                                log("WARNING: Found existing relative crop/pad filter (" .. name .. ").\n" ..
                                    "         This will cause issues with zooming. Convert to relative settings instead.")
                            end
                            obs.obs_data_release(settings)
                        end
                    end
                end
            end

            obs.source_list_release(filters)
        end

        -- If the user has a transform crop set, we need to convert it into a crop filter so that it works correctly with zooming
        -- Ideally the user does this manually and uses a crop filter instead of the transfrom crop because this might not work 100% of the time
        if not found_crop_filter and (sceneitem_crop_orig.left ~= 0 or sceneitem_crop_orig.top ~= 0 or sceneitem_crop_orig.right ~= 0 or sceneitem_crop_orig.bottom ~= 0) then
            log("Creating new crop filter")

            -- Update the source size
            source_width = source_width - (sceneitem_crop_orig.left + sceneitem_crop_orig.right)
            source_height = source_height - (sceneitem_crop_orig.top + sceneitem_crop_orig.bottom)

            -- Update the source crop filter now that we will be using one
            zoom_info.source_crop_filter.x = sceneitem_crop_orig.left
            zoom_info.source_crop_filter.y = sceneitem_crop_orig.top
            zoom_info.source_crop_filter.w = source_width
            zoom_info.source_crop_filter.h = source_height

            -- Add a new crop filter that emulates the existing transform crop
            local settings = obs.obs_data_create()
            obs.obs_data_set_bool(settings, "relative", false)
            obs.obs_data_set_int(settings, "left", zoom_info.source_crop_filter.x)
            obs.obs_data_set_int(settings, "top", zoom_info.source_crop_filter.y)
            obs.obs_data_set_int(settings, "cx", zoom_info.source_crop_filter.w)
            obs.obs_data_set_int(settings, "cy", zoom_info.source_crop_filter.h)
            crop_filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
            obs.obs_source_filter_add(source, crop_filter_temp)
            obs.obs_data_release(settings)

            -- Clear out the transform crop
            sceneitem_crop.left = 0
            sceneitem_crop.top = 0
            sceneitem_crop.right = 0
            sceneitem_crop.bottom = 0
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop)

            log("WARNING: Found existing transform crop. This may cause issues with zooming.\n" ..
                "         Settings have been auto converted to a relative crop/pad filter instead.\n" ..
                "         If you have issues with your layout consider making the filter manually.")
        elseif found_crop_filter then
            source_width = zoom_info.source_crop_filter.w
            source_height = zoom_info.source_crop_filter.h
        end

        -- Get the rest of the information needed to correctly zoom
        zoom_info.source_size = { width = source_width, height = source_height }
        zoom_info.source_crop = {
            l = sceneitem_crop_orig.left,
            t = sceneitem_crop_orig.top,
            r = sceneitem_crop_orig.right,
            b = sceneitem_crop_orig.bottom
        }
        --log("Transform updated. Using following values -\n" .. format_table(zoom_info))

        if zoom_info.source_size.width <= 0 or zoom_info.source_size.height <= 0 then
            log("ERROR: Invalid source size for transform zoom")
            return
        end

        -- Set the initial visible region data to match the source
        crop_filter_info_orig = { x = 0, y = 0, w = zoom_info.source_size.width, h = zoom_info.source_size.height }
        crop_filter_info = {
            x = crop_filter_info_orig.x,
            y = crop_filter_info_orig.y,
            w = crop_filter_info_orig.w,
            h = crop_filter_info_orig.h
        }

        local sceneitem_rect = get_sceneitem_rect(sceneitem_info, zoom_info.source_size.width, zoom_info.source_size.height)
        sceneitem_info.alignment = OBS_ALIGN_TOP_LEFT
        sceneitem_info.bounds_alignment = OBS_ALIGN_TOP_LEFT
        sceneitem_info.bounds_type = obs.OBS_BOUNDS_NONE
        sceneitem_info.bounds.x = 0
        sceneitem_info.bounds.y = 0
        sceneitem_info.pos.x = sceneitem_rect.x
        sceneitem_info.pos.y = sceneitem_rect.y
        sceneitem_info.scale.x = sceneitem_rect.w / zoom_info.source_size.width
        sceneitem_info.scale.y = sceneitem_rect.h / zoom_info.source_size.height

        suppress_transform_update = true
        obs.obs_sceneitem_set_info2(sceneitem, sceneitem_info)
        suppress_transform_update = false

        sceneitem_info_base = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info_base)
        sceneitem_info = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info)
        sceneitem_rect_base = get_sceneitem_rect(sceneitem_info_base, zoom_info.source_size.width, zoom_info.source_size.height)

        if crop_filter ~= nil and source ~= nil then
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end
        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        set_crop_settings(crop_filter_info_orig)
    end
end

---
-- Get the target position that we will attempt to zoom towards
---@param zoom any
---@return table
function get_target_position(zoom)
    return get_target_position_from_center(zoom, nil)
end

function get_target_position_from_center(zoom, source_center)
    local mouse = get_mouse_pos()

    -- Apply smoothing and velocity prediction
    mouse = process_mouse_position(mouse)

    -- If we have monitor information then we can offset the mouse by the top-left of the monitor position
    -- This is because the display-capture source assumes top-left is 0,0 but the mouse uses the total desktop area,
    -- so a second monitor might start at x:1920, y:0 for example, so when we click at 1920,0 we want it to look like we clicked 0,0 on the source.
    if monitor_info then
        mouse.x = mouse.x - monitor_info.x
        mouse.y = mouse.y - monitor_info.y
    end

    -- Now offset the mouse by the crop top-left because if we cropped 100px off of the display clicking at 100,0 should really be the top-left 0,0
    mouse.x = mouse.x - zoom.source_crop_filter.x
    mouse.y = mouse.y - zoom.source_crop_filter.y

    -- If the source uses a different scale to the display, apply that now.
    -- This can happen with cloned sources, where it is cloning a scene that has a full screen display.
    -- The display will be the full desktop pixel size, but the cloned scene will be scaled down to the canvas,
    -- so we need to scale down the mouse movement to match
    if monitor_info and monitor_info.scale_x and monitor_info.scale_y then
        mouse.x = mouse.x * monitor_info.scale_x
        mouse.y = mouse.y * monitor_info.scale_y
    end

    if source_center ~= nil then
        mouse = {
            x = source_center.x,
            y = source_center.y,
        }
    end

    -- Get the new size after we zoom
    -- Remember that because we are using a crop/pad filter making the size smaller (dividing by zoom) means that we see less of the image
    -- in the same amount of space making it look bigger (aka zoomed in)
    local new_size = {
        width = (
            --  if should keep shape, use aspect ratio to get new width
            keep_shape and (zoom.source_size.height * (aspect_ratio_w / aspect_ratio_h))
            --  else use source resolution
            or  zoom.source_size.width
        ) / zoom.zoom_to,
        height = zoom.source_size.height / zoom.zoom_to
    }

    -- New offset for the crop/pad filter is whereever we clicked minus half the size, so that the clicked point because the new center
    local bias_x = 0
    local bias_y = 0
    if source_center == nil then
        bias_x = composition_bias_x
        bias_y = composition_bias_y
    end

    local pos = {
        x = mouse.x - new_size.width * (0.5 + bias_x),
        y = mouse.y - new_size.height * (0.5 + bias_y)
    }

    -- Create the full crop results
    local crop = {
        x = pos.x,
        y = pos.y,
        w = new_size.width,
        h = new_size.height,
    }

    -- Keep the zoom in bounds of the source so that we never show something outside that user is trying to hide with existing crop settings
    crop.x = math.floor(clamp(0, (zoom.source_size.width - new_size.width), crop.x))
    crop.y = math.floor(clamp(0, (zoom.source_size.height - new_size.height), crop.y))

    return { crop = crop, raw_center = mouse, clamped_center = { x = math.floor(crop.x + crop.w * 0.5), y = math.floor(crop.y + crop.h * 0.5) } }
end

function on_toggle_follow(pressed)
    if pressed then
        pending_auto_follow = false
        follow_activation_timer = 0
        is_following_mouse = not is_following_mouse
        log("Tracking mouse is " .. (is_following_mouse and "on" or "off"))

        if is_following_mouse and zoom_state == ZoomState.ZoomedIn then
            -- Since we are zooming we need to start the timer for the animation and tracking
            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function start_zoom_timer()
    if is_timer_running == false then
        is_timer_running = true
        local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
        obs.timer_add(on_timer, timer_interval)
    end
end

function on_toggle_tier_zoom(pressed)
    if not pressed then
        return
    end

    if not use_tier_zoom then
        log("Tier zoom is disabled")
        return
    end

    if sceneitem == nil or sceneitem_info_base == nil or crop_filter_info_orig.w <= 0 or crop_filter_info_orig.h <= 0 then
        log("WARNING: Zoom source is not ready yet")
        return
    end

    mouse_idle_timer = 0
    is_mouse_idle = false
    last_mouse_pos = nil
    smoothed_mouse_pos = nil
    mouse_velocity_buffer = { x = 0, y = 0 }
    last_follow_raw_pos = nil
    pending_auto_follow = false
    follow_activation_timer = 0
    was_auto_zoomed_out = false

    if keep_shape then
        update_aspect_ratio()
    end

    locked_center = nil
    locked_last_pos = nil
    zoom_time = 0
    zoom_anim_start = copy_crop_rect(crop_filter_info)

    if zoom_state == ZoomState.None or zoom_state == ZoomState.ZoomingOut then
        log("Tier zoom: none -> tier (" .. zoom_value_tier .. "x)")
        zoom_info.zoom_to = zoom_value_tier
        zoom_state = ZoomState.ZoomingIn
        current_zoom_level = "tier"
        zoom_target = get_target_position(zoom_info)
        start_zoom_timer()
    elseif current_zoom_level == "tier" then
        log("Tier zoom: tier (" .. zoom_value_tier .. "x) -> max (" .. zoom_value .. "x)")
        zoom_info.zoom_to = zoom_value
        zoom_state = ZoomState.ZoomingIn
        current_zoom_level = "max"
        zoom_target = get_target_position_from_center(zoom_info, get_crop_center(crop_filter_info))
        start_zoom_timer()
    else
        log("Tier zoom: max (" .. zoom_value .. "x) -> tier (" .. zoom_value_tier .. "x)")
        zoom_info.zoom_to = zoom_value_tier
        zoom_state = ZoomState.ZoomingIn
        current_zoom_level = "tier"
        zoom_target = get_target_position_from_center(zoom_info, get_crop_center(crop_filter_info))
        start_zoom_timer()
    end
end

function on_toggle_auto_zoom_out(pressed)
    if pressed then
        use_auto_zoom_out = not use_auto_zoom_out
        log("Auto zoom-out is " .. (use_auto_zoom_out and "on" or "off"))
        -- Reset mouse idle timer when toggled
        mouse_idle_timer = 0
        is_mouse_idle = false
    end
end

function on_toggle_zoom(pressed, force_value)
    if pressed or force_value then
        if sceneitem == nil or sceneitem_info_base == nil or crop_filter_info_orig.w <= 0 or crop_filter_info_orig.h <= 0 then
            log("WARNING: Zoom source is not ready yet")
            return
        end

        -- Reset mouse idle timer when zoom is toggled
        mouse_idle_timer = 0
        is_mouse_idle = false
        last_mouse_pos = nil
        -- Reset smooth follow buffer
        smoothed_mouse_pos = nil
        mouse_velocity_buffer = { x = 0, y = 0 }
        last_follow_raw_pos = nil
        pending_auto_follow = false
        follow_activation_timer = 0

        -- If this is a manual toggle (not auto), reset the auto zoom out flag
        if force_value == nil then
            was_auto_zoomed_out = false
        end

        -- Check if we are in a safe state to zoom
        if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.None or force_value then
            local should_zoom = (force_value ~= nil) and force_value or (zoom_state ~= ZoomState.ZoomedIn)
            if not should_zoom then
                log("Zooming out")
                -- To zoom out, we set the target back to whatever it was originally
                zoom_state = ZoomState.ZoomingOut
                current_zoom_level = "none"
                zoom_time = 0
                zoom_anim_start = copy_crop_rect(crop_filter_info)
                locked_center = nil
                locked_last_pos = nil
                zoom_target = {
                    crop = {
                        x = crop_filter_info_orig.x,
                        y = crop_filter_info_orig.y,
                        w = crop_filter_info_orig.w,
                        h = crop_filter_info_orig.h
                    },
                    c = sceneitem_crop_orig
                }
                if is_following_mouse then
                    is_following_mouse = false
                    log("Tracking mouse is off (due to zoom out)")
                end
            else
                log("Zooming in")
                -- To zoom in, we get a new target based on where the mouse was when zoom was clicked
                if keep_shape then
                    update_aspect_ratio()
                end
                zoom_state = ZoomState.ZoomingIn
                current_zoom_level = "max"
                zoom_info.zoom_to = zoom_value
                zoom_time = 0
                zoom_anim_start = copy_crop_rect(crop_filter_info)
                locked_center = nil
                locked_last_pos = nil
                zoom_target = get_target_position(zoom_info)
            end

            -- Since we are zooming we need to start the timer for the animation and tracking
            start_zoom_timer()
        end
    end
end

function on_timer()
    if crop_filter_info ~= nil and zoom_target ~= nil then
        -- Update our zoom time that we use for the animation
        zoom_time = zoom_time + zoom_speed

        if zoom_state == ZoomState.ZoomingOut or zoom_state == ZoomState.ZoomingIn then
            -- When we are doing a zoom animation (in or out) we interpolate from the captured
            -- start state to the target with a smoother cinematic easing curve.
            if zoom_time <= 1 then
                -- If we have auto-follow turned on, make sure to keep the mouse in the view while we zoom
                -- This is incase the user is moving the mouse a lot while the animation (which may be slow) is playing
                if zoom_state == ZoomState.ZoomingIn and use_auto_follow_mouse then
                    zoom_target = get_target_position(zoom_info)
                end

                local eased_t = get_zoom_ease(clamp(0, 1, zoom_time))
                local anim_from = zoom_anim_start or crop_filter_info_orig

                crop_filter_info.x = lerp(anim_from.x, zoom_target.crop.x, eased_t)
                crop_filter_info.y = lerp(anim_from.y, zoom_target.crop.y, eased_t)
                crop_filter_info.w = lerp(anim_from.w, zoom_target.crop.w, eased_t)
                crop_filter_info.h = lerp(anim_from.h, zoom_target.crop.h, eased_t)
                set_crop_settings(crop_filter_info)
            end
        else
            -- Check for mouse idle when zoomed in and auto_zoom_out is enabled
            if zoom_state == ZoomState.ZoomedIn and use_auto_zoom_out then
                local current_mouse = get_mouse_pos()
                if last_mouse_pos ~= nil then
                    local dx = math.abs(current_mouse.x - last_mouse_pos.x)
                    local dy = math.abs(current_mouse.y - last_mouse_pos.y)
                    if dx < 3 and dy < 3 then
                        if is_user_typing() then
                            mouse_idle_timer = 0
                            is_mouse_idle = false
                        else
                            mouse_idle_timer = mouse_idle_timer + (obs.obs_get_frame_interval_ns() / 1000000000.0)
                            if mouse_idle_timer >= auto_zoom_out_delay and not is_mouse_idle then
                                is_mouse_idle = true
                                was_auto_zoomed_out = true
                                log("Mouse idle for " .. auto_zoom_out_delay .. " seconds, auto zooming out")
                                on_toggle_zoom(true, false)
                            end
                        end
                    else
                        mouse_idle_timer = 0
                        is_mouse_idle = false
                    end
                end
                last_mouse_pos = { x = current_mouse.x, y = current_mouse.y }
            end

            -- Check for mouse movement to auto zoom back in after auto zoom out
            if zoom_state == ZoomState.None and use_auto_zoom_out and was_auto_zoomed_out then
                local current_mouse = get_mouse_pos()
                if last_mouse_pos ~= nil then
                    local dx = math.abs(current_mouse.x - last_mouse_pos.x)
                    local dy = math.abs(current_mouse.y - last_mouse_pos.y)
                    if dx > 5 or dy > 5 then
                        was_auto_zoomed_out = false
                        log("Mouse moved, auto zooming back in")
                        on_toggle_zoom(true, true)
                    end
                end
                last_mouse_pos = { x = current_mouse.x, y = current_mouse.y }
            end

            -- If we are not zooming we only move the x/y to follow the mouse (width/height stay constant)
            if is_following_mouse then
                zoom_target = get_target_position(zoom_info)

                local skip_frame = false
                if not use_follow_outside_bounds then
                    if zoom_target.raw_center.x < zoom_target.crop.x or
                        zoom_target.raw_center.x > zoom_target.crop.x + zoom_target.crop.w or
                        zoom_target.raw_center.y < zoom_target.crop.y or
                        zoom_target.raw_center.y > zoom_target.crop.y + zoom_target.crop.h then
                        -- Don't follow the mouse if we are outside the bounds of the source
                        skip_frame = true
                    end
                end

                if not skip_frame then
                    -- If we have a locked_center it means we are currently in a locked zone and
                    -- shouldn't track the mouse until it moves out of the area
                    if locked_center ~= nil then
                        local diff = {
                            x = zoom_target.raw_center.x - locked_center.x,
                            y = zoom_target.raw_center.y - locked_center.y
                        }

                        local track = {
                            x = zoom_target.crop.w * (0.5 - (follow_border * 0.01)),
                            y = zoom_target.crop.h * (0.5 - (follow_border * 0.01))
                        }

                        if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                            -- Cursor moved into the active border area, so resume tracking by clearing out the locked_center
                            locked_center = nil
                            locked_last_pos = {
                                x = zoom_target.raw_center.x,
                                y = zoom_target.raw_center.y,
                                diff_x = diff.x,
                                diff_y = diff.y
                            }
                            log("Locked area exited - resume tracking")
                        end
                    end

                    if locked_center == nil and (zoom_target.crop.x ~= crop_filter_info.x or zoom_target.crop.y ~= crop_filter_info.y) then
                        local diff_x = math.abs(crop_filter_info.x - zoom_target.crop.x)
                        local diff_y = math.abs(crop_filter_info.y - zoom_target.crop.y)

                        if diff_x <= 0.75 and diff_y <= 0.75 then
                            crop_filter_info.x = zoom_target.crop.x
                            crop_filter_info.y = zoom_target.crop.y
                        else
                            local smooth_t = get_follow_lerp_t(crop_filter_info, zoom_target.crop)
                            crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, smooth_t)
                            crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, smooth_t)
                        end

                        set_crop_settings(crop_filter_info)

                        -- Check to see if the mouse has stopped moving long enough to create a new safe zone
                        if is_following_mouse and locked_center == nil and locked_last_pos ~= nil then
                            local diff = {
                                x = math.abs(crop_filter_info.x - zoom_target.crop.x),
                                y = math.abs(crop_filter_info.y - zoom_target.crop.y),
                                auto_x = zoom_target.raw_center.x - locked_last_pos.x,
                                auto_y = zoom_target.raw_center.y - locked_last_pos.y
                            }

                            locked_last_pos.x = zoom_target.raw_center.x
                            locked_last_pos.y = zoom_target.raw_center.y

                            local lock = false
                            if math.abs(locked_last_pos.diff_x) > math.abs(locked_last_pos.diff_y) then
                                if (diff.auto_x < 0 and locked_last_pos.diff_x > 0) or (diff.auto_x > 0 and locked_last_pos.diff_x < 0) then
                                    lock = true
                                end
                            else
                                if (diff.auto_y < 0 and locked_last_pos.diff_y > 0) or (diff.auto_y > 0 and locked_last_pos.diff_y < 0) then
                                    lock = true
                                end
                            end

                            if (lock and use_follow_auto_lock) or (diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity) then
                                -- Make the new center the position of the current camera (which might not be the same as the mouse since we lerp towards it)
                                locked_center = {
                                    x = math.floor(crop_filter_info.x + zoom_target.crop.w * 0.5),
                                    y = math.floor(crop_filter_info.y + zoom_target.crop.h * 0.5)
                                }
                                log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                            end
                        end
                    end
                end
            end
        end

        -- Check to see if the animation is over
        if zoom_time >= 1 then
            local should_stop_timer = false

            crop_filter_info.x = zoom_target.crop.x
            crop_filter_info.y = zoom_target.crop.y
            crop_filter_info.w = zoom_target.crop.w
            crop_filter_info.h = zoom_target.crop.h
            set_crop_settings(crop_filter_info)

            -- When we finished zooming out we remove the timer
            if zoom_state == ZoomState.ZoomingOut then
                log("Zoomed out")
                zoom_state = ZoomState.None
                current_zoom_level = "none"
                zoom_anim_start = nil
                -- Don't stop timer if we need to watch for mouse movement to zoom back in
                should_stop_timer = not (use_auto_zoom_out and was_auto_zoomed_out)
            elseif zoom_state == ZoomState.ZoomingIn then
                log("Zoomed in")
                zoom_state = ZoomState.ZoomedIn
                zoom_anim_start = nil
                pending_auto_follow = false
                follow_activation_timer = 0
                -- If we finished zooming in and we arent tracking the mouse we can also remove the timer
                should_stop_timer = (not use_auto_follow_mouse) and (not is_following_mouse)

                if use_auto_follow_mouse then
                    pending_auto_follow = false
                    follow_activation_timer = 0
                    is_following_mouse = true
                    log("Tracking mouse is " .. (is_following_mouse and "on" or "off") .. " (due to auto follow)")
                end

                -- We set the current position as the center for the follow safezone
                if is_following_mouse and follow_border < 50 then
                    zoom_target = get_target_position(zoom_info)
                    locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                    log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                end
            end

            if should_stop_timer then
                is_timer_running = false
                obs.timer_remove(on_timer)
            end
        end
    end
end

function on_socket_timer()
    if not socket_server then
        return
    end

    repeat
        local data, status = socket_server:receive_from()
        if data then
            local sx, sy = data:match("(-?%d+) (-?%d+)")
            if sx and sy then
                local x = tonumber(sx, 10)
                local y = tonumber(sy, 10)
                if not socket_mouse then
                    log("Socket server client connected")
                    socket_mouse = { x = x, y = y }
                else
                    socket_mouse.x = x
                    socket_mouse.y = y
                end
            end
        elseif status ~= "timeout" then
            error(status)
        end
    until data == nil
end

function start_server()
    if socket_available then
        local address = socket.find_first_address("*", socket_port)

        socket_server = socket.create("inet", "dgram", "udp")
        if socket_server ~= nil then
            socket_server:set_option("reuseaddr", 1)
            socket_server:set_blocking(false)
            socket_server:bind(address, socket_port)
            obs.timer_add(on_socket_timer, socket_poll)
            log("Socket server listening on port " .. socket_port .. "...")
        end
    end
end

function stop_server()
    if socket_server ~= nil then
        log("Socket server stopped")
        obs.timer_remove(on_socket_timer)
        socket_server:close()
        socket_server = nil
        socket_mouse = nil
    end
end

function set_crop_settings(crop)
    if sceneitem ~= nil and sceneitem_info ~= nil and sceneitem_info_base ~= nil and crop.w > 0 and crop.h > 0 then
        local scale_x = sceneitem_info_base.scale.x * (zoom_info.source_size.width / crop.w)
        local scale_y = sceneitem_info_base.scale.y * (zoom_info.source_size.height / crop.h)

        sceneitem_info.alignment = OBS_ALIGN_TOP_LEFT
        sceneitem_info.bounds_alignment = OBS_ALIGN_TOP_LEFT
        sceneitem_info.bounds_type = obs.OBS_BOUNDS_NONE
        sceneitem_info.bounds.x = 0
        sceneitem_info.bounds.y = 0
        sceneitem_info.pos.x = sceneitem_rect_base.x - crop.x * scale_x
        sceneitem_info.pos.y = sceneitem_rect_base.y - crop.y * scale_y
        sceneitem_info.scale.x = scale_x
        sceneitem_info.scale.y = scale_y

        suppress_transform_update = true
        obs.obs_sceneitem_set_info2(sceneitem, sceneitem_info)
        suppress_transform_update = false
    end
end

function on_transition_start(t)
    log("Transition started")
    -- We need to remove the crop from the sceneitem as the transition starts to avoid
    -- a delay with the rendering where you see the old crop and jump to the new one
    release_sceneitem()
    
    -- Ensure to restart filters on scene change back
    if is_obs_loaded and source_name ~= "" and source_name ~= "obs-zoom-to-mouse-none" and auto_start and not auto_start_running then
        log("Auto starting after transition")
        auto_start_running = true
        local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 100000)
        obs.timer_add(wait_for_auto_start, timer_interval)
    end    
end

function update_aspect_ratio()
    if keep_shape == nil or not keep_shape or sceneitem == nil or sceneitem_rect_base.w <= 0 or sceneitem_rect_base.h <= 0 then
        return
    end

    aspect_ratio_w, aspect_ratio_h = resolution_to_aspect_ratio(
        sceneitem_rect_base.w, sceneitem_rect_base.h
    )
end

function on_transform_update()
    if suppress_transform_update then
        return
    end

    if zoom_state == ZoomState.None then
        refresh_sceneitem(false)
        return
    end

    update_aspect_ratio()
    if keep_shape then
        if zoom_state == ZoomState.ZoomedIn then
            -- Perform zoom again
            zoom_state = ZoomState.ZoomingIn
            zoom_info.zoom_to = zoom_value
            zoom_time = 0
            zoom_target = get_target_position(zoom_info)
        end
    end
end

function toggle_sceneitem_change_listener(value)
    local scene = obs.obs_sceneitem_get_scene(sceneitem)
    local scene_source = obs.obs_scene_get_source(scene)
    local handler = obs.obs_source_get_signal_handler(scene_source)
    if value then
        update_aspect_ratio()
        obs.signal_handler_connect(handler, "item_transform", on_transform_update)
    else
        obs.signal_handler_disconnect(handler, on_transform_update)
    end
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("OBS Scene changed")
        -- If the scene changes we attempt to find a new source with the same name in this new scene
        -- TODO: There probably needs to be a way for users to specify what source they want to use in each scene
        -- Scene change can happen before OBS has completely loaded, so we check for that here
        if is_obs_loaded then
            refresh_sceneitem(true)
        end
    elseif event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        log("OBS Loaded")
        -- Once loaded we perform our initial lookup
        is_obs_loaded = true
        monitor_info = get_monitor_info(source)
        refresh_sceneitem(true)
        
        -- Auto start zoom after OBS is fully loaded
        if source_name ~= "" and source_name ~= "obs-zoom-to-mouse-none" and auto_start and not auto_start_running then
            log("Auto starting after OBS loaded")
            auto_start_running = true
            local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 100000)
            obs.timer_add(wait_for_auto_start, timer_interval)
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        log("OBS Shutting down")
        -- Add a fail-safe for unloading the script during shutdown
        if is_script_loaded then
            script_unload()
        end
    end
end

function on_update_transform()
    -- Update the crop/size settings based on whatever the source in the current scene looks like
    if is_obs_loaded then
        refresh_sceneitem(true)
    end

    return true
end

function on_settings_modified(props, prop, settings)
    local name = obs.obs_property_name(prop)

    -- Show/Hide the settings based on if the checkbox is checked or not
    if name == "use_monitor_override" then
        local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_x"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_y"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_w"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_h"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sx"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sy"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dw"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dh"), visible)
        return true
    elseif name == "use_tier_zoom" then
        local visible = obs.obs_data_get_bool(settings, "use_tier_zoom")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "zoom_value_tier"), visible)
        return true
    elseif name == "use_socket" then
        local visible = obs.obs_data_get_bool(settings, "use_socket")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_port"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_poll"), visible)
        return true
    elseif name == "allow_all_sources" then
        local sources_list = obs.obs_properties_get(props, "source")
        populate_zoom_sources(sources_list)
        return true
    elseif name == "keep_shape" then
        on_transform_update()
    elseif name == "debug_logs" then
        if obs.obs_data_get_bool(settings, "debug_logs") then
            log_current_settings()
        end
    end

    return false
end

---
-- Write the current settings into the log for debugging and user issue reports
function log_current_settings()
    local settings = {
        zoom_value = zoom_value,
        zoom_speed = zoom_speed,
        auto_start = auto_start,
        keep_shape = keep_shape,
        use_auto_follow_mouse = use_auto_follow_mouse,
        use_follow_outside_bounds = use_follow_outside_bounds,
        follow_speed = follow_speed,
        follow_border = follow_border,
        follow_safezone_sensitivity = follow_safezone_sensitivity,
        use_follow_auto_lock = use_follow_auto_lock,
        follow_activation_delay = follow_activation_delay,
        composition_bias_x = composition_bias_x,
        composition_bias_y = composition_bias_y,
        use_tier_zoom = use_tier_zoom,
        zoom_value_tier = zoom_value_tier,
        use_auto_zoom_out = use_auto_zoom_out,
        auto_zoom_out_delay = auto_zoom_out_delay,
        use_detect_typing = use_detect_typing,
        typing_pause_delay = typing_pause_delay,
        use_monitor_override = use_monitor_override,
        monitor_override_x = monitor_override_x,
        monitor_override_y = monitor_override_y,
        monitor_override_w = monitor_override_w,
        monitor_override_h = monitor_override_h,
        monitor_override_sx = monitor_override_sx,
        monitor_override_sy = monitor_override_sy,
        monitor_override_dw = monitor_override_dw,
        monitor_override_dh = monitor_override_dh,
        use_socket = use_socket,
        socket_port = socket_port,
        socket_poll = socket_poll,
        debug_logs = debug_logs,
        version = VERSION
    }

    log("OBS Version: " .. string.format("%.1f", major) .. "." .. minor)
    log("Platform: " .. ffi.os)
    log("Current settings:")
    log(format_table(settings))
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "OBS鼠标缩放 v" .. VERSION .. " 帮助信息\n" ..
        "细K B站：https://space.bilibili.com/3546772855064749\n" ..
        "原作者GitHub：https://github.com/BlankSourceCode/obs-zoom-to-mouse\n" ..
        "----------------------------------------------------\n" ..
        "此脚本将缩放选定的显示器捕获源以聚焦于鼠标位置\n\n" ..
        "=== 快捷键 ===\n" ..
        "切换鼠标缩放：放大/缩小（原始状态：原始→最大→原始）\n" ..
        "切换二级缩放：在二级缩放和最大缩放之间切换\n" ..
        "切换缩放时跟随鼠标：开启/关闭跟随鼠标\n" ..
        "切换鼠标静止自动缩小：开启/关闭自动缩小功能\n\n" ..
        "=== 设置 ===\n" ..
        "缩放源：当前场景中用于缩放的显示器捕获源\n" ..
        "缩放倍率：缩放的程度（最大缩放倍数）\n" ..
        "启用二级缩放：开启二级缩放系统（中间档位）\n" ..
        "二级缩放倍数：二级缩放的热键第一段倍率\n" ..
        "缩放速度：缩放/缩小动画的速度\n" ..
        "缩放丝滑度：使用更柔和的缓动曲线（Screen Studio风格）\n" ..
        "OBS启动时自动缩放：OBS启动时自动激活缩放\n" ..
        "动态宽高比：根据画布源大小调整缩放宽高比\n" ..
        "自动跟随鼠标：缩放时自动跟踪光标\n" ..
        "边界外跟随：即使光标在缩放源边界外也跟踪\n" ..
        "跟随速度：缩放区域跟踪鼠标的速度\n" ..
        "跟随边界：从源边缘重新启用鼠标跟踪的距离百分比\n" ..
        "锁定灵敏度：跟踪需要多接近才会锁定位置并停止跟踪\n" ..
        "反向自动锁定：如果反转鼠标方向则自动停止跟踪\n" ..
        "平滑跟随：使用速度预测和缓动函数使跟随更丝滑\n" ..
        "平滑系数：控制平滑程度（值越小越平滑，值越大越灵敏）\n" ..
        "跟随回弹强度：控制跟随时的预判量（越大越有提前量）\n" ..
        "回弹最大像素：限制预判位移上限\n" ..
        "鼠标静止自动缩小：当鼠标静止超过指定时间后自动缩小\n" ..
        "静止延迟：鼠标静止多长时间后自动缩小\n" ..
        "检测键盘输入：检测到键盘输入时不会自动缩小\n" ..
        "输入暂停延迟：停止输入后多长时间才允许自动缩小\n" ..
        "允许任意缩放源：允许选择任何源作为缩放源\n" ..
        "设置手动源位置：覆盖自动计算的值\n" ..
        "X/Y：源左上角的坐标\n" ..
        "宽度/高度：源的像素大小\n" ..
        "缩放X/Y：鼠标位置的缩放因子（用于克隆源）\n" ..
        "显示器宽度/高度：显示器的分辨率\n"

    if socket_available then
        help = help ..
            "启用远程鼠标监听：启动UDP服务器接收远程鼠标位置\n" ..
            "端口：套接字服务器使用的端口号\n" ..
            "轮询延迟：更新鼠标位置之间的时间（毫秒）\n"
    end

    help = help ..
        "启用调试日志：在脚本日志中显示额外的调试信息\n\n"

    obs.script_log(obs.OBS_LOG_INFO, help)
end

function script_description()
    return "将选定的显示器捕获源缩放到鼠标位置【B站-细Kei】"
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Populate the sources list with the known display-capture sources (OBS calls them 'monitor_capture' internally even though the UI says 'Display Capture')
    local sources_list = obs.obs_properties_add_list(props, "source", "缩放源", obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)

    populate_zoom_sources(sources_list)

    local refresh_sources = obs.obs_properties_add_button(props, "refresh", "刷新缩放源",
        function()
            populate_zoom_sources(sources_list)
            monitor_info = get_monitor_info(source)
            return true
        end)
    obs.obs_property_set_long_description(refresh_sources,
        "点击重新填充可用的缩放源下拉列表")

    local zoom = obs.obs_properties_add_float(props, "zoom_value", "缩放倍率", 1, 5, 0.5)
    local tier_zoom = obs.obs_properties_add_bool(props, "use_tier_zoom", "启用二级缩放")
    local tier_zoom_value = obs.obs_properties_add_float(props, "zoom_value_tier", "二级缩放倍数", 1, 5, 0.5)

    obs.obs_property_set_long_description(tier_zoom_value,
        "二级缩放热键的第一段倍率；再次触发会进入主缩放倍数，第三次回到第一段倍率")
    local zoom_speed = obs.obs_properties_add_float_slider(props, "zoom_speed", "缩放速度", 0.01, 1, 0.01)

    local auto_start = obs.obs_properties_add_bool(props, "auto_start", "OBS启动时自动缩放 ")
    obs.obs_property_set_long_description(auto_start,
        "启用后，OBS启动时将尽快自动激活缩放")

    local keep_shape = obs.obs_properties_add_bool(props, "keep_shape", "动态宽高比 ")
    obs.obs_property_set_long_description(keep_shape,
        "启用后，缩放将跟随画布中源的宽高比")

    local follow = obs.obs_properties_add_bool(props, "follow", "自动跟随鼠标 ")
    obs.obs_property_set_long_description(follow,
        "启用后，缩放时鼠标跟踪将自动开始，无需等待跟踪切换热键")

    local follow_outside_bounds = obs.obs_properties_add_bool(props, "follow_outside_bounds", "边界外跟随 ")
    obs.obs_property_set_long_description(follow_outside_bounds,
        "启用后，即使光标在缩放源边界外也会跟踪鼠标")

    local follow_speed = obs.obs_properties_add_float_slider(props, "follow_speed", "跟随速度", 0.01, 1, 0.01)
    local follow_border = obs.obs_properties_add_int_slider(props, "follow_border", "跟随边界", 0, 50, 1)
    local safezone_sense = obs.obs_properties_add_int_slider(props,
        "follow_safezone_sensitivity", "锁定灵敏度", 1, 20, 1)
    local follow_auto_lock = obs.obs_properties_add_bool(props, "follow_auto_lock", "反向自动锁定 ")
    obs.obs_property_set_long_description(follow_auto_lock,
        "启用后，将鼠标移动到缩放源边缘将开始跟踪，\n" ..
        "但向中心移回将停止跟踪，类似于 RTS 游戏中的镜头平移")

    local smooth_follow = obs.obs_properties_add_bool(props, "use_smooth_follow", "平滑跟随")
    obs.obs_property_set_long_description(smooth_follow,
        "启用后，使用速度预测和缓动函数使跟随更丝滑")

    local smooth_factor_prop = obs.obs_properties_add_float_slider(props, "smooth_factor", "平滑系数", 0.1, 1, 0.05)
    obs.obs_property_set_long_description(smooth_factor_prop,
        "值越小跟随越延迟（更平滑），值越大跟随越灵敏（更直接）")
    local follow_prediction_time_prop = obs.obs_properties_add_float_slider(props, "follow_prediction_time", "跟随回弹强度", 0, 0.08, 0.001)
    obs.obs_property_set_long_description(follow_prediction_time_prop,
        "控制跟随时的预判量；越大越有提前量和回弹感，设为 0 可基本关闭回弹")
    
    local follow_prediction_limit_prop = obs.obs_properties_add_int_slider(props, "follow_prediction_limit", "回弹最大像素", 0, 200, 1)
    obs.obs_property_set_long_description(follow_prediction_limit_prop,
        "限制预判位移上限，避免快速甩动鼠标时回弹过大")
    
    local zoom_smoothness_prop = obs.obs_properties_add_float_slider(props, "zoom_smoothness", "缩放丝滑度", 0, 1, 0.05)
    obs.obs_property_set_long_description(zoom_smoothness_prop,
        "提高后会使用更柔和的缓动曲线，让缩放更接近 Screen Studio 风格")

    local auto_zoom_out = obs.obs_properties_add_bool(props, "auto_zoom_out", "鼠标静止自动缩小 ")
    obs.obs_property_set_long_description(auto_zoom_out,
        "启用后，当鼠标静止超过指定时间后自动缩小回原始倍率")

    local auto_zoom_out_delay = obs.obs_properties_add_float(props, "auto_zoom_out_delay", "静止延迟(秒) ", 1, 30, 0.5)
    obs.obs_property_set_long_description(auto_zoom_out_delay,
        "鼠标静止多长时间后自动缩小回原始倍率")

    local detect_typing = obs.obs_properties_add_bool(props, "detect_typing", "检测键盘输入 ")
    obs.obs_property_set_long_description(detect_typing,
        "启用后，检测到键盘输入时不会自动缩小（方便放大查看正在输入的内容）")

    local typing_pause_delay_prop = obs.obs_properties_add_float(props, "typing_pause_delay", "输入暂停延迟(秒) ", 1, 30, 0.5)
    obs.obs_property_set_long_description(typing_pause_delay_prop,
        "停止输入后多长时间才允许自动缩小")


    local allow_all = obs.obs_properties_add_bool(props, "allow_all_sources", "允许任意缩放源 ")
    obs.obs_property_set_long_description(allow_all, "启用后允许选择任何源作为缩放源\n" ..
        "对于非显示器捕获源，必须设置手动源位置")

    local override_props = obs.obs_properties_create();
    local override_label = obs.obs_properties_add_text(override_props, "monitor_override_label", "", obs.OBS_TEXT_INFO)
    local override_x = obs.obs_properties_add_int(override_props, "monitor_override_x", "X", -10000, 10000, 1)
    local override_y = obs.obs_properties_add_int(override_props, "monitor_override_y", "Y", -10000, 10000, 1)
    local override_w = obs.obs_properties_add_int(override_props, "monitor_override_w", "宽度", 0, 10000, 1)
    local override_h = obs.obs_properties_add_int(override_props, "monitor_override_h", "高度", 0, 10000, 1)
    local override_sx = obs.obs_properties_add_float(override_props, "monitor_override_sx", "缩放X ", 0, 100, 0.01)
    local override_sy = obs.obs_properties_add_float(override_props, "monitor_override_sy", "缩放Y ", 0, 100, 0.01)
    local override_dw = obs.obs_properties_add_int(override_props, "monitor_override_dw", "显示器宽度 ", 0, 10000, 1)
    local override_dh = obs.obs_properties_add_int(override_props, "monitor_override_dh", "显示器高度 ", 0, 10000, 1)
    local override = obs.obs_properties_add_group(props, "use_monitor_override", "设置手动源位置 ",
        obs.OBS_GROUP_CHECKABLE, override_props)

    obs.obs_property_set_long_description(override_label,
        "启用后将使用指定的大小/位置设置作为缩放源，而不是自动计算的值")
    obs.obs_property_set_long_description(override_sx, "通常为1 - 除非您使用的是缩放源")
    obs.obs_property_set_long_description(override_sy, "通常为1 - 除非您使用的是缩放源")
    obs.obs_property_set_long_description(override_dw, "显示器的X分辨率")
    obs.obs_property_set_long_description(override_dh, "显示器的Y分辨率")

    if socket_available then
        local socket_props = obs.obs_properties_create();
        local r_label = obs.obs_properties_add_text(socket_props, "socket_label", "", obs.OBS_TEXT_INFO)
        local r_port = obs.obs_properties_add_int(socket_props, "socket_port", "端口 ", 1024, 65535, 1)
        local r_poll = obs.obs_properties_add_int(socket_props, "socket_poll", "轮询延迟(毫秒) ", 0, 1000, 1)
        local socket = obs.obs_properties_add_group(props, "use_socket", "启用远程鼠标监听 ",
            obs.OBS_GROUP_CHECKABLE, socket_props)

        obs.obs_property_set_long_description(r_label,
            "启用后将启动UDP套接字服务器，监听来自远程客户端的鼠标位置消息")
        obs.obs_property_set_long_description(r_port,
            "更改端口后必须重启服务器（取消勾选然后重新勾选'启用远程鼠标监听'）")
        obs.obs_property_set_long_description(r_poll,
            "更改轮询延迟后必须重启服务器（取消勾选然后重新勾选'启用远程鼠标监听'）")

        obs.obs_property_set_visible(r_label, not use_socket)
        obs.obs_property_set_visible(r_port, use_socket)
        obs.obs_property_set_visible(r_poll, use_socket)
        obs.obs_property_set_modified_callback(socket, on_settings_modified)
    end

    -- Add a button for more information
    local help = obs.obs_properties_add_button(props, "help_button", "更多信息", on_print_help)
    obs.obs_property_set_long_description(help,
        "点击显示帮助信息（通过脚本日志）")

    local debug = obs.obs_properties_add_bool(props, "debug_logs", "启用调试日志 ")
    obs.obs_property_set_long_description(debug,
        "启用后脚本将输出诊断信息到脚本日志（用于调试/GitHub问题反馈）")

    obs.obs_property_set_visible(override_label, not use_monitor_override)
    obs.obs_property_set_visible(tier_zoom_value, use_tier_zoom)
    obs.obs_property_set_visible(override_x, use_monitor_override)
    obs.obs_property_set_visible(override_y, use_monitor_override)
    obs.obs_property_set_visible(override_w, use_monitor_override)
    obs.obs_property_set_visible(override_h, use_monitor_override)
    obs.obs_property_set_visible(override_sx, use_monitor_override)
    obs.obs_property_set_visible(override_sy, use_monitor_override)
    obs.obs_property_set_visible(override_dw, use_monitor_override)
    obs.obs_property_set_visible(override_dh, use_monitor_override)
    obs.obs_property_set_modified_callback(override, on_settings_modified)
    obs.obs_property_set_modified_callback(tier_zoom, on_settings_modified)

    obs.obs_property_set_modified_callback(allow_all, on_settings_modified)
    obs.obs_property_set_modified_callback(debug, on_settings_modified)

    return props
end

function script_load(settings)
    sceneitem_info_orig = nil

    -- Workaround for detecting if OBS is already loaded and we were reloaded using "Reload Scripts"
    local current_scene = obs.obs_frontend_get_current_scene()
    is_obs_loaded = current_scene ~= nil -- Current scene is nil on first OBS load
    obs.obs_source_release(current_scene)

    -- Add our hotkey
    hotkey_zoom_id = obs.obs_hotkey_register_frontend("toggle_zoom_hotkey", "切换鼠标缩放",
        on_toggle_zoom)

    hotkey_tier_zoom_id = obs.obs_hotkey_register_frontend("toggle_tier_zoom_hotkey", "切换二级缩放",
        on_toggle_tier_zoom)

    hotkey_follow_id = obs.obs_hotkey_register_frontend("toggle_follow_hotkey", "切换缩放时跟随鼠标",
        on_toggle_follow)

    hotkey_auto_zoom_out_id = obs.obs_hotkey_register_frontend("toggle_auto_zoom_out_hotkey", "切换鼠标静止自动缩小",
        on_toggle_auto_zoom_out)

    -- Attempt to reload existing hotkey bindings if we can find any
    local hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom")
    obs.obs_hotkey_load(hotkey_zoom_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.tier_zoom")
    obs.obs_hotkey_load(hotkey_tier_zoom_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.follow")
    obs.obs_hotkey_load(hotkey_follow_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.auto_zoom_out")
    obs.obs_hotkey_load(hotkey_auto_zoom_out_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    -- Load any other settings
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    use_smooth_follow = obs.obs_data_get_bool(settings, "use_smooth_follow")
    smooth_factor = obs.obs_data_get_double(settings, "smooth_factor")
    follow_prediction_time = obs.obs_data_get_double(settings, "follow_prediction_time")
    follow_prediction_limit = obs.obs_data_get_int(settings, "follow_prediction_limit")
    zoom_smoothness = obs.obs_data_get_double(settings, "zoom_smoothness")
    use_tier_zoom = obs.obs_data_get_bool(settings, "use_tier_zoom")
    zoom_value_tier = obs.obs_data_get_double(settings, "zoom_value_tier")
    use_auto_zoom_out = obs.obs_data_get_bool(settings, "auto_zoom_out")
    auto_zoom_out_delay = obs.obs_data_get_double(settings, "auto_zoom_out_delay")
    use_detect_typing = obs.obs_data_get_bool(settings, "detect_typing")
    typing_pause_delay = obs.obs_data_get_double(settings, "typing_pause_delay")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")
    auto_start = obs.obs_data_get_bool(settings, "auto_start")
    keep_shape = obs.obs_data_get_bool(settings, "keep_shape")

    obs.obs_frontend_add_event_callback(on_frontend_event)

    if debug_logs then
        log_current_settings()
    end

    -- Add the transition_start event handlers to each transition (the global source_transition_start event never fires)
    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for i, s in pairs(transitions) do
            local name = obs.obs_source_get_name(s)
            log("Adding transition_start listener to " .. name)
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        obs.source_list_release(transitions)
    end

    if ffi.os == "Linux" and not x11_display then
        log("ERROR: Could not get X11 Display for Linux\n" ..
            "Mouse position will be incorrect.")
    end

    source_name = ""
    use_socket = false
    is_script_loaded = true
end

function script_unload()
    is_script_loaded = false

    -- Clean up the memory usage
    if major > 29.1 or (major == 29.1 and minor > 2) then -- 29.1.2 and below seems to crash if you do this, so we ignore it as the script is closing anyway
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for i, s in pairs(transitions) do
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        obs.obs_hotkey_unregister(on_toggle_zoom)
        obs.obs_hotkey_unregister(on_toggle_tier_zoom)
        obs.obs_hotkey_unregister(on_toggle_follow)
        obs.obs_hotkey_unregister(on_toggle_auto_zoom_out)
        obs.obs_frontend_remove_event_callback(on_frontend_event)
        release_sceneitem()
    end

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
        x11_display = nil
        x11_lib = nil
    end

    if socket_server ~= nil then
        stop_server()
    end
end

function script_defaults(settings)
    -- Default values for the script
    obs.obs_data_set_default_double(settings, "zoom_value", 2)
    obs.obs_data_set_default_bool(settings, "use_tier_zoom", false)
    obs.obs_data_set_default_double(settings, "zoom_value_tier", 1.5)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.05)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.18)
    obs.obs_data_set_default_int(settings, "follow_border", 8)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 1)
    obs.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    obs.obs_data_set_default_bool(settings, "use_smooth_follow", true)
    obs.obs_data_set_default_double(settings, "smooth_factor", 0.16)
    obs.obs_data_set_default_double(settings, "follow_prediction_time", 0.010)
    obs.obs_data_set_default_int(settings, "follow_prediction_limit", 28)
    obs.obs_data_set_default_double(settings, "zoom_smoothness", 0.88)
    obs.obs_data_set_default_bool(settings, "auto_zoom_out", false)
    obs.obs_data_set_default_double(settings, "auto_zoom_out_delay", 3.0)
    obs.obs_data_set_default_bool(settings, "detect_typing", false)
    obs.obs_data_set_default_double(settings, "typing_pause_delay", 2.0)
    obs.obs_data_set_default_bool(settings, "allow_all_sources", false)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    obs.obs_data_set_default_double(settings, "monitor_override_sx", 1)
    obs.obs_data_set_default_double(settings, "monitor_override_sy", 1)
    obs.obs_data_set_default_int(settings, "monitor_override_dw", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_dh", 1080)
    obs.obs_data_set_default_bool(settings, "use_socket", false)
    obs.obs_data_set_default_int(settings, "socket_port", 12345)
    obs.obs_data_set_default_int(settings, "socket_poll", 10)
    obs.obs_data_set_default_bool(settings, "debug_logs", false)
    obs.obs_data_set_default_bool(settings, "auto_start", false)
    obs.obs_data_set_default_bool(settings, "keep_shape", false)
end

function script_save(settings)
    -- Save the custom hotkey information
    if hotkey_zoom_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_tier_zoom_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_tier_zoom_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.tier_zoom", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_follow_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_follow_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.follow", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_auto_zoom_out_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_auto_zoom_out_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.auto_zoom_out", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end

function script_update(settings)
    local old_source_name = source_name
    local old_override = use_monitor_override
    local old_x = monitor_override_x
    local old_y = monitor_override_y
    local old_w = monitor_override_w
    local old_h = monitor_override_h
    local old_sx = monitor_override_sx
    local old_sy = monitor_override_sy
    local old_dw = monitor_override_dw
    local old_dh = monitor_override_dh
    local old_socket = use_socket
    local old_port = socket_port
    local old_poll = socket_poll

    -- Update the settings
    source_name = obs.obs_data_get_string(settings, "source")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    use_smooth_follow = obs.obs_data_get_bool(settings, "use_smooth_follow")
    smooth_factor = obs.obs_data_get_double(settings, "smooth_factor")
    follow_prediction_time = obs.obs_data_get_double(settings, "follow_prediction_time")
    follow_prediction_limit = obs.obs_data_get_int(settings, "follow_prediction_limit")
    zoom_smoothness = obs.obs_data_get_double(settings, "zoom_smoothness")
    use_tier_zoom = obs.obs_data_get_bool(settings, "use_tier_zoom")
    zoom_value_tier = obs.obs_data_get_double(settings, "zoom_value_tier")
    use_auto_zoom_out = obs.obs_data_get_bool(settings, "auto_zoom_out")
    auto_zoom_out_delay = obs.obs_data_get_double(settings, "auto_zoom_out_delay")
    use_detect_typing = obs.obs_data_get_bool(settings, "detect_typing")
    typing_pause_delay = obs.obs_data_get_double(settings, "typing_pause_delay")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")
    auto_start = obs.obs_data_get_bool(settings, "auto_start")
    keep_shape = obs.obs_data_get_bool(settings, "keep_shape")

    -- Only do the expensive refresh if the user selected a new source
    if source_name ~= old_source_name and is_obs_loaded then
        refresh_sceneitem(true)
    end

    -- Update the monitor_info if the settings changed
    if source_name ~= old_source_name or
        use_monitor_override ~= old_override or
        monitor_override_x ~= old_x or
        monitor_override_y ~= old_y or
        monitor_override_w ~= old_w or
        monitor_override_h ~= old_h or
        monitor_override_sx ~= old_sx or
        monitor_override_sy ~= old_sy or
        monitor_override_w ~= old_dw or
        monitor_override_h ~= old_dh then
        if is_obs_loaded then
            monitor_info = get_monitor_info(source)
        end
    end

    if old_socket ~= use_socket then
        if use_socket then
            start_server()
        else
            stop_server()
        end
    elseif use_socket and (old_poll ~= socket_poll or old_port ~= socket_port) then
        stop_server()
        start_server()
    end

    -- Auto start only after OBS is fully loaded
    if is_obs_loaded and source_name ~= "" and source_name ~= "obs-zoom-to-mouse-none" and auto_start and not auto_start_running then
        log("Auto starting from settings update")
        auto_start_running = true
        local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 100000)
        obs.timer_add(wait_for_auto_start, timer_interval)
    end
end

function wait_for_auto_start()
    if source_name == "obs-zoom-to-mouse-none" or not auto_start or source_name == "" then
        obs.remove_current_callback()
        auto_start_running = false
        log("Auto start cancelled")
    else
        auto_start_running = true
        local found_source = obs.obs_get_source_by_name(source_name)
        if found_source ~= nil then
            source = found_source
            monitor_info = get_monitor_info(source)
            refresh_sceneitem(true)
            on_toggle_zoom(true, true)
            obs.remove_current_callback()
            auto_start_running = false
            log("Auto start done")
        end
    end
end

function populate_zoom_sources(list)
    obs.obs_property_list_clear(list)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        obs.obs_property_list_add_string(list, "<无>", "obs-zoom-to-mouse-none")
        for _, source in ipairs(sources) do
            local source_type = obs.obs_source_get_id(source)
            if source_type == dc_info.source_id or allow_all_sources then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end

        obs.source_list_release(sources)
    end
end
