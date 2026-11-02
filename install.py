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

可重复运行（幂等），MOD 更新后重跑一次即可。
"""
import io
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

MARK_MAIN = '"replay.lua",'
MARK_ENTRY = '-- >>> 剧情回放 MOD 入口'


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
              '\tpcall(function()\n'
              '\t\tif _G.REPLAY_OPEN then _G.REPLAY_OPEN() end\n'
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
    mod_dir = find_mod_dir(game_root)
    lua_dir = os.path.join(mod_dir, 'lua')
    print('MOD 目录: %s' % mod_dir)

    for f in ('replay.lua', 'replay_main.lua'):
        shutil.copy2(os.path.join(HERE, 'lua', f), os.path.join(lua_dir, f))
        print('  已复制 %s' % f)

    patch_main_lua(os.path.join(lua_dir, 'main.lua'))
    patch_gameengine(os.path.join(lua_dir, 'GameEngine.lua'))

    print('\n安装完成。进游戏后点左上角主角头像（打开「江湖」面板）即可呼出剧情回放。')


if __name__ == '__main__':
    main()
