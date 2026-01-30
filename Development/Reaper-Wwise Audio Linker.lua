-- @description Reaper-Wwise Audio Linker
-- @author ayi111
-- @version 1.0.0
-- @changelog
--   v1.0.0 (2025-01-30)
--   + Initial release
--   + Import audio sources from Wwise selection
--   + Render selected items back to Wwise original paths
--   + P4 (Perforce) integration for checkout before render
--   + Progress bar with real-time logging
-- @about
--   # Reaper-Wwise Audio Linker
--
--   A tool for bidirectional audio workflow between REAPER and Wwise.
--
--   ## Features
--   - Import audio sources from Wwise selected objects into REAPER
--   - Render REAPER items back to overwrite Wwise original audio files
--   - Automatic P4 checkout before rendering
--   - Real-time progress display and logging
--
--   ## Requirements
--   - ReaImGui (install via ReaPack: Extensions > ReaImGui)
--   - ReaWwise (download from Audiokinetic: https://www.audiokinetic.com/library/edge/?source=ReaWwise)
--   - Wwise with WAAPI enabled (default port 8080)
--
--   ## Usage
--   1. Open Wwise project with WAAPI enabled
--   2. Select objects containing audio sources in Wwise
--   3. Click "Import from Wwise" to import audio files
--   4. Edit audio in REAPER
--   5. Select items and click "Render to Wwise" to overwrite original files
-- @links
--   Audiokinetic ReaWwise https://www.audiokinetic.com/library/edge/?source=ReaWwise
-- @provides
--   [main] .

-- region 依赖检查

-- 检查 ReaImGui
local function check_reaimgui()
    if not reaper.ImGui_CreateContext then
        local msg = [[
ReaImGui 扩展未安装！

安装方法：
1. 打开 REAPER
2. 菜单: Extensions -> ReaPack -> Browse packages
3. 搜索 "ReaImGui"
4. 右键点击 "ReaImGui: ReaScript binding for Dear ImGui"
5. 选择 "Install"
6. 重启 REAPER

]]
        reaper.MB(msg, "缺少依赖: ReaImGui", 0)
        return false
    end
    return true
end

-- 检查 ReaWwise
local function check_reawwise()
    if not reaper.AK_Waapi_Connect then
        local msg = [[
ReaWwise 插件未安装！

安装方法：
1. 访问 Audiokinetic 官网下载 ReaWwise:
   https://www.audiokinetic.com/library/edge/?source=ReaWwise
2. 下载对应系统版本的 reaper_reawwise 插件
3. 将 .dll (Windows) 或 .dylib (Mac) 文件放入:
   - Windows: %APPDATA%\REAPER\UserPlugins\
   - Mac: ~/Library/Application Support/REAPER/UserPlugins/
4. 重启 REAPER

]]
        reaper.MB(msg, "缺少依赖: ReaWwise", 0)
        return false
    end
    return true
end

if not check_reaimgui() then
    return
end

if not check_reawwise() then
    return
end

-- endregion

-- region 全局变量
local ctx = reaper.ImGui_CreateContext("Reaper-Wwise Linker")

local imported_sources = {} -- 存储导入的音频源信息
local WAAPI_IP = "127.0.0.1"
local WAAPI_PORT = 8080
local port_input = tostring(WAAPI_PORT)
local waapi_connected = false -- WAAPI连接状态
local status_text = "就绪"
local selected_list_item = -1 -- 列表选中项
local window_open = true

-- 日志系统
local log_buffer = {}              -- 日志缓冲区
local log_max_lines = 500          -- 最大日志行数
local log_scroll_to_bottom = false -- 标记是否需要滚动到底部

-- 进度系统
local progress_active = false -- 是否有任务在进行
local progress_value = 0      -- 当前进度 0-1
local progress_text = ""      -- 进度文本
local current_task = nil      -- 当前协程任务
-- endregion

-- region 日志函数
local function log(msg)
    local timestamp = os.date("%H:%M:%S")
    local lines = {}
    for line in (msg .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            table.insert(lines, string.format("[%s] %s", timestamp, line))
        end
    end
    for _, line in ipairs(lines) do
        table.insert(log_buffer, line)
    end
    -- 限制日志行数
    while #log_buffer > log_max_lines do
        table.remove(log_buffer, 1)
    end
    -- 标记需要滚动到底部
    log_scroll_to_bottom = true
end

local function log_clear()
    log_buffer = {}
end
-- endregion

-- region WAAPI工具函数

-- 连接WAAPI
local function waapi_connect()
    if reaper.AK_Waapi_Connect(WAAPI_IP, WAAPI_PORT) then
        waapi_connected = true
        log("WAAPI已连接: " .. WAAPI_IP .. ":" .. WAAPI_PORT .. "\n")
        return true
    else
        waapi_connected = false
        log("WAAPI连接失败: " .. WAAPI_IP .. ":" .. WAAPI_PORT .. "\n")
        return false
    end
end

-- 断开WAAPI连接
local function waapi_disconnect()
    if waapi_connected then
        reaper.AK_AkJson_ClearAll()
        reaper.AK_Waapi_Disconnect()
        waapi_connected = false
        log("WAAPI已断开\n")
    end
end

-- 重试连接
local function retry_connection()
    waapi_disconnect()

    local port_num = tonumber(port_input)
    if port_num and port_num > 0 and port_num < 65536 then
        WAAPI_PORT = port_num
    else
        reaper.MB("端口号无效，请输入1-65535之间的数字", "错误", 0)
        return
    end

    waapi_connect()
end
-- endregion

-- region WAAPI查询函数

-- 步骤1: 获取Wwise中当前选中的对象
local function get_selected_objects()
    local selected = {}

    if not waapi_connected then return selected end

    -- 构建options
    local fieldsToReturn = reaper.AK_AkJson_Array()
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("id"))
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("name"))
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("path"))

    local options = reaper.AK_AkJson_Map()
    reaper.AK_AkJson_Map_Set(options, "return", fieldsToReturn)

    -- 调用getSelectedObjects
    local result = reaper.AK_Waapi_Call("ak.wwise.ui.getSelectedObjects", reaper.AK_AkJson_Map(), options)
    local status = reaper.AK_AkJson_GetStatus(result)

    if status then
        local objects = reaper.AK_AkJson_Map_Get(result, "objects")
        local numObjects = reaper.AK_AkJson_Array_Size(objects)

        log("找到 " .. numObjects .. " 个选中对象\n")

        for i = 0, numObjects - 1 do
            local item = reaper.AK_AkJson_Array_Get(objects, i)
            local id_var = reaper.AK_AkJson_Map_Get(item, "id")
            local name_var = reaper.AK_AkJson_Map_Get(item, "name")
            local path_var = reaper.AK_AkJson_Map_Get(item, "path")

            local id = reaper.AK_AkVariant_GetString(id_var)
            local name = reaper.AK_AkVariant_GetString(name_var)
            local path = reaper.AK_AkVariant_GetString(path_var)

            table.insert(selected, { id = id, name = name, path = path })
            log(" - " .. name .. " [" .. id .. "]\n")
        end
    else
        local errorMessage = reaper.AK_AkJson_Map_Get(result, "message")
        local errorStr = reaper.AK_AkVariant_GetString(errorMessage)
        log("获取选中对象失败: " .. (errorStr or "未知错误") .. "\n")
    end

    reaper.AK_AkJson_ClearAll()
    return selected
end

-- 步骤2: 根据对象ID查询其下的所有子节点，过滤出AudioFileSource
local function get_audio_sources_from_object(object_id)
    local sources = {}

    if not waapi_connected then return sources end

    -- 使用 from.id 指定对象，配合 transform 获取 descendants
    local arguments = reaper.AK_AkJson_Map()

    -- from.id 数组
    local from_map = reaper.AK_AkJson_Map()
    local id_array = reaper.AK_AkJson_Array()
    reaper.AK_AkJson_Array_Add(id_array, reaper.AK_AkVariant_String(object_id))
    reaper.AK_AkJson_Map_Set(from_map, "id", id_array)
    reaper.AK_AkJson_Map_Set(arguments, "from", from_map)

    -- transform: [{"select": ["descendants"]}]
    local transform_array = reaper.AK_AkJson_Array()
    local select_map = reaper.AK_AkJson_Map()
    local select_array = reaper.AK_AkJson_Array()
    reaper.AK_AkJson_Array_Add(select_array, reaper.AK_AkVariant_String("descendants"))
    reaper.AK_AkJson_Map_Set(select_map, "select", select_array)
    reaper.AK_AkJson_Array_Add(transform_array, select_map)
    reaper.AK_AkJson_Map_Set(arguments, "transform", transform_array)

    -- options: 返回字段，包含type用于过滤
    local fieldsToReturn = reaper.AK_AkJson_Array()
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("name"))
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("type"))
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("path"))
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("sound:originalWavFilePath"))
    reaper.AK_AkJson_Array_Add(fieldsToReturn, reaper.AK_AkVariant_String("id"))

    local options = reaper.AK_AkJson_Map()
    reaper.AK_AkJson_Map_Set(options, "return", fieldsToReturn)

    -- 执行WAAPI调用
    local result = reaper.AK_Waapi_Call("ak.wwise.core.object.get", arguments, options)
    local status = reaper.AK_AkJson_GetStatus(result)

    if status then
        local objects = reaper.AK_AkJson_Map_Get(result, "return")
        local numObjects = reaper.AK_AkJson_Array_Size(objects)

        log("找到 " .. numObjects .. " 个子节点\n")

        for i = 0, numObjects - 1 do
            local item = reaper.AK_AkJson_Array_Get(objects, i)

            local type_var = reaper.AK_AkJson_Map_Get(item, "type")
            local obj_type = reaper.AK_AkVariant_GetString(type_var)

            -- 只处理AudioFileSource类型
            if obj_type == "AudioFileSource" then
                local name_var = reaper.AK_AkJson_Map_Get(item, "name")
                local path_var = reaper.AK_AkJson_Map_Get(item, "path")
                local wav_path_var = reaper.AK_AkJson_Map_Get(item, "sound:originalWavFilePath")
                local id_var = reaper.AK_AkJson_Map_Get(item, "id")

                local name = reaper.AK_AkVariant_GetString(name_var)
                local wwise_path = reaper.AK_AkVariant_GetString(path_var)
                local wav_path = reaper.AK_AkVariant_GetString(wav_path_var)
                local id = reaper.AK_AkVariant_GetString(id_var)

                if wav_path and wav_path ~= "" then
                    table.insert(sources, {
                        name = name,
                        wwise_path = wwise_path,
                        original_path = wav_path,
                        id = id
                    })
                    log("[AudioFileSource] " .. name .. "\n")
                end
            end
        end
    else
        local errorMessage = reaper.AK_AkJson_Map_Get(result, "message")
        local errorStr = reaper.AK_AkVariant_GetString(errorMessage)
        log("查询子节点失败: " .. (errorStr or "未知错误") .. "\n")
    end

    reaper.AK_AkJson_ClearAll()
    return sources
end

-- 执行完整查询：获取选中对象的所有音频源文件
local function get_audio_sources_from_selection()
    local all_sources = {}

    if not waapi_connected then
        reaper.MB("WAAPI未连接，请先连接到Wwise", "错误", 0)
        return all_sources
    end

    -- 第一步：获取选中对象
    local selected_objects = get_selected_objects()

    if #selected_objects == 0 then
        log("Wwise中没有选中任何对象\n")
        return all_sources
    end

    -- 第二步：遍历每个选中对象，查询其下的AudioFileSource
    for _, obj in ipairs(selected_objects) do
        log("查询对象: " .. obj.name .. "\n")
        local sources = get_audio_sources_from_object(obj.id)

        for _, src in ipairs(sources) do
            -- 去重
            local exists = false
            for _, existing in ipairs(all_sources) do
                if existing.id == src.id then
                    exists = true
                    break
                end
            end
            if not exists then
                table.insert(all_sources, src)
            end
        end
    end

    return all_sources
end
-- endregion

-- region Reaper工具函数

-- 创建新轨道（每次导入都创建新轨道）
local import_counter = 0
local function create_new_track()
    import_counter = import_counter + 1
    local track_count = reaper.CountTracks(0)
    local track_name = string.format("Wwise Import #%d", import_counter)

    reaper.InsertTrackAtIndex(track_count, true)
    local new_track = reaper.GetTrack(0, track_count)
    reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", track_name, true)
    return new_track
end

-- 导入音频文件到轨道
local function import_audio_to_track(track, file_path, position)
    local item = reaper.AddMediaItemToTrack(track)
    local take = reaper.AddTakeToMediaItem(item)
    local source = reaper.PCM_Source_CreateFromFile(file_path)

    if source then
        reaper.SetMediaItemTake_Source(take, source)
        local length = reaper.GetMediaSourceLength(source)
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", file_path:match("([^\\]+)$"), true)
        reaper.UpdateItemInProject(item)
        return item, length
    end

    return nil, 0
end
-- endregion

-- region 文件操作

-- 复制文件（强制覆盖）
local function copy_file(src, dst)
    local src_file = io.open(src, "rb")
    if not src_file then return false end

    local content = src_file:read("*all")
    src_file:close()

    -- 先删除目标文件（如果存在）
    os.remove(dst)

    local dst_file = io.open(dst, "wb")
    if not dst_file then return false end

    dst_file:write(content)
    dst_file:close()
    return true
end

-- 获取Reaper工程的Media目录
local function get_project_media_dir()
    local _, project_path = reaper.EnumProjects(-1)
    if not project_path or project_path == "" then
        return nil
    end

    -- 获取工程目录
    local project_dir = project_path:match("(.+)\\")
    if not project_dir then return nil end

    -- Media目录
    local media_dir = project_dir .. "\\Media"

    -- 创建目录（如果不存在）
    os.execute('mkdir "' .. media_dir .. '" 2>nul')

    return media_dir
end
-- endregion

-- region 核心功能

-- 功能一：从Wwise导入音频源（协程版本）
local function import_from_wwise_coroutine()
    local sources = get_audio_sources_from_selection()
    if #sources == 0 then
        reaper.MB("未找到音频源文件。请在Wwise中选择包含音频源的对象。", "提示", 0)
        progress_active = false
        return
    end

    -- 获取Media目录
    local media_dir = get_project_media_dir()
    if not media_dir then
        reaper.MB("无法获取Reaper工程路径，请先保存工程。", "错误", 0)
        progress_active = false
        return
    end

    -- 每次创建新轨道
    local track = create_new_track()

    log("=== 开始从Wwise导入音频源 ===")
    log("找到 " .. #sources .. " 个音频源文件")
    log("Media目录: " .. media_dir)

    reaper.Undo_BeginBlock()

    local position = 0
    local gap = 0.1 -- 文件之间的间隔（秒）
    local success_count = 0
    local fail_count = 0
    local total = #sources

    for i, source in ipairs(sources) do
        -- 更新进度
        progress_value = (i - 1) / total
        progress_text = string.format("导入中... (%d/%d) %s", i, total, source.name)
        coroutine.yield() -- 让出执行权，让GUI更新

        local original_path = source.original_path
        local file_name = original_path:match("([^\\]+)$")
        local local_path = media_dir .. "\\" .. file_name

        -- 检查源文件是否存在
        local file = io.open(original_path, "r")
        if file then
            file:close()

            -- 复制文件到Media目录
            if copy_file(original_path, local_path) then
                log("复制: " .. file_name .. " -> Media")

                -- 从本地副本导入
                local item, length = import_audio_to_track(track, local_path, position)
                if item then
                    table.insert(imported_sources, {
                        original_path = original_path, -- 保留原始路径用于渲染
                        local_path = local_path,       -- 本地副本路径
                        name = source.name,
                        wwise_path = source.wwise_path,
                        id = source.id,
                        item = item
                    })
                    position = position + length + gap
                    success_count = success_count + 1
                    log("[OK] " .. source.name)
                else
                    fail_count = fail_count + 1
                    log("[FAIL] 无法导入: " .. local_path)
                end
            else
                fail_count = fail_count + 1
                log("[FAIL] 无法复制文件: " .. original_path)
            end
        else
            fail_count = fail_count + 1
            log("[FAIL] 文件不存在: " .. original_path)
        end
    end

    reaper.Undo_EndBlock("Import Wwise Audio Sources", -1)
    reaper.UpdateArrange()

    progress_value = 1
    progress_text = "导入完成"
    progress_active = false
    status_text = string.format("导入完成，共 %d 个文件", #imported_sources)
    log(string.format("=== 导入完成: 成功 %d, 失败 %d ===", success_count, fail_count))
end

-- 启动导入任务
local function import_from_wwise()
    if progress_active then
        reaper.MB("有任务正在进行中，请等待完成。", "提示", 0)
        return
    end
    if not waapi_connected then
        reaper.MB("请先连接到Wwise", "未连接", 0)
        return
    end
    progress_active = true
    progress_value = 0
    progress_text = "准备导入..."
    current_task = coroutine.create(import_from_wwise_coroutine)
end

-- 功能二：渲染选中Item并覆盖原始文件（协程版本）
local function render_to_wwise_coroutine()
    local selected_count = reaper.CountSelectedMediaItems(0)
    if selected_count == 0 then
        reaper.MB("请先选择要渲染的Item。", "提示", 0)
        progress_active = false
        return
    end

    if #imported_sources == 0 then
        reaper.MB("没有已记录的Wwise音频源。请先执行'从Wwise导入'功能。", "提示", 0)
        progress_active = false
        return
    end

    -- 收集需要渲染的item信息，并按目录分组
    local dir_groups = {}
    local all_items = {} -- 用于计算总进度
    for i = 0, selected_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        for _, source_info in ipairs(imported_sources) do
            if source_info.item == item then
                local output_path = source_info.original_path
                local output_dir = output_path:match("(.+)\\")

                if not dir_groups[output_dir] then
                    dir_groups[output_dir] = {}
                end
                table.insert(dir_groups[output_dir], { item = item, info = source_info })
                table.insert(all_items, { item = item, info = source_info, dir = output_dir })
                break
            end
        end
    end

    local total_items = #all_items
    if total_items == 0 then
        reaper.MB("选中的Item不在已导入的Wwise音频源列表中。", "提示", 0)
        progress_active = false
        return
    end

    log("=== 开始渲染到Wwise ===")
    reaper.Undo_BeginBlock()

    local success_count = 0
    local fail_count = 0
    local processed = 0

    -- 设置渲染参数
    reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$item", true)
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 32, true) -- selected media items

    -- 按目录分批渲染
    for output_dir, items in pairs(dir_groups) do
        -- 更新进度 - P4 checkout阶段
        progress_text = string.format("P4 checkout... %s", output_dir:match("([^\\]+)$") or output_dir)
        coroutine.yield()

        log("渲染目录: " .. output_dir)

        -- p4 edit checkout文件
        for _, render_item in ipairs(items) do
            local file_path = render_item.info.original_path
            local p4_cmd = string.format('p4 edit "%s"', file_path)
            log("P4 Edit: " .. render_item.info.name)
            os.execute(p4_cmd)
        end

        -- 更新进度 - 渲染阶段
        progress_text = string.format("渲染中... %s (%d个文件)", output_dir:match("([^\\]+)$") or output_dir, #items)
        coroutine.yield()

        reaper.SelectAllMediaItems(0, false)

        -- 选中该目录下的所有item
        for _, render_item in ipairs(items) do
            reaper.SetMediaItemSelected(render_item.item, true)
        end

        -- 设置渲染目录
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE", output_dir, true)

        -- 执行渲染 (42230 = Render project using recent settings, auto-close)
        reaper.Main_OnCommand(42230, 0)

        -- 检查每个文件是否渲染成功
        for _, render_item in ipairs(items) do
            processed = processed + 1
            progress_value = processed / total_items

            local output_path = render_item.info.original_path
            local check = io.open(output_path, "r")
            if check then
                check:close()
                success_count = success_count + 1
                log("[OK] " .. render_item.info.name)
            else
                fail_count = fail_count + 1
                log("[FAIL] " .. render_item.info.name)
            end
        end
    end

    reaper.Undo_EndBlock("Render to Wwise", -1)
    reaper.UpdateArrange()

    progress_value = 1
    progress_text = "渲染完成"
    progress_active = false
    status_text = "渲染完成"
    log(string.format("=== 渲染完成: 成功 %d, 失败 %d ===", success_count, fail_count))
end

-- 启动渲染任务
local function render_to_wwise()
    if progress_active then
        reaper.MB("有任务正在进行中，请等待完成。", "提示", 0)
        return
    end
    progress_active = true
    progress_value = 0
    progress_text = "准备渲染..."
    current_task = coroutine.create(render_to_wwise_coroutine)
end

-- 选中所有导入的Item
local function select_all_imported_items()
    reaper.SelectAllMediaItems(0, false)
    local count = 0
    for _, source in ipairs(imported_sources) do
        if reaper.ValidatePtr(source.item, "MediaItem*") then
            reaper.SetMediaItemSelected(source.item, true)
            count = count + 1
        end
    end
    reaper.UpdateArrange()
    status_text = "已选中 " .. count .. " 个Item"
end

-- 清空列表
local function clear_list()
    imported_sources = {}
    status_text = "列表已清空"
end
-- endregion

-- region GUI绘制

local function get_connection_status_text()
    if waapi_connected then
        return "已连接"
    else
        return "未连接"
    end
end

local function get_connection_status_color()
    if waapi_connected then
        return 0x88FF88FF -- 绿色
    else
        return 0xFFFF88FF -- 红色
    end
end

local function draw_gui()
    -- 设置窗口大小
    reaper.ImGui_SetNextWindowSize(ctx, 500, 800, reaper.ImGui_Cond_FirstUseEver())

    local visible, open = reaper.ImGui_Begin(ctx, "Reaper-Wwise Linker", true)

    if visible then
        -- 标题
        reaper.ImGui_Text(ctx, "Reaper-Wwise Linker")
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- WAAPI连接区域
        reaper.ImGui_Text(ctx, "WAAPI连接")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 50)
        local changed, new_port = reaper.ImGui_InputText(ctx, "端口", port_input)
        if changed then port_input = new_port end

        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "连接", 50, 0) then
            retry_connection()
        end

        reaper.ImGui_SameLine(ctx)
        local status_color = get_connection_status_color()
        reaper.ImGui_TextColored(ctx, status_color, get_connection_status_text())

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- 状态显示
        reaper.ImGui_Text(ctx, "状态: " .. status_text)
        reaper.ImGui_Spacing(ctx)

        -- 进度条（任务进行中时显示）
        if progress_active then
            reaper.ImGui_ProgressBar(ctx, progress_value, -1, 0, progress_text)
            reaper.ImGui_Spacing(ctx)
        end

        -- 功能按钮（任务进行中时禁用）
        local buttons_disabled = progress_active
        if buttons_disabled then
            reaper.ImGui_BeginDisabled(ctx)
        end

        if reaper.ImGui_Button(ctx, "从Wwise导入音频源", 150, 26) then
            status_text = "正在从Wwise导入..."
            import_from_wwise()
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "渲染选中Item到Wwise", 150, 26) then
            status_text = "正在渲染..."
            render_to_wwise()
        end

        if buttons_disabled then
            reaper.ImGui_EndDisabled(ctx)
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- 列表区域
        reaper.ImGui_Text(ctx, "已导入的音频源 (" .. #imported_sources .. ")")

        local list_height = 120
        if reaper.ImGui_BeginChild(ctx, "source_list", -1, list_height, 1) then
            for i, source in ipairs(imported_sources) do
                local is_selected = (selected_list_item == i)
                if reaper.ImGui_Selectable(ctx, string.format("%d. %s", i, source.name), is_selected) then
                    selected_list_item = i
                    if reaper.ValidatePtr(source.item, "MediaItem*") then
                        reaper.SelectAllMediaItems(0, false)
                        reaper.SetMediaItemSelected(source.item, true)
                        reaper.UpdateArrange()
                    end
                end
            end
            reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_Spacing(ctx)

        -- 列表操作按钮
        if reaper.ImGui_Button(ctx, "清空列表", 80, 26) then
            clear_list()
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "选中所有导入的Item", 150, 26) then
            select_all_imported_items()
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- 日志区域
        if reaper.ImGui_Button(ctx, "清空日志", 80, 26) then
            log_clear()
        end

        reaper.ImGui_Spacing(ctx)
        local log_height = 180
        if reaper.ImGui_BeginChild(ctx, "log_window", -1, log_height, 1) then
            for _, line in ipairs(log_buffer) do
                -- 根据日志内容设置颜色
                if line:find("%[OK%]") then
                    reaper.ImGui_TextColored(ctx, 0x88FF88FF, line) -- 绿色
                elseif line:find("%[FAIL%]") then
                    reaper.ImGui_TextColored(ctx, 0xFF8888FF, line) -- 红色
                elseif line:find("===") then
                    reaper.ImGui_TextColored(ctx, 0x88FFFFFF, line) -- 青色
                else
                    reaper.ImGui_Text(ctx, line)
                end
            end
            -- 有新日志时滚动到底部
            if log_scroll_to_bottom then
                reaper.ImGui_SetScrollHereY(ctx, 1.0)
                log_scroll_to_bottom = false
            end
            reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)

        -- 底部信息
        reaper.ImGui_TextDisabled(ctx, "IP: " .. WAAPI_IP .. " | 端口: " .. WAAPI_PORT)

        reaper.ImGui_End(ctx)
    end

    return open
end
-- endregion

-- region 主循环

local function main_loop()
    -- 处理协程任务
    if current_task and coroutine.status(current_task) ~= "dead" then
        local ok, err = coroutine.resume(current_task)
        if not ok then
            log("[ERROR] " .. tostring(err))
            progress_active = false
            current_task = nil
        end
    elseif current_task then
        current_task = nil
    end

    -- 绘制GUI
    window_open = draw_gui()

    if window_open then
        reaper.defer(main_loop)
    else
        waapi_disconnect()
    end
end

-- 初始化
waapi_connect()
log("Reaper-Wwise Linker 已启动")

-- 启动主循环
reaper.defer(main_loop)
-- endregion
