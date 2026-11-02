--[[
 剧情回放 MOD  ——  入口/钩子层
 负责：把控制台指令 cg / rp 挂到 GameEngine_extendConsole 上
]]

local Debug = luanet.import_type('UnityEngine.Debug')
local GlobalData = luanet.import_type('JyGame.GlobalData')
local Application = luanet.import_type('UnityEngine.Application')

local function L(s)
    Debug.LogError('[RP] ' .. tostring(s))
end

-- 计算 MOD 目录：<游戏根目录>/gamedata/modcache/<MODKEY>
local function resolveModDir()
    local ok, dataPath = pcall(function() return Application.dataPath end)
    local key = nil
    pcall(function() key = GlobalData.CURRENT_MOD_KEY end)
    if key == nil or key == '' or key == 'current_mod' or key == 'current_mod_key' then
        key = 'SSWS_HG'
    end
    if ok and dataPath and dataPath ~= '' then
        -- dataPath 形如 <游戏根目录>/金庸群侠传X_Data，去掉最后一段得到游戏根目录
        local root = dataPath:gsub('[/\\][^/\\]*$', '')
        return root .. '/gamedata/modcache/' .. key
    end
    return 'gamedata/modcache/' .. key
end

_G.REPLAY_MODDIR = resolveModDir()
_G.REPLAY_MODKEY = (function()
    local k = nil
    pcall(function() k = GlobalData.CURRENT_MOD_KEY end)
    return k
end)()

-- 从磁盘重新加载业务模块（开发期热重载；正式版也保留，方便改数据不用重启）
function REPLAY_RELOAD()
    local File = luanet.import_type('System.IO.File')
    local candidates = {
        _G.REPLAY_MODDIR .. '/lua/replay_main.lua',
        'gamedata/modcache/SSWS_HG/lua/replay_main.lua',
    }
    local res
    for _, path in ipairs(candidates) do
        local ok, v = pcall(function() return File.ReadAllText(path) end)
        if ok then
            res = v
            break
        end
    end
    if not res then
        L('read fail, tried: ' .. table.concat(candidates, ' | '))
        return
    end
    local loader = loadstring or load
    local chunk, err = loader(res)
    if not chunk then
        L('syntax error: ' .. tostring(err))
        return
    end
    local ok2, err2 = pcall(chunk)
    if not ok2 then
        L('runtime error: ' .. tostring(err2))
    end
end

-- 给 GameEngine.lua 的注入点提供实现
function REPLAY_ON_COMMAND(statusType, value)
    if statusType == 'rp' then
        REPLAY_RELOAD()
        return true
    end
    if statusType == 'cg' or statusType == '回放' then
        if not _G.REPLAY_OPEN then
            REPLAY_RELOAD()
        end
        if _G.REPLAY_OPEN then
            pcall(_G.REPLAY_OPEN, value)
            return true
        end
        return false
    end
    return false
end
_G.REPLAY_ON_COMMAND = REPLAY_ON_COMMAND

if not _G.REPLAY_HOOKED then
    _G.REPLAY_HOOKED = true
    local orig = GameEngine_extendConsole
    function GameEngine_extendConsole(ge, statusType, value)
        if statusType == 'rp' then
            REPLAY_RELOAD()
            return true
        end
        if statusType == 'cg' or statusType == '回放' then
            REPLAY_RELOAD()
            if _G.REPLAY_OPEN then pcall(_G.REPLAY_OPEN, value) end
            return true
        end
        if orig then
            return orig(ge, statusType, value)
        end
        return false
    end
    L('hook installed, moddir=' .. tostring(_G.REPLAY_MODDIR) .. ' key=' .. tostring(_G.REPLAY_MODKEY))
end

-- 载入后先跑一次，看看资源是否已就绪
REPLAY_RELOAD()
