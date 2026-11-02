--[[ 剧情回放 MOD —— 业务模块（可热重载） ]]

local Debug = luanet.import_type('UnityEngine.Debug')
local LuaTool = luanet.import_type('JyGame.LuaTool')
local Array = luanet.import_type('System.Array')
local Assembly = luanet.import_type('System.Reflection.Assembly')
local File = luanet.import_type('System.IO.File')
local AppDomain = luanet.import_type('System.AppDomain')
local Enum = luanet.import_type('System.Enum')
local Delegate = luanet.import_type('System.Delegate')

local GameObject = luanet.import_type('UnityEngine.GameObject')
local Vector2 = luanet.import_type('UnityEngine.Vector2')
local Color = luanet.import_type('UnityEngine.Color')
local Font = luanet.import_type('UnityEngine.Font')
local RuntimeData = luanet.import_type('JyGame.RuntimeData')

local function L(s)
    Debug.LogError('[RP] ' .. tostring(s))
end

local function moddir()
    return _G.REPLAY_MODDIR or 'gamedata/modcache/SSWS_HG'
end

-- 调试开关：改成 true 会把过程写入 replay_trace.log
local DEBUG_TRACE = false
local TRACE_FILE = nil
local function T(s)
    if not DEBUG_TRACE then return end
    if not TRACE_FILE then
        TRACE_FILE = moddir() .. '/replay_trace.log'
        pcall(function() File.WriteAllText(TRACE_FILE, '') end)
    end
    pcall(function() File.AppendAllText(TRACE_FILE, tostring(s) .. '\n') end)
end

local _typeCache = {}
local function typeOf(fullName)
    if _typeCache[fullName] then return _typeCache[fullName] end
    local asms = AppDomain.CurrentDomain:GetAssemblies()
    for i = 0, asms.Length - 1 do
        local a = asms[i]
        local ok, t = pcall(function() return a:GetType(fullName) end)
        if ok and t ~= nil then
            _typeCache[fullName] = t
            return t
        end
    end
    L('type not found: ' .. fullName)
    return nil
end

local function setProp(obj, name, value)
    local ok, err = pcall(function()
        local pi = obj:GetType():GetProperty(name)
        if pi == nil then error('no property ' .. name) end
        pi:SetValue(obj, value)
    end)
    if not ok then T('setProp FAIL ' .. name .. ' :: ' .. tostring(err)) end
end

local function setEnumProp(obj, propName, enumTypeName, value)
    local ok, err = pcall(function()
        local pi = obj:GetType():GetProperty(propName)
        pi:SetValue(obj, Enum.ToObject(typeOf(enumTypeName), value))
    end)
    if not ok then T('setEnum FAIL ' .. propName .. ' :: ' .. tostring(err)) end
end

-- LuaInterface 不支持直接把 Lua 函数转委托，绕一圈：Lua 函数 -> JyGame.VoidCallBack -> UnityAction
local function toUnityAction(fn)
    local vc = LuaTool.MakeVoidCallBack(fn)
    if vc == nil then return nil end
    local uaType = typeOf('UnityEngine.Events.UnityAction')
    local mi = vc:GetType():GetMethod('Invoke')
    local ok, d = pcall(function() return Delegate.CreateDelegate(uaType, vc, mi) end)
    if not ok or d == nil then
        T('toUnityAction fail: ' .. tostring(d))
        return nil
    end
    return d
end

local function writeOut(name, text)
    local p = moddir() .. '/' .. name
    local ok, e = pcall(function() File.WriteAllText(p, text) end)
    if not ok then L('write fail ' .. p .. ' :: ' .. tostring(e)) end
end


-- ============ 剧情目录 ============
local CATALOG_FILE = 'replay_catalog.txt'

local function getAllOf(typeName)
    local asm = Assembly.GetExecutingAssembly()
    local t = asm:GetType(typeName)
    if t == nil then error('type not found: ' .. typeName) end
    local rmType = asm:GetType('JyGame.ResourceManager')
    local m = rmType:GetMethod('GetAll')
    local tarr = Array.CreateInstance(t:GetType(), 1)
    tarr[0] = t
    local gm = m:MakeGenericMethod(tarr)
    local objType = Assembly.Load('mscorlib.dll'):GetType('System.Object')
    local oarr = Array.CreateInstance(objType, 0)
    return LuaTool.CreateLuaTable(gm:Invoke(nil, oarr))
end

local function buildCatalog()
    local list = getAllOf('JyGame.Story')
    local names = {}
    for _, v in pairs(list) do
        if v.Name and v.Name ~= '' then
            names[#names + 1] = v.Name
        end
    end
    table.sort(names)
    if #names == 0 then
        L('catalog empty, skip write')
        return names
    end
    writeOut(CATALOG_FILE, table.concat(names, '\n'))
    L('catalog built: ' .. #names)
    return names
end

local function getCatalog()
    if _G.REPLAY_CATALOG then return _G.REPLAY_CATALOG end
    local p = moddir() .. '/' .. CATALOG_FILE
    local ok, txt = pcall(function() return File.ReadAllText(p) end)
    local names = {}
    if ok and txt and #txt > 0 then
        for line in txt:gmatch('[^\r\n]+') do
            names[#names + 1] = line
        end
    end
    if #names == 0 then
        names = buildCatalog()
    end
    _G.REPLAY_CATALOG = names
    return names
end

-- ============ UI 基础件 ============
local function newRect(name, parent)
    local go = GameObject(name)
    local ok = pcall(function() go:AddComponent(typeOf('UnityEngine.RectTransform')) end)
    if not ok then
        pcall(function() go:AddComponent(typeOf('UnityEngine.UI.Image')) end)
    end
    if parent then
        local ok = pcall(function() go.transform:SetParent(parent.transform, false) end)
        if not ok then
            T('setparent retry for ' .. name)
            pcall(function() go.transform.parent = parent.transform end)
        end
    end
    return go
end

local function setAnchors(go, amin, amax, pivot, pos, size)
    local rt = go:GetComponent(typeOf('UnityEngine.RectTransform'))
    if rt == nil then
        T('setAnchors: rect nil for ' .. tostring(go.name) .. ', try transform')
        local ok2, t2 = pcall(function() return go.transform end)
        if ok2 and t2 then rt = t2 end
    end
    if rt == nil then return nil end
    rt.anchorMin = amin
    rt.anchorMax = amax
    rt.pivot = pivot
    rt.anchoredPosition = pos
    rt.sizeDelta = size
    return rt
end

local function getFont()
    if _G.REPLAY_FONT then return _G.REPLAY_FONT end
    local f
    pcall(function() f = Font.CreateDynamicFontFromOSFont('Microsoft YaHei', 22) end)
    if f == nil then
        pcall(function() f = Font.CreateDynamicFontFromOSFont('SimHei', 22) end)
    end
    _G.REPLAY_FONT = f
    T('font=' .. tostring(f))
    return f
end

local function makeText(parent, name, str, size, color, align)
    local go = newRect(name, parent)
    local t = go:AddComponent(typeOf('UnityEngine.UI.Text'))
    t.font = getFont()
    t.fontSize = size or 20
    t.text = str or ''
    t.color = color or Color(1, 1, 1, 1)
    pcall(function() t:set_alignment(Enum.ToObject(typeOf('UnityEngine.TextAnchor'), align or 4)) end)
    t.raycastTarget = false
    return go, t
end

local function makePanel(parent, name, color)
    local go = newRect(name, parent)
    local img = go:AddComponent(typeOf('UnityEngine.UI.Image'))
    img.color = color
    img.raycastTarget = false
    return go, img
end

local function makeButton(parent, name, label, onClick)
    local go = newRect(name, parent)
    local img = go:AddComponent(typeOf('UnityEngine.UI.Image'))
    img.color = Color(0.16, 0.20, 0.28, 0.96)
    local btn = go:AddComponent(typeOf('UnityEngine.UI.Button'))
    btn.targetGraphic = img
    local tg, tt = makeText(go, 'Label', label, 27, Color(0.92, 0.92, 0.92, 1), 4)
    setAnchors(tg, Vector2(0, 0), Vector2(1, 1), Vector2(0.5, 0.5), Vector2(0, 0), Vector2(0, 0))
    if onClick then
        -- MakeVoidCallBack 在创建委托时会立即调用一次回调，用 armed 标志屏蔽掉
        local armed = false
        local act = toUnityAction(function()
            if not armed then return end
            onClick()
        end)
        if act then
            local ok, e = pcall(function() btn.onClick:AddListener(act) end)
            if not ok then T('addlistener fail: ' .. tostring(e)) end
            armed = true
        else
            T('no action for ' .. name)
        end
    end
    return go, btn, tt
end

local function ensureEventSystem()
    local ES = luanet.import_type('UnityEngine.EventSystems.EventSystem')
    local ok, es = pcall(function() return ES.current end)
    if ok and es ~= nil then return es end
    local go = GameObject('ReplayEventSystem')
    go:AddComponent(typeOf('UnityEngine.EventSystems.EventSystem'))
    go:AddComponent(typeOf('UnityEngine.EventSystems.StandaloneInputModule'))
    T('created EventSystem')
    return go
end

local function destroyRoot()
    if _G.REPLAY_ROOT then
        pcall(function() GameObject.DestroyImmediate(_G.REPLAY_ROOT) end)
        _G.REPLAY_ROOT = nil
    end
    for _ = 1, 6 do
        local ok, existing = pcall(function() return GameObject.Find('ReplayRoot') end)
        if not (ok and existing) then break end
        pcall(function() GameObject.DestroyImmediate(existing) end)
    end
end

-- ============ 状态 ============
-- 每页 = 3 列 x 16 行
local COLS, ROWS = 3, 16
local PAGE_SIZE = COLS * ROWS

local function getState()
    if not _G.REPLAY_STATE then
        _G.REPLAY_STATE = { page = 1, keyword = '', filtered = nil }
    end
    return _G.REPLAY_STATE
end

local function applyFilter(st)
    local cat = getCatalog()
    local kw = st.keyword
    if kw == nil or kw == '' then
        st.filtered = cat
    else
        local out = {}
        local low = string.lower(kw)
        for i = 1, #cat do
            local n = cat[i]
            if string.find(n, kw, 1, true) or string.find(string.lower(n), low, 1, true) then
                out[#out + 1] = n
            end
        end
        st.filtered = out
    end
    st.page = 1
end

local function jumpTo(name)
    T('jump -> ' .. name)
    destroyRoot()
    -- 先隐藏地图 UI 层（江湖面板等），否则会挡住剧情
    pcall(function() RuntimeData.Instance.mapUI:SetMapUIElementVisiable(false) end)
    T('map ui hidden')
    -- 方式1：直接让地图 UI 播放指定剧情
    local ok, e = pcall(function()
        RuntimeData.Instance.mapUI:LoadStory(name)
    end)
    T('jump LoadStory ok=' .. tostring(ok) .. ' err=' .. tostring(e))
    -- 关掉挡住剧情的面板（人物/江湖面板等），硬编码字段访问最稳
    local ui = RuntimeData.Instance.mapUI
    local done = {}
    local function shut(name, getter)
        local okC = pcall(function()
            local go = getter()
            if go ~= nil then go:SetActive(false); done[#done + 1] = name end
        end)
        if not okC then done[#done + 1] = name .. '!' end
    end
    shut('RolePanel', function() return ui.RolePanel end)
    shut('InfoPanelObj', function() return ui.InfoPanelObj end)
    shut('AchievementPanelObj', function() return ui.AchievementPanelObj end)
    shut('RoleStatePanelObj', function() return ui.RoleStatePanelObj end)
    shut('TeamPanelObj', function() return ui.TeamPanelObj end)
    shut('ItemPanel', function() return ui.ItemPanel end)
    shut('SystemPanelObj', function() return ui.SystemPanelObj end)
    T('panels: ' .. table.concat(done, ','))

    if not ok then
        -- 方式2：走 GameEngine 场景切换
        local ok2, e2 = pcall(function()
            local GE = luanet.import_type('JyGame.GameEngine')
            GE.Instance:SwitchGameScene('story', name)
        end)
        T('jump SwitchGameScene ok=' .. tostring(ok2) .. ' err=' .. tostring(e2))
    end
end

-- ============ 主界面 ============
local function buildUI()
    local st = getState()
    if not st.filtered then applyFilter(st) end
    local total = #st.filtered
    local maxPage = math.max(1, math.ceil(total / PAGE_SIZE))
    if st.page > maxPage then st.page = maxPage end

    destroyRoot()

    local Screen = luanet.import_type('UnityEngine.Screen')
    local sw, sh = Screen.width, Screen.height

    local root = newRect('ReplayRoot', nil)
    _G.REPLAY_ROOT = root
    local canvas = root:AddComponent(typeOf('UnityEngine.Canvas'))
    pcall(function() canvas.sortingOrder = 30000 end)
    root:AddComponent(typeOf('UnityEngine.UI.GraphicRaycaster'))
    local rrt = root:GetComponent(typeOf('UnityEngine.RectTransform'))
    if rrt then
        rrt.anchorMin = Vector2(0.5, 0.5)
        rrt.anchorMax = Vector2(0.5, 0.5)
        rrt.pivot = Vector2(0.5, 0.5)
        rrt.anchoredPosition = Vector2(0, 0)
        rrt.sizeDelta = Vector2(sw, sh)
    end
    pcall(function()
        local Vector3 = luanet.import_type('UnityEngine.Vector3')
        root.transform.localScale = Vector3(0.47, 0.47, 1)
    end)

    ensureEventSystem()

    local A = Vector2(0.5, 0.5)
    local function place(go, cx, cy, w, h)
        setAnchors(go, A, A, A, Vector2(cx, cy), Vector2(w, h))
    end

    local PW = sw * 0.96
    local PH = sh * 0.96
    local hw, hh = PW / 2, PH / 2

    local mask = makePanel(root, 'Mask', Color(0.02, 0.02, 0.04, 0.86))
    place(mask, 0, 0, sw, sh)

    local panel = makePanel(root, 'Panel', Color(0.07, 0.08, 0.12, 0.99))
    place(panel, 0, 0, PW, PH)

    -- 标题栏
    local title = makeText(root, 'Title', '剧情回放', 38, Color(0.96, 0.86, 0.55, 1), 3)
    place(title, -hw + 160, hh - 46, 280, 50)

    local cnt = makeText(root, 'Count', string.format('共 %d 条 · 第 %d/%d 页', total, st.page, maxPage),
        22, Color(0.68, 0.71, 0.78, 1), 5)
    place(cnt, hw - 320, hh - 42, 400, 34)

    local closeGo = makeButton(root, 'Close', '×', function() destroyRoot() end)
    place(closeGo, hw - 36, hh - 42, 44, 44)

    -- ===== 搜索栏（用游戏原生输入框，Unity 运行时 InputField 的 IME 不可用）=====
    local searchW = PW - 330
    local searchBg, searchImg = makePanel(root, 'SearchBg', Color(0.16, 0.18, 0.24, 1))
    searchImg.raycastTarget = true
    place(searchBg, -hw + 30 + searchW / 2, hh - 94, searchW, 52)

    local kwText = (st.keyword ~= nil and st.keyword ~= '') and st.keyword or '点击「搜索」输入关键词（角色名 / 地名 / 剧情名）'
    local kwColor = (st.keyword ~= nil and st.keyword ~= '') and Color(0.97, 0.97, 0.97, 1) or Color(0.55, 0.58, 0.65, 1)
    local kwLabel = makeText(searchBg, 'Text', kwText, 27, kwColor, 3)
    place(kwLabel, 0, 0, searchW - 30, 40)

    local function closeMapPanels()
        pcall(function()
            local ui = RuntimeData.Instance.mapUI
            local g
            g = ui.RolePanel;          if g ~= nil then g:SetActive(false) end
            g = ui.InfoPanelObj;       if g ~= nil then g:SetActive(false) end
            g = ui.AchievementPanelObj; if g ~= nil then g:SetActive(false) end
            g = ui.RoleStatePanelObj;  if g ~= nil then g:SetActive(false) end
            g = ui.TeamPanelObj;       if g ~= nil then g:SetActive(false) end
            g = ui.ItemPanel;          if g ~= nil then g:SetActive(false) end
            g = ui.SystemPanelObj;     if g ~= nil then g:SetActive(false) end
        end)
    end

    local function openSearch()
        -- 先收起自己的界面 + 江湖面板，否则会盖住游戏原生输入框
        destroyRoot()
        closeMapPanels()
        local ok, err = pcall(function()
            local nip = RuntimeData.Instance.mapUI.nameInputPanel
            local armed = false
            local cb = LuaTool.MakeStringCallBack(function(s)
                if not armed then return end
                local st2 = getState()
                st2.keyword = (s ~= nil) and s or ''
                applyFilter(st2)
                buildUI()
            end)
            armed = true
            nip:Show('', cb)
        end)
        T('openSearch ok=' .. tostring(ok) .. ' ' .. tostring(err))
    end

    local searchBtn = makeButton(root, 'SearchBtn', '搜索', openSearch)
    place(searchBtn, hw - 160, hh - 94, 116, 52)

    local clearBtn = makeButton(root, 'ClearBtn', '清空', function()
        local st2 = getState()
        st2.keyword = ''
        applyFilter(st2)
        buildUI()
    end)
    place(clearBtn, hw - 280, hh - 94, 100, 52)

    local resetBtn = makeButton(root, 'ResetBtn', '全部', function()
        local st2 = getState()
        st2.keyword = ''
        applyFilter(st2)
        buildUI()
    end)
    place(resetBtn, hw - 55, hh - 94, 88, 52)

    -- 搜索框本身也能点（双入口，免得按钮点不中）
    pcall(function()
        local fb = searchBg:AddComponent(typeOf('UnityEngine.UI.Button'))
        fb.targetGraphic = searchImg
        local act = toUnityAction(openSearch)
        if act then fb.onClick:AddListener(act) end
        T('searchbg clickable')
    end)

    -- ===== 列表：3 列 x 16 行 =====
    local gridTop = hh - 130
    local gridBottom = -hh + 72
    local rowH = (gridTop - gridBottom) / ROWS
    local colW = (PW - 50) / COLS
    local startIdx = (st.page - 1) * PAGE_SIZE + 1
    for r = 0, ROWS - 1 do
        for c = 0, COLS - 1 do
            local i = c * ROWS + r
            local idx = startIdx + i
            local name = st.filtered[idx]
            local label = name and string.format('%d  %s', idx, name) or ''
            local item = makeButton(root, 'Item' .. i, label, function()
                if name then jumpTo(name) end
            end)
            local itemH = rowH - 3
            place(item, -hw + 25 + colW / 2 + c * colW,
                gridTop - r * rowH - itemH / 2, colW - 8, itemH)
            if name then
                local it = item:GetComponent(typeOf('UnityEngine.UI.Text'))
                -- 列表项文字左对齐更易读
                local lbl = item.transform:GetChild(0)
                if lbl then
                    local lt = lbl:GetComponent(typeOf('UnityEngine.UI.Text'))
                    if lt then
                        lt.fontSize = 25
                        pcall(function()
                            lt:set_alignment(Enum.ToObject(typeOf('UnityEngine.TextAnchor'), 3))
                        end)
                    end
                end
            else
                item:SetActive(false)
            end
        end
    end
    T('grid ok')

    -- ===== 底部：上页 | 1..30 | 下页 =====
    local barY = -hh + 38
    local prev = makeButton(root, 'Prev', '◀', function()
        local st2 = getState()
        if st2.page > 1 then st2.page = st2.page - 1; buildUI() end
    end)
    place(prev, -hw + 48, barY, 70, 50)

    local nextB = makeButton(root, 'Next', '▶', function()
        local st2 = getState()
        local mp = math.max(1, math.ceil(#st2.filtered / PAGE_SIZE))
        if st2.page < mp then st2.page = st2.page + 1; buildUI() end
    end)
    place(nextB, hw - 48, barY, 70, 50)

    local PER = 30
    local groupStart = math.floor((st.page - 1) / PER) * PER + 1
    local btnW, btnGap = 60, 3
    local totalW = PER * btnW + (PER - 1) * btnGap
    local gx0 = -totalW / 2 + btnW / 2
    for i = 0, PER - 1 do
        local pg = groupStart + i
        if pg <= maxPage then
            local isCur = (pg == st.page)
            local pb = makeButton(root, 'Pg' .. i, tostring(pg), function()
                local st2 = getState()
                st2.page = pg
                buildUI()
            end)
            place(pb, gx0 + i * (btnW + btnGap), barY, btnW, 46)
            local plbl = pb.transform:GetChild(0)
            if plbl then
                local plt = plbl:GetComponent(typeOf('UnityEngine.UI.Text'))
                if plt then plt.fontSize = 24 end
            end
            if isCur then
                local pimg = pb:GetComponent(typeOf('UnityEngine.UI.Image'))
                if pimg then pimg.color = Color(0.62, 0.46, 0.10, 0.98) end
            end
        end
    end

    T('build done')
end

-- 关闭时直接收起（本次游戏内不再显示，重开游戏会再出现）
function showFloat()
    destroyRoot()
end

function REPLAY_OPEN()
    T('open begin')
    local ok, err = pcall(function()
        getCatalog()
        buildUI()
    end)
    if not ok then
        L('open error: ' .. tostring(err))
        T('open error: ' .. tostring(err))
    end
end

do
    local cat = nil
    local ok, err = pcall(function() cat = getCatalog() end)
    if not ok then L('catalog error: ' .. tostring(err)) end
    if ok and cat and #cat > 0 then
        L('catalog ready: ' .. #cat .. ' stories')
        L('准备就绪：游戏内点【江湖】即可打开剧情回放')
    end
end
