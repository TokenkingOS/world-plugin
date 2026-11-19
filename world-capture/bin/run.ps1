# 钩子与子命令的包装（Windows PowerShell 5.1）：挑出这台机器的二进制，参数原样交给它，退出码原样交回。
# stdin 不经手：用 & 调，二进制直接继承钩子的 stdin。先读进来再用管道转交会多出 BOM 和换行、解析失败（实测）。
# 文件带 UTF-8 BOM：PowerShell 5.1 读没有 BOM 的脚本时按系统 ANSI 代码页解码。代码里只有 ASCII。
$arch = $env:PROCESSOR_ARCHITEW6432
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
if ($arch -eq 'ARM64') { $arch = 'arm64' } else { $arch = 'amd64' }
$program = Join-Path $PSScriptRoot ('capture-windows-' + $arch + '.exe')
if (-not (Test-Path -LiteralPath $program -PathType Leaf)) {
  # 钩子什么都不输出；子命令照旧交一行拒绝。
  if (@('check', 'enable', 'import', 'export') -ccontains [string]$args[0]) {
    [Console]::Out.Write('{"ok":false,"reason":"failed"}' + "`n")
    exit 1
  }
  exit 0
}
& $program @args
exit $LASTEXITCODE
