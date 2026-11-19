#!/bin/sh
# 钩子与子命令的包装（Mac）：挑出这台机器的二进制，参数原样交给它，退出码原样交回；stdin 不经手。
# 装了 Git Bash 的 Windows 会把 Claude Code 那一行钩子整行交给 Git Bash，PowerShell 那段已经干过活了：不是 Darwin 就不跑。
[ -n "${WORLD_AUTO_EXTRACT_ROUND:-}" ] && exit 0
case "$(uname -s 2>/dev/null)" in
  Darwin) ;;
  MINGW* | MSYS* | CYGWIN*)
    case "${1:-}" in check | enable | import | export) printf '{"ok":false,"reason":"use_powershell"}\n'; exit 1 ;; esac
    exit 0 ;;
  *)
    case "${1:-}" in
      check) printf '{"supported":false,"reason":"not_macos","system":"%s","os_version":""}\n' "$(uname -s 2>/dev/null | tr -cd 'A-Za-z0-9._-')"; exit 0 ;;
      enable | import | export) printf '{"ok":false,"reason":"not_macos"}\n'; exit 1 ;;
    esac
    exit 0 ;;
esac
case "$(uname -m 2>/dev/null)" in
  arm64) arch=arm64 ;;
  *) arch=amd64 ;;
esac
program="$(dirname -- "$0")/capture-darwin-$arch"
case "${1:-}" in
  check | enable | import | export)
    [ -x "$program" ] || { printf '{"ok":false,"reason":"failed"}\n'; exit 1; }
    exec "$program" "$@" ;;
esac
# 钩子：程序本身什么都不输出、退出码总是 0；它起不来（被系统拦下、文件坏了）时这里也不往外写、照样交 0，同 0.1.7 的脚本。
[ -x "$program" ] && "$program" "$@" >/dev/null 2>&1
exit 0
