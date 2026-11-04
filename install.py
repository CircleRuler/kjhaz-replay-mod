#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""金庸群侠传X「剧情回放」MOD 安装脚本

用法:
    python install.py "你的游戏根目录"

    也可以把本脚本复制到游戏根目录（有 金庸群侠传X.exe 的那层）后直接运行:
    python install.py

做的事:
    1. 把 replay.lua / replay_main.lua 复制到 <游戏>/gamedata/modcache/<MOD>/lua/
    2. 在 main.lua 的 ROOT_getLuaFiles 里注册 replay.lua
    3. 在 GameEngine.lua 的 GameEngine_jianghuContent 里插入呼出入口
    4. 给 Assembly-CSharp.dll 打「去掉授权校验」补丁（不再需要改 hosts）

可重复运行（幂等），MOD 更新后重跑一次即可。
DLL 补丁按代码签名定位，不依赖具体版本号，也不改动文件长度。
"""
import glob
import io
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

MARK_MAIN = '"replay.lua",'
MARK_ENTRY = '-- >>> 剧情回放 MOD 入口'

# ---------------------------------------------------------------------------
# DLL 补丁
#
# 游戏启动时会调 NetworkClass.GetHostAddress("rz.protect-file.com")，
# 返回 "127.0.0.1" 才走离线分支。原来是靠改 hosts 骗过这个判断。
#
# 现在直接把两处比较的 IL 改掉：
#     call <string::op_Inequality 包装>   ->   pop; pop; ldc.i4.0; nop; nop
# 两者栈效果相同（吃掉 2 个 string、压入 1 个 bool），但结果恒为「相等」，
# 等价于域名永远解析到 127.0.0.1。只改 5 字节，文件长度不变。
#
# 补丁点用「前 21 字节 + 原始 5 字节」做签名，已确认在 DLL 中唯一。
# ---------------------------------------------------------------------------
PATCH_SITES = [
    # (名字, 前21字节上下文, 原始5字节, 说明)
    ('ResourceManager.LoadResource',
     '49 28 02 00 00 2b 28 2a 2d 00 06 20 44 22 b2 65 28 04 00 00 2b',
     '28 09 04 00 06'),
    ('RuntimeData.Load',
     '5b 28 03 00 00 2b 28 2a 2d 00 06 20 de 42 1c 1c 28 02 00 00 2b',
     '28 5b 05 00 06'),
]
PATCH_NEW = bytes.fromhex('2626160000')     # pop; pop; ldc.i4.0; nop; nop


def find_dll(game_root):
    """找 <游戏>/*_Data/Managed/Assembly-CSharp.dll"""
    cands = glob.glob(os.path.join(game_root, '*_Data', 'Managed', 'Assembly-CSharp.dll'))
    if not cands:
        sys.exit('找不到 *_Data/Managed/Assembly-CSharp.dll，请确认路径是游戏根目录')
    if len(cands) > 1:
        # 优先带「金庸」的那个
        for c in cands:
            if '金庸' in c:
                return c
    return cands[0]


def patch_dll(game_root):
    dll = find_dll(game_root)
    print('  DLL: %s' % dll)
    data = bytearray(open(dll, 'rb').read())
    orig_len = len(data)

    done = 0
    pending = []
    for name, prefix_hex, call_hex in PATCH_SITES:
        prefix = bytes.fromhex(prefix_hex.replace(' ', ''))
        call = bytes.fromhex(call_hex.replace(' ', ''))
        pos = data.find(prefix)
        if pos < 0:
            print('  [跳过] %s: 找不到代码签名（游戏版本可能不同）' % name)
            continue
        at = pos + len(prefix)
        cur = bytes(data[at:at + 5])
        if cur == PATCH_NEW:
            print('  [已有] %s: 已经是补丁状态' % name)
            done += 1
            continue
        if cur != call:
            print('  [跳过] %s: 签名后紧跟的字节不符（%s）' % (name, cur.hex(' ')))
            continue
        pending.append((name, at, call))

    if not pending:
        if done == len(PATCH_SITES):
            print('  DLL 已是补丁状态，跳过')
        else:
            print('  DLL 未能打补丁：没有任何补丁点被识别。')
            print('  如果是新版本游戏，可以到仓库提 issue；')
            print('  或者直接把仓库 dll/Assembly-CSharp.dll 复制过去覆盖（需版本一致）。')
        return

    # 备份原版（只备份一次）
    bak = dll + '.orig_backup'
    if not os.path.exists(bak):
        shutil.copy2(dll, bak)
        print('  已备份原版 -> %s' % os.path.basename(bak))

    for name, at, call in pending:
        data[at:at + 5] = PATCH_NEW
        print('  [补丁] %s: 0x%06X  %s -> %s' %
              (name, at, call.hex(' '), PATCH_NEW.hex(' ')))

    assert len(data) == orig_len, '内部错误：补丁改变了文件长度'
    open(dll, 'wb').write(bytes(data))
    print('  DLL 补丁完成（共 %d 处，文件长度未变）' % len(pending))
    print('  提示：如果 hosts 里还有 rz.protect-file.com 那条，现在可以删掉了。')


def restore_dll(game_root):
    dll = find_dll(game_root)
    bak = dll + '.orig_backup'
    if not os.path.exists(bak):
        sys.exit('没有找到备份 %s，无法还原' % bak)
    shutil.copy2(bak, dll)
    print('已还原官方原版 DLL: %s' % dll)


def find_mod_dir(game_root):
    base = os.path.join(game_root, 'gamedata', 'modcache')
    if not os.path.isdir(base):
        sys.exit('找不到 %s，请确认路径是游戏根目录（有 金庸群侠传X.exe 的那层）' % base)
    cands = [d for d in os.listdir(base)
             if os.path.isdir(os.path.join(base, d)) and os.path.isdir(os.path.join(base, d, 'lua'))]
    if not cands:
        sys.exit('modcache 下没有找到带 lua 目录的 MOD')
    if len(cands) == 1:
        return os.path.join(base, cands[0])
    # 多个时优先 SSWS_HG
    if 'SSWS_HG' in cands:
        return os.path.join(base, 'SSWS_HG')
    print('检测到多个 MOD，请选择:')
    for i, c in enumerate(cands):
        print('  [%d] %s' % (i, c))
    idx = int(input('序号: ').strip())
    return os.path.join(base, cands[idx])


def patch_main_lua(path):
    src = io.open(path, encoding='utf-8').read()
    if MARK_MAIN in src:
        print('  main.lua 已注册过，跳过')
        return
    m = re.search(r'function\s+ROOT_getLuaFiles\s*\(\s*\)\s*return\s*\{', src)
    if not m:
        sys.exit('main.lua 里找不到 ROOT_getLuaFiles 的 return 表，请手动注册')
    # 在表的最后一个元素后插入
    tail = src.find('\n\t}', m.end())
    if tail < 0:
        tail = src.find('\n}', m.end())
    if tail < 0:
        sys.exit('main.lua 结构异常，请手动注册')
    src = src[:tail] + '\n\t\t"replay.lua",' + src[tail:]
    io.open(path, 'w', encoding='utf-8').write(src)
    print('  main.lua 已注册 replay.lua')


def patch_gameengine(path):
    src = io.open(path, encoding='utf-8').read()
    if MARK_ENTRY in src:
        print('  GameEngine.lua 已插入入口，跳过')
        return
    m = re.search(r'function\s+GameEngine_jianghuContent\s*\([^)]*\)\s*\n', src)
    if not m:
        sys.exit('GameEngine.lua 里找不到 GameEngine_jianghuContent，请手动插入入口')
    inject = ('\t-- >>> 剧情回放 MOD 入口 >>>\n'
              '\t-- 只在点「江湖历练」标签时呼出；点头像打开面板时不呼出\n'
              '\tpcall(function()\n'
              '\t\tif not _G.REPLAY_OPEN then return end\n'
              '\t\tlocal Input = luanet.import_type(\'UnityEngine.Input\')\n'
              '\t\tlocal Screen = luanet.import_type(\'UnityEngine.Screen\')\n'
              '\t\tlocal mp = Input.mousePosition\n'
              '\t\tlocal rx = mp.x / Screen.width\n'
              '\t\tlocal ry = mp.y / Screen.height\n'
              '\t\tif rx > 0.14 and rx < 0.42 and ry > 0.72 and ry < 0.94 then\n'
              '\t\t\t_G.REPLAY_OPEN()\n'
              '\t\tend\n'
              '\tend)\n'
              '\t-- <<< 剧情回放 MOD 入口 <<<\n')
    src = src[:m.end()] + inject + src[m.end():]
    io.open(path, 'w', encoding='utf-8').write(src)
    print('  GameEngine.lua 已插入呼出入口')


def looks_like_game_root(path):
    if os.path.isdir(os.path.join(path, 'gamedata', 'modcache')):
        return True
    for f in os.listdir(path):
        if f.lower().endswith('.exe') and '金庸' in f:
            return True
    return False


def main():
    if len(sys.argv) >= 2 and sys.argv[1] in ('--restore', '-r'):
        root = sys.argv[2] if len(sys.argv) >= 3 else os.getcwd()
        restore_dll(root)
        return

    if len(sys.argv) >= 2:
        game_root = sys.argv[1]
    else:
        # 没传参数时，先看当前目录是不是游戏根目录
        here = os.getcwd()
        if looks_like_game_root(here):
            game_root = here
            print('未指定路径，使用当前目录: %s' % here)
        else:
            print(__doc__)
            print('提示：把本脚本放进游戏根目录（有 金庸群侠传X.exe 的那层）再双击运行，')
            print('      或者运行  python install.py "游戏根目录"')
            sys.exit(1)

    print('\n[1/2] 给游戏主程序打补丁（去掉授权校验）')
    patch_dll(game_root)

    print('\n[2/2] 安装剧情回放 MOD')
    mod_dir = find_mod_dir(game_root)
    lua_dir = os.path.join(mod_dir, 'lua')
    print('MOD 目录: %s' % mod_dir)

    for f in ('replay.lua', 'replay_main.lua'):
        shutil.copy2(os.path.join(HERE, 'lua', f), os.path.join(lua_dir, f))
        print('  已复制 %s' % f)

    patch_main_lua(os.path.join(lua_dir, 'main.lua'))
    patch_gameengine(os.path.join(lua_dir, 'GameEngine.lua'))

    print('\n安装完成。不需要改 hosts 了。')
    print('进游戏后点左上角主角头像（打开「江湖」面板），再点「江湖历练」标签即可呼出剧情回放。')


if __name__ == '__main__':
    main()
