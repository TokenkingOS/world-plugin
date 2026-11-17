# 本机采集的启动脚本（Windows PowerShell 5.1）：capture.ps1 <claude|codex> <事件>，钩子的 JSON 从 stdin 来。
# 与 capture.sh 同一套逻辑，只有数据目录、程序位置和脱离方式不同。钩子的标准输出会被 Agent 当作指令解析，
# 所以这里什么都不输出，任何失败都静默 exit 0。读取规则逐条照 packages/world-capture 的 adapters.mjs、index.mjs、
# contract.mjs，语义按 JS 算：字符串比较一律区分大小写、按序号比，正则只用显式字符类（.NET 的 \w \s \b 认 Unicode）。
# 文件带 UTF-8 BOM：PowerShell 5.1 读没有 BOM 的脚本时按系统 ANSI 代码页解码。代码里不写非 ASCII 字面量。
# 另有三个子命令给「开始采集」那次对话里的 Agent 用（capture.ps1 <check|enable|import> <claude|codex> [选择记录文件]），
# 规则同 setup.jq，见文件末尾那一节。

if ($env:WORLD_AUTO_EXTRACT_ROUND) { exit 0 }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Off

$script:Self = $PSCommandPath
$script:Json = $null

# 脚本级的初始化都放在这里，在最外层的 try 里跑：出错也不往标准错误写东西。
function Initialize-Capture {
  $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
  $script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
  $script:Ordinal = [System.StringComparison]::Ordinal
  $script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
  $script:Sha = [System.Security.Cryptography.SHA256]::Create()
  # JSON.stringify 的转义表：" \ 与 \b \f \n \r \t 用短转义，其余 0x00-0x1F 写成小写 \u00xx。
  $script:Escapes = @(
    , @([string][char]92, '\\')
    , @([string][char]34, '\"')
    , @([string][char]8, '\b')
    , @([string][char]12, '\f')
    , @([string][char]10, '\n')
    , @([string][char]13, '\r')
    , @([string][char]9, '\t')
  )
  foreach ($code in 0..31) {
    if (@(8, 9, 10, 12, 13) -notcontains $code) { $script:Escapes += , @([string][char]$code, ('\u{0:x4}' -f $code)) }
  }
  $script:LonePattern = New-Object System.Text.RegularExpressions.Regex('[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]')
  $script:LoneEscape = New-Object System.Text.RegularExpressions.Regex('(?<p>(?<!\\)(?:\\\\)*)(?:(?<pair>\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2})|\\u[dD][89a-fA-F][0-9a-fA-F]{2})')
  $script:LoneEscapeEvaluator = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)
    if ($m.Groups['pair'].Success) { return $m.Value }
    return $m.Groups['p'].Value + '\udbff\udfff'
  }
  $script:NonCharacter = [char]::ConvertFromUtf32(0x10FFFF)
  $script:LineLone = $false
  $script:LoneEvaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) '\u' + ([int][char]$m.Value[0]).ToString('x4') }
  # JS 的 String.prototype.trim 去掉的字符（WhiteSpace 加 LineTerminator）；.NET 无参的 Trim() 少 U+FEFF、多 U+0085。
  $script:Ws = [char[]](@(9, 10, 11, 12, 13, 32, 0xA0, 0x1680) + (0x2000..0x200A) + @(0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF))
  $script:WsClass = '\t\n\u000b\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff'
  # JS 正则里 . 不匹配、多行模式的 ^ $ 认作行边界的字符。
  $script:Eol = '\n\r\u2028\u2029'
  $script:DailyMark = [string][char]0x3010 + [char]0x65E5 + [char]0x8FDB + [char]0x5C55
  $script:UtcPattern = New-Object System.Text.RegularExpressions.Regex('\A(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(?:\.(?<f>[0-9]+))?(?<z>Z|(?<sign>[+-])(?<oh>[0-9]{2}):(?<om>[0-9]{2}))\z')
  $script:Control = New-Object System.Text.RegularExpressions.Regex('[\x00-\x08\x0b\x0c\x0e-\x1f]')
  # 确认原话里要逐字出现的词（同 setup.jq 的 SCOPE_WORDS）：读的是哪种会话、哪个文件夹、包括以后新开的、持续采集；
  # Codex 还要写明只读没压缩的 .jsonl。中文词按码点拼，代码行保持 ASCII。
  $later = -join @([char]0x4EE5, [char]0x540E, [char]0x65B0, [char]0x5F00)
  $continuous = -join @([char]0x6301, [char]0x7EED)
  $script:ScopeWords = @{ claude = @('Claude Code', 'projects', $later, $continuous); codex = @('Codex', 'sessions', '.jsonl', $later, $continuous) }
  Initialize-Round
}

# ---------- JS 语义的小件 ----------

function Test-Is($v, [string]$s) { return ($v -is [string]) -and [string]::Equals($v, $s, $script:Ordinal) }

function Test-Number($v) {
  return ($v -is [int]) -or ($v -is [long]) -or ($v -is [decimal]) -or ($v -is [double]) -or ($v -is [single]) `
    -or ($v -is [int16]) -or ($v -is [byte]) -or ($v -is [uint32]) -or ($v -is [uint64])
}

# Dictionary`2 的 IDictionary.Contains 是显式接口成员，PowerShell 5.1 调不到，所以按类型分别用 Contains / ContainsKey。
function Test-HasKey($obj, [string]$key) {
  if ($obj -is [System.Collections.Specialized.OrderedDictionary]) { return $obj.Contains($key) }
  if ($obj -is [System.Collections.IDictionary]) { return $obj.ContainsKey($key) }
  return $false
}

# 取 JSON 对象的字段；不是对象或没有这个字段时是 $null。数组原样返回，不让管道把它拆开。
function Get-Field($obj, [string]$key) {
  if (Test-HasKey $obj $key) {
    $v = $obj[$key]
    if ($null -eq $v) { return $null }
    return , $v
  }
  return $null
}

function Test-Truthy($v) {
  if ($null -eq $v) { return $false }
  if ($v -is [bool]) { return $v }
  if ($v -is [string]) { return $v.Length -gt 0 }
  if (Test-Number $v) { return $v -ne 0 }
  return $true
}

function Format-JsNumber($v) {
  if (($v -is [double]) -or ($v -is [single])) {
    if (([math]::Floor($v) -eq $v) -and ([math]::Abs($v) -lt 1e21)) { return ([decimal]$v).ToString('0', $script:Invariant) }
    return $v.ToString('R', $script:Invariant)
  }
  if ($v -is [decimal]) {
    if ([decimal]::Truncate($v) -eq $v) { return $v.ToString('0', $script:Invariant) }
    return ([double]$v).ToString('R', $script:Invariant)
  }
  return $v.ToString($script:Invariant)
}

# JS 模板字符串里 `${x}` 的结果（undefined 由调用方处理）。
function ConvertTo-JsTemplate($v) {
  if ($null -eq $v) { return 'null' }
  if ($v -is [string]) { return $v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if (Test-Number $v) { return Format-JsNumber $v }
  if ($v -is [System.Collections.IDictionary]) { return '[object Object]' }
  if ($v -is [System.Collections.IList]) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($x in $v) { if ($null -eq $x) { $parts.Add('') } else { $parts.Add((ConvertTo-JsTemplate $x)) } }
    return ($parts -join ',')
  }
  return [string]$v
}

# JSON.stringify(string)：转义表见 Initialize-Capture，孤立代理项写成小写 \udxxx，其他字符原样。
# 不用 ConvertTo-Json：它还会转义 < > & ' 等字符。
function ConvertTo-JsString([string]$s) {
  foreach ($pair in $script:Escapes) {
    if ($s.IndexOf($pair[0], $script:Ordinal) -ge 0) { $s = $s.Replace($pair[0], $pair[1]) }
  }
  if ($script:LonePattern.IsMatch($s)) { $s = $script:LonePattern.Replace($s, $script:LoneEvaluator) }
  return '"' + $s + '"'
}

function ConvertTo-JsJson($v) {
  if ($null -eq $v) { return 'null' }
  if ($v -is [string]) { return ConvertTo-JsString $v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if (Test-Number $v) { return Format-JsNumber $v }
  $parts = New-Object System.Collections.Generic.List[string]
  if ($v -is [System.Collections.IDictionary]) {
    foreach ($k in $v.Keys) { $parts.Add((ConvertTo-JsString ([string]$k)) + ':' + (ConvertTo-JsJson $v[$k])) }
    return '{' + ($parts -join ',') + '}'
  }
  if ($v -is [System.Collections.IEnumerable]) {
    foreach ($x in $v) { $parts.Add((ConvertTo-JsJson $x)) }
    return '[' + ($parts -join ',') + ']'
  }
  return ConvertTo-JsString ([string]$v)
}

function Test-WellFormed([string]$s) { return -not $script:LonePattern.IsMatch($s) }

function Test-Blank([string]$s) { return $s.Trim($script:Ws).Length -eq 0 }
function Get-LTrim([string]$s) { return $s.TrimStart($script:Ws) }

# ---------- 时间：contract.mjs 的 utc 与 before ----------

function Get-FloorDiv([long]$a, [long]$b) { return [long][math]::Floor($a / $b) }

function Get-DaysFromCivil([long]$y, [long]$m, [long]$d) {
  if ($m -le 2) { $y = $y - 1 }
  $era = Get-FloorDiv $y 400
  $yoe = $y - $era * 400
  if ($m -gt 2) { $mp = $m - 3 } else { $mp = $m + 9 }
  $doe = $yoe * 365 + (Get-FloorDiv $yoe 4) - (Get-FloorDiv $yoe 100) + (Get-FloorDiv (153 * $mp + 2) 5) + $d - 1
  return $era * 146097 + $doe - 719468
}

# Date#toISOString 到秒为止的那一段：0-9999 年写四位，之外写正负号加六位。
function Format-IsoSeconds([long]$t) {
  $days = Get-FloorDiv $t 86400
  $s = $t - $days * 86400
  $z = $days + 719468
  $era = Get-FloorDiv $z 146097
  $doe = $z - $era * 146097
  $yoe = Get-FloorDiv ($doe - (Get-FloorDiv $doe 1460) + (Get-FloorDiv $doe 36524) - (Get-FloorDiv $doe 146096)) 365
  $doy = $doe - (365 * $yoe + (Get-FloorDiv $yoe 4) - (Get-FloorDiv $yoe 100))
  $mp = Get-FloorDiv (5 * $doy + 2) 153
  $d = $doy - (Get-FloorDiv (153 * $mp + 2) 5) + 1
  if ($mp -lt 10) { $m = $mp + 3 } else { $m = $mp - 9 }
  $y = $yoe + $era * 400
  if ($m -le 2) { $y = $y + 1 }
  if (($y -ge 0) -and ($y -le 9999)) { $year = $y.ToString($script:Invariant).PadLeft(4, '0') }
  elseif ($y -lt 0) { $year = '-' + (-$y).ToString($script:Invariant).PadLeft(6, '0') }
  else { $year = '+' + $y.ToString($script:Invariant).PadLeft(6, '0') }
  $two = { param($n) ([long]$n).ToString($script:Invariant).PadLeft(2, '0') }
  return $year + '-' + (& $two $m) + '-' + (& $two $d) + 'T' + (& $two (Get-FloorDiv $s 3600)) + ':' `
    + (& $two (Get-FloorDiv ($s % 3600) 60)) + ':' + (& $two ($s % 60))
}

# 带时区的显式时刻换成 UTC；秒以下照原样保留全部位数，没有就补 .000。不合法返回 $null。
function ConvertTo-Utc($value) {
  if (-not ($value -is [string])) { return $null }
  $m = $script:UtcPattern.Match($value)
  if (-not $m.Success) { return $null }
  $y = [long]$m.Groups['y'].Value; $mo = [long]$m.Groups['mo'].Value; $d = [long]$m.Groups['d'].Value
  $h = [long]$m.Groups['h'].Value; $mi = [long]$m.Groups['mi'].Value; $s = [long]$m.Groups['s'].Value
  $oh = 0; $om = 0; $sign = 1
  if ($m.Groups['sign'].Success) {
    $oh = [long]$m.Groups['oh'].Value; $om = [long]$m.Groups['om'].Value
    if ($m.Groups['sign'].Value -ceq '-') { $sign = -1 }
  }
  $leap = (($y % 4) -eq 0) -and ((($y % 100) -ne 0) -or (($y % 400) -eq 0))
  $month = @(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
  if ($leap) { $month[1] = 29 }
  if (($y -lt 1) -or ($mo -lt 1) -or ($mo -gt 12)) { return $null }
  if (($d -lt 1) -or ($d -gt $month[$mo - 1]) -or ($h -gt 23) -or ($mi -gt 59) -or ($s -gt 59) -or ($oh -gt 23) -or ($om -gt 59)) { return $null }
  $t = (Get-DaysFromCivil $y $mo $d) * 86400 + $h * 3600 + $mi * 60 + $s - $sign * ($oh * 3600 + $om * 60)
  if ($m.Groups['f'].Success) { $fraction = $m.Groups['f'].Value } else { $fraction = '000' }
  return (Format-IsoSeconds $t).Substring(0, 19) + '.' + $fraction + 'Z'
}

function Test-Before([string]$a, [string]$b) {
  $pa = $a.Substring(0, 19); $pb = $b.Substring(0, 19)
  if ($pa -cne $pb) { return [string]::CompareOrdinal($pa, $pb) -lt 0 }
  $x = $a.Substring(20, $a.Length - 21); $y = $b.Substring(20, $b.Length - 21)
  $w = [math]::Max($x.Length, $y.Length)
  return [string]::CompareOrdinal($x.PadRight($w, '0'), $y.PadRight($w, '0')) -lt 0
}

# ---------- adapters.mjs 的判断 ----------

function Get-TextBlocks($value, [string[]]$kinds) {
  $out = New-Object System.Collections.Generic.List[string]
  if ($value -is [string]) { $out.Add($value) }
  elseif ($value -is [System.Collections.IList]) {
    foreach ($block in $value) {
      if ($block -is [System.Collections.IDictionary]) {
        $type = Get-Field $block 'type'
        $text = Get-Field $block 'text'
        if (($type -is [string]) -and ($kinds -ccontains $type) -and ($text -is [string])) { $out.Add($text) }
      }
    }
  }
  return $out
}

function Test-KnownContent($content) {
  if ($content -is [string]) { return $true }
  if (-not ($content -is [System.Collections.IList])) { return $false }
  foreach ($block in $content) {
    if (-not ($block -is [System.Collections.IDictionary])) { return $false }
    $type = Get-Field $block 'type'
    if (-not ($type -is [string])) { return $false }
    if ((Test-Is $type 'text') -and -not ((Get-Field $block 'text') -is [string])) { return $false }
  }
  return $true
}

function Test-RealRequest([string]$s) {
  if (Test-Blank $s) { return $false }
  $t = Get-LTrim $s
  foreach ($prefix in @('<', '# AGENTS.md', '[Request interrupted', 'Caveat:')) {
    if ($t.StartsWith($prefix, $script:Ordinal)) { return $false }
  }
  return $true
}

function Test-SkillDirectory([string]$s, [string]$name) {
  if ($s.IndexOf('Base directory for this skill: ', $script:Ordinal) -lt 0) { return $false }
  $pattern = '(?<![^' + $script:Eol + '])Base directory for this skill: [^' + $script:Eol + ']*[\\/]' + $name + '[' + $script:WsClass + ']*(?![^' + $script:Eol + '])'
  return [regex]::IsMatch($s, $pattern)
}

function Test-DailyRequest([string]$s) {
  $t = Get-LTrim $s
  if ([regex]::IsMatch($t, '\A[$/](?:tkos-|world:|skill:(?:tkos-)?)?world-daily(?![A-Za-z0-9_-])')) { return $true }
  if ($s.Contains('<command-name>/') -and [regex]::IsMatch($s, '<command-name>/(?:tkos-|world:)?world-daily</command-name>')) { return $true }
  if (Test-SkillDirectory $s '(?:tkos-)?world-daily') { return $true }
  return [regex]::IsMatch($t, '\A<skill name="(?:tkos-)?world-daily"')
}

function Test-ExtractRequest([string]$s) {
  $t = Get-LTrim $s
  if ([regex]::IsMatch($t, '\A[$/](?:world:|skill:)?world-source-extract(?![A-Za-z0-9_])')) { return $true }
  if ($s.Contains('<command-name>/') -and [regex]::IsMatch($s, '<command-name>/(?:world:)?world-source-extract</command-name>')) { return $true }
  if (Test-SkillDirectory $s 'world-source-extract') { return $true }
  return [regex]::IsMatch($t, '\A<skill name="world-source-extract"')
}

function Test-SelfReport([string]$s) { return (Test-DailyRequest $s) -or (Test-ExtractRequest $s) }

function Test-DailyWrite($name, $arguments) {
  if (-not ($name -is [string])) { return $false }
  if (-not $name.EndsWith('world_record_event', $script:Ordinal)) { return $false }
  if ($arguments -is [string]) { $text = $arguments }
  elseif ($null -eq $arguments) { $text = '{}' }
  else { $text = ConvertTo-JsJson $arguments }
  return $text.Contains($script:DailyMark)
}

# ---------- 一段增量的解析状态 ----------

function Add-Issue([string]$code) { $script:Issues[$code] = 1 + [int]$script:Issues[$code] }

# Claude：adapters.mjs 的 claude()。状态：recognized、daily。每段增量读完时把 pending 交出并清空，
# 等于库在这个位置读完整个文件。
function Step-Claude($r, [long]$n) {
  $t = Get-Field $r 'type'
  $isMessage = (Test-Is $t 'user') -or (Test-Is $t 'assistant')
  if (((Get-Field $r 'sessionId') -is [string]) -and $isMessage) { $script:St.recognized = $true }
  if ((Test-Truthy (Get-Field $r 'isSidechain')) -or -not $isMessage) { return }
  $message = Get-Field $r 'message'
  $content = Get-Field $message 'content'
  if (-not (Test-KnownContent $content)) { Add-Issue 'parse_failed'; return }
  $texts = @(Get-TextBlocks $content @('text') | Where-Object { -not (Test-Blank $_) })
  if (Test-HasKey $r 'sessionId') { $session = ConvertTo-JsTemplate $r['sessionId'] } else { $session = 'undefined' }
  $key = $n.ToString($script:Invariant)
  foreach ($candidate in @((Get-Field $message 'id'), (Get-Field $r 'uuid'), (Get-Field $r 'timestamp'))) {
    if ($null -ne $candidate) { $key = ConvertTo-JsTemplate $candidate; break }
  }
  $raw = Get-Field $r 'timestamp'
  $enters = $false
  foreach ($x in $texts) { if (Test-SelfReport $x) { $enters = $true; break } }
  if ((-not $enters) -and ($content -is [System.Collections.IList])) {
    foreach ($block in $content) {
      if ((Test-Is (Get-Field $block 'type') 'tool_use') -and (Test-DailyWrite (Get-Field $block 'name') (Get-Field $block 'input'))) { $enters = $true; break }
    }
  }
  if ($enters) {
    if (($null -ne $script:Pending) -and -not $script:St.daily) { $script:Out.Add($script:Pending) }
    $script:Pending = $null
    $script:St.daily = $true
  }
  elseif ((Test-Is $t 'assistant') -and ($texts.Count -gt 0) -and -not $script:St.daily) {
    $script:Pending = @{ role = 'assistant'; text = $texts[$texts.Count - 1]; raw = $raw; id = "$session/assistant/$key"; lone = $script:LineLone }
  }
  elseif ((Test-Is $t 'user') -and -not (Test-Truthy (Get-Field $r 'isMeta'))) {
    $requests = @($texts | Where-Object { Test-RealRequest $_ })
    if ($requests.Count -gt 0) {
      if ($null -ne $script:Pending) { $script:Out.Add($script:Pending) }
      $script:Pending = $null
      $script:St.daily = $false
      $script:Out.Add(@{ role = 'user'; text = ($requests -join "`n"); raw = $raw; id = "$session/user/$key"; lone = $script:LineLone })
    }
  }
}

function Complete-Claude {
  if ($script:St.recognized -and ($null -ne $script:Pending)) { $script:Out.Add($script:Pending) }
  $script:Pending = $null
  return [bool]$script:St.recognized
}

# Codex：adapters.mjs 的 codex()。状态：session、subagent、两种消息各自见过的最高优先级、daily。
# 优先级按到目前为止读过的全部内容取最大，库按整份文件取。
function Add-CodexMessage([string]$role, $text, [int]$priority, $id, $ts, [long]$n) {
  if ($null -eq $id) { if ($null -ne $ts) { $id = $ts } else { $id = 'line-' + $n.ToString($script:Invariant) } }
  $script:Msgs.Add(@{ role = $role; text = $text; priority = $priority; raw = $ts; id = $id; lone = $script:LineLone })
}

function Step-Codex($r, [long]$n) {
  $type = Get-Field $r 'type'
  $p = Get-Field $r 'payload'
  $pt = Get-Field $p 'type'
  $ts = Get-Field $r 'timestamp'
  if (Test-Is $type 'session_meta') {
    $id = Get-Field $p 'id'
    if ($id -is [string]) { $script:St.session = $id } else { $script:St.session = $null }
    $script:St.subagent = (Test-Is (Get-Field $p 'thread_source') 'subagent') -or (Test-Truthy (Get-Field (Get-Field $p 'source') 'subagent'))
  }
  if (Test-Is $type 'event_msg') {
    if ((Test-Is $pt 'user_message') -and ((Get-Field $p 'message') -is [string])) {
      Add-CodexMessage 'user' (Get-Field $p 'message') 1 $null $ts $n
    }
    if ((Test-Is $pt 'task_complete') -and ((Get-Field $p 'last_agent_message') -is [string])) {
      Add-CodexMessage 'assistant' (Get-Field $p 'last_agent_message') 1 (Get-Field $p 'turn_id') $ts $n
    }
    $item = Get-Field $p 'item'
    if ((Test-Is $pt 'item_completed') -and (Test-Truthy $item)) {
      $it = Get-Field $item 'type'
      if (Test-Is $it 'UserMessage') {
        foreach ($x in @(Get-TextBlocks (Get-Field $item 'content') @('text'))) { Add-CodexMessage 'user' $x 2 (Get-Field $item 'id') $ts $n }
      }
      if ((Test-Is $it 'AgentMessage') -and (Test-Is (Get-Field $item 'phase') 'final_answer')) {
        foreach ($x in @(Get-TextBlocks (Get-Field $item 'content') @('text', 'Text'))) { Add-CodexMessage 'assistant' $x 2 (Get-Field $item 'id') $ts $n }
      }
      if ((Test-Is $it 'McpToolCall') -and (Test-DailyWrite (Get-Field $item 'tool') (Get-Field $item 'arguments'))) {
        Add-CodexMessage 'daily' '' 0 $null $ts $n
      }
    }
  }
  if (Test-Is $type 'response_item') {
    if (Test-Is $pt 'message') {
      $role = Get-Field $p 'role'
      if (Test-Is $role 'user') {
        foreach ($x in @(Get-TextBlocks (Get-Field $p 'content') @('input_text'))) { Add-CodexMessage 'user' $x 0 $null $ts $n }
      }
      if ((Test-Is $role 'assistant') -and ((Test-Is (Get-Field $p 'phase') 'final_answer') -or (Test-Is (Get-Field $p 'channel') 'final'))) {
        foreach ($x in @(Get-TextBlocks (Get-Field $p 'content') @('output_text'))) { Add-CodexMessage 'assistant' $x 0 $null $ts $n }
      }
    }
    if ((Test-Is $pt 'function_call') -or (Test-Is $pt 'custom_tool_call')) {
      $arguments = Get-Field $p 'arguments'
      if ($null -eq $arguments) { $arguments = Get-Field $p 'input' }
      if (Test-DailyWrite (Get-Field $p 'name') $arguments) { Add-CodexMessage 'daily' '' 0 $null $ts $n }
    }
  }
}

function Complete-Codex {
  foreach ($m in $script:Msgs) {
    if (($m.role -ceq 'user') -and ($m.priority -gt $script:St.up)) { $script:St.up = $m.priority }
    if (($m.role -ceq 'assistant') -and ($m.priority -gt $script:St.ap)) { $script:St.ap = $m.priority }
  }
  $session = $script:St.session
  $records = New-Object System.Collections.Generic.List[object]
  foreach ($m in $script:Msgs) {
    if (($m.role -ceq 'daily') -or (($m.role -ceq 'user') -and ($m.priority -eq $script:St.up) -and (Test-SelfReport $m.text))) {
      $script:St.daily = $true
    }
    elseif (($m.role -ceq 'user') -and ($m.priority -eq $script:St.up) -and (Test-RealRequest $m.text)) {
      $script:St.daily = $false
      $records.Add(@{ role = 'user'; text = $m.text; raw = $m.raw; id = "$session/user/" + (ConvertTo-JsTemplate $m.id); lone = $m.lone })
    }
    elseif (($m.role -ceq 'assistant') -and ($m.priority -eq $script:St.ap) -and -not $script:St.daily -and -not (Test-Blank $m.text)) {
      $records.Add(@{ role = 'assistant'; text = $m.text; raw = $m.raw; id = "$session/assistant/" + (ConvertTo-JsTemplate $m.id); lone = $m.lone })
    }
  }
  $script:Msgs.Clear()
  if (-not $script:St.subagent) { foreach ($e in $records) { $script:Out.Add($e) } }
  return ($script:St.session -is [string])
}

# ---------- 文件与目录 ----------

function Get-Sha256Hex([byte[]]$bytes) {
  return ([System.BitConverter]::ToString($script:Sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
}
function Get-TextSha256([string]$s) { return Get-Sha256Hex ($script:Utf8.GetBytes($s)) }

function Open-Shared([string]$path) {
  return New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
}

function Read-SharedText([string]$path) {
  $fs = Open-Shared $path
  try { $reader = New-Object System.IO.StreamReader($fs, $script:Utf8); return $reader.ReadToEnd() } finally { $fs.Dispose() }
}

function Read-Bytes($fs, [long]$start, [long]$count) {
  $buffer = New-Object byte[] ([int]$count)
  [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
  $total = 0
  while ($total -lt $count) {
    $got = $fs.Read($buffer, $total, [int]($count - $total))
    if ($got -le 0) { break }
    $total += $got
  }
  if ($total -lt $count) {
    $short = New-Object byte[] $total
    [System.Array]::Copy($buffer, $short, $total)
    $buffer = $short
  }
  return , $buffer
}

function Test-ReparsePoint([string]$path) {
  return ([System.IO.File]::GetAttributes($path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
}

# 目录收到当前用户和 SYSTEM（照 packages/world-capture-host 的 private-directory.mjs），子目录和文件继承。
function New-PrivateRoot([string]$dir) {
  if ([System.IO.Directory]::Exists($dir)) { if (Test-ReparsePoint $dir) { throw 'state directory is a reparse point' } }
  else { [void][System.IO.Directory]::CreateDirectory($dir) }
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $icacls $dir '/inheritancelevel:r' '/grant:r' ('*' + $sid + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' > $null 2> $null }
  finally { $ErrorActionPreference = $previous }
}

function New-Directory([string]$dir) { if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) } }

# 写临时文件再改名。$replace 为假时目标已存在就不动它（队列文件：同名即同一条目，首见时刻以先写的为准）。
function Write-Atomic([string]$path, [string]$text, [string]$tmpDir, [bool]$replace) {
  $tmp = Join-Path $tmpDir ([guid]::NewGuid().ToString('N'))
  [System.IO.File]::WriteAllText($tmp, $text, $script:Utf8)
  try {
    if ([System.IO.File]::Exists($path)) {
      if ($replace) { [System.IO.File]::Delete($path); [System.IO.File]::Move($tmp, $path) }
    }
    else { [System.IO.File]::Move($tmp, $path) }
  }
  finally { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } }
}

function Test-NonNegativeInteger($v) {
  if (($v -is [int]) -or ($v -is [long])) { return $v -ge 0 }
  if ($v -is [decimal]) { return ($v -ge 0) -and ([decimal]::Truncate($v) -eq $v) }
  return $false
}

function Get-Bool($d, [string]$key) { $v = Get-Field $d $key; return ($v -is [bool]) -and $v }

# config.json 里这种 Agent 的那一项；合用时返回 source_id、历史起点（UTC）和确认过的文件夹（只读它下面的会话）。
function Get-ConfigEntry([string]$text, [string]$agent, [string]$format) {
  try { $config = $script:Json.DeserializeObject($text) } catch { return $null }
  return Get-ConfigEntryOf $config $agent $format
}

function Test-RootedPath($v) {
  return ($v -is [string]) -and ($v -cmatch '\A(?:[A-Za-z]:[\\/]|\\\\)') -and -not ($v -match '[\x00-\x1f]')
}

function Get-ConfigEntryOf($config, [string]$agent, [string]$format) {
  $e = Get-Field (Get-Field $config 'agents') $agent
  if (-not ($e -is [System.Collections.IDictionary])) { return $null }
  if (-not (Test-Is (Get-Field $e 'format') $format)) { return $null }
  $from = ConvertTo-Utc (Get-Field $e 'history_from')
  if ($null -eq $from) { return $null }
  $selection = Get-Field $e 'selection_id'
  if (-not (($selection -is [string]) -and ($selection -cmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'))) { return $null }
  $version = Get-Field $e 'selection_version'
  if (-not ((Test-NonNegativeInteger $version) -and ($version -ge 1))) { return $null }
  $source = Get-Field $e 'source_id'
  if (-not (($source -is [string]) -and ($source -cmatch '\A[A-Za-z0-9][A-Za-z0-9._:/@+~-]{0,199}\z'))) { return $null }
  $folder = Get-Field $e 'folder'
  if (-not (Test-RootedPath $folder)) { return $null }
  return @{ source_id = $source; start = $from; folder = $folder }
}

# 这个会话文件读不读：确认过的文件夹下面的 .jsonl，本身不是重解析点；规范化后（.. 已消掉）在文件夹里，
# 从文件夹往下到它所在目录的每一层都不是重解析点（同 sh 版按实际所在目录比）。
function Test-Transcript([string]$path, [string]$folder) {
  if (-not ($path -cmatch '\A(?:[A-Za-z]:[\\/]|\\\\)')) { return $false }
  if (-not $path.EndsWith('.jsonl', $script:Ordinal)) { return $false }
  if (-not [System.IO.File]::Exists($path)) { return $false }
  if (Test-ReparsePoint $path) { return $false }
  try {
    $full = [System.IO.Path]::GetFullPath($path)
    $root = [System.IO.Path]::GetFullPath($folder).TrimEnd([char[]]@([char]92, [char]47))
  }
  catch { return $false }
  if (-not $full.StartsWith($root + [string][char]92, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  $dir = [System.IO.Path]::GetDirectoryName($full)
  while ($dir.Length -gt $root.Length) {
    if (Test-ReparsePoint $dir) { return $false }
    $dir = [System.IO.Path]::GetDirectoryName($dir)
  }
  return $true
}

# 上次的位置文件；合用时返回它。
function Read-Position([string]$file, [string]$format, [string]$path) {
  if (-not [System.IO.File]::Exists($file)) { return $null }
  try { $p = $script:Json.DeserializeObject((Read-SharedText $file)) } catch { return $null }
  if (-not ($p -is [System.Collections.IDictionary])) { return $null }
  if ((-not (Test-Is (Get-Field $p 'format') $format)) -or (-not (Test-Is (Get-Field $p 'path') $path))) { return $null }
  foreach ($k in @('offset', 'head_bytes', 'lines')) { if (-not (Test-NonNegativeInteger (Get-Field $p $k))) { return $null } }
  $h = Get-Field $p 'head_sha256'
  if (-not (($h -is [string]) -and ($h -cmatch '\A[0-9a-f]{64}\z'))) { return $null }
  if (-not ((Get-Field $p 'state') -is [System.Collections.IDictionary])) { return $null }
  return $p
}

function Get-InitialState([string]$format, $previous) {
  $s = Get-Field $previous 'state'
  if ($format -ceq 'claude-session-jsonl/1') {
    return @{ recognized = (Get-Bool $s 'recognized'); daily = (Get-Bool $s 'daily') }
  }
  $session = Get-Field $s 'session'
  if (-not ($session -is [string])) { $session = $null }
  $up = Get-Field $s 'up'; if (-not (Test-Number $up)) { $up = -1 }
  $ap = Get-Field $s 'ap'; if (-not (Test-Number $ap)) { $ap = -1 }
  return @{ session = $session; subagent = (Get-Bool $s 'subagent'); up = [int]$up; ap = [int]$ap; daily = (Get-Bool $s 'daily') }
}

function Get-Now { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Invariant) }

# ---------- 读一段增量、入队 ----------

function Invoke-Worker([string]$agent, [string]$hookEvent, [string]$format, [string]$stateDir, [string]$path) {
  $configPath = Join-Path $stateDir 'config.json'
  if (-not [System.IO.File]::Exists($configPath)) { return }
  $entry = Get-ConfigEntry (Read-SharedText $configPath) $agent $format
  if ($null -eq $entry) { return }
  if (-not (Test-Transcript $path $entry.folder)) { return }
  $state = Initialize-State $stateDir $format
  try {
    Read-Increment $format $entry $path $state.transcripts $state.queue $state.work $stateDir
    Write-Decision $agent $hookEvent $format $state.queue $state.work $stateDir
  }
  finally { try { [System.IO.Directory]::Delete($state.work, $true) } catch { } }
}

# 本机状态目录和这一次运行的临时目录。
function Initialize-State([string]$stateDir, [string]$format) {
  New-PrivateRoot $stateDir
  $transcripts = Join-Path $stateDir 'transcripts'
  $tmpRoot = Join-Path $stateDir 'tmp'
  $queue = Join-Path (Join-Path $stateDir 'queue') ($format.Replace('/', '\'))
  New-Directory $transcripts
  New-Directory $tmpRoot
  New-Directory $queue
  foreach ($old in [System.IO.Directory]::GetDirectories($tmpRoot)) {
    try { if ([System.IO.Directory]::GetLastWriteTimeUtc($old) -lt [DateTime]::UtcNow.AddDays(-1)) { [System.IO.Directory]::Delete($old, $true) } } catch { }
  }
  $work = Join-Path $tmpRoot ('run.' + [guid]::NewGuid().ToString('N'))
  [void][System.IO.Directory]::CreateDirectory($work)
  return @{ transcripts = $transcripts; queue = $queue; work = $work }
}

function Read-Increment([string]$format, $entry, [string]$path, [string]$transcripts, [string]$queue, [string]$work, [string]$stateDir) {
  $key = Get-TextSha256 $path
  $positionPath = Join-Path $transcripts ($key + '.json')
  $fs = Open-Shared $path
  try {
    $size = [long]$fs.Length
    $mtime = [long](New-Object System.DateTimeOffset([System.IO.File]::GetLastWriteTimeUtc($path))).ToUnixTimeSeconds()
    $offset = [long]0; $lines = [long]0; $previous = $null
    $known = Read-Position $positionPath $format $path
    if ($null -ne $known) {
      # 文件变小，或开头那一段的摘要变了：当作被改写，从头读。
      $knownOffset = [long](Get-Field $known 'offset')
      $knownHead = [long](Get-Field $known 'head_bytes')
      if (($size -ge $knownOffset) -and ((Get-Sha256Hex (Read-Bytes $fs 0 $knownHead)) -ceq (Get-Field $known 'head_sha256'))) {
        $offset = $knownOffset; $lines = [long](Get-Field $known 'lines'); $previous = $known
      }
    }
    if ($size -le $offset) { return }
    $chunk = Read-Bytes $fs $offset ($size - $offset)
    $last = [System.Array]::LastIndexOf($chunk, [byte]10)
    if ($last -lt 0) { return }
    $complete = $last + 1

    $script:St = Get-InitialState $format $previous
    $script:Pending = $null
    $script:Out = New-Object System.Collections.Generic.List[object]
    $script:Msgs = New-Object System.Collections.Generic.List[object]
    $script:Issues = @{}
    $n = $lines
    $start = 0
    while ($start -lt $complete) {
      $end = [System.Array]::IndexOf($chunk, [byte]10, $start)
      $n += 1
      $length = $end - $start
      $lineStart = $start
      $start = $end + 1
      if ($length -eq 0) { continue }
      try { $s = $script:StrictUtf8.GetString($chunk, $lineStart, $length) } catch { Add-Issue 'parse_failed'; continue }
      # TextDecoder 每行去掉开头一个 BOM；JSON.parse 不认第二个。
      if (($s.Length -gt 0) -and ([int]$s[0] -eq 0xFEFF)) { $s = $s.Substring(1) }
      if (($s.Length -gt 0) -and ([int]$s[0] -eq 0xFEFF)) { Add-Issue 'parse_failed'; continue }
      # JSON.parse 不收的原始控制字符，JavaScriptSerializer 会收。
      if ($script:Control.IsMatch($s)) { Add-Issue 'parse_failed'; continue }
      # 同 capture.jq 的 fix_lone：孤立代理项的 \u 转义换成 U+10FFFF，并给这一行记上标记。
      $script:LineLone = $script:LoneEscape.IsMatch($s)
      if ($script:LineLone) { $s = $script:LoneEscape.Replace($s, $script:LoneEscapeEvaluator) }
      try { $row = $script:Json.DeserializeObject($s) } catch { Add-Issue 'parse_failed'; continue }
      if (-not ($row -is [System.Collections.IDictionary])) { Add-Issue 'parse_failed'; continue }
      if ($format -ceq 'claude-session-jsonl/1') { Step-Claude $row $n } else { Step-Codex $row $n }
    }
    if ($format -ceq 'claude-session-jsonl/1') { $recognized = Complete-Claude } else { $recognized = Complete-Codex }
    # 认不出是这种格式：不前进，下次从同一处再读。
    if (-not $recognized) { return }

    # 与 index.mjs 相同的筛选：原文不合法的整份文件不交（这里只丢这一条），没有可用时刻的是覆盖缺口，早于历史起点的丢掉。
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($e in $script:Out) {
      $at = ConvertTo-Utc $e.raw
      if ((-not (Test-WellFormed $e.text)) -or ($e.lone -and $e.text.Contains($script:NonCharacter))) { Add-Issue 'text_not_well_formed' }
      elseif ($null -eq $at) { Add-Issue 'time_unknown' }
      elseif (Test-Before $at $entry.start) { }
      else {
        $item = 'entry-' + (Get-TextSha256 ($format + ':' + $e.id))
        $version = Get-TextSha256 ('[' + (ConvertTo-JsString $e.role) + ',' + (ConvertTo-JsString $e.text) + ',' + (ConvertTo-JsString $e.raw) + ']')
        $entries.Add([ordered]@{ item_id = $item; item_version = $version; locator = 'local-capture:' + $entry.source_id + '/' + $item + '@' + $version;
            role = $e.role; reported_at = $at; text = $e.text })
      }
    }

    $newOffset = $offset + $complete
    $headBytes = [math]::Min([long]4096, $newOffset)
    $headSha = Get-Sha256Hex (Read-Bytes $fs 0 $headBytes)
  }
  finally { $fs.Dispose() }

  # 先列队列、再读已送出：后台轮是先记已送出、再删队列文件，这个顺序下刚送出的条目不会被重新排进来。
  $queued = @{}
  foreach ($f in [System.IO.Directory]::GetFiles($queue, 'entry-*.json')) { $queued[[System.IO.Path]::GetFileName($f)] = $true }
  $done = @{}
  $deliveredPath = Join-Path (Join-Path $stateDir 'delivered') ($format.Replace('/', '\') + '.jsonl')
  if ([System.IO.File]::Exists($deliveredPath)) {
    foreach ($text in (Read-SharedText $deliveredPath).Split([char]10)) {
      try { $d = $script:Json.DeserializeObject($text) } catch { continue }
      if ($d -is [System.Collections.IDictionary]) { $done[(ConvertTo-JsTemplate (Get-Field $d 'item_id')) + '@' + (ConvertTo-JsTemplate (Get-Field $d 'item_version')) + '.json'] = $true }
    }
  }
  $now = Get-Now
  # 先把条目放进队列，再写位置：中途断了，下次从旧位置重读，同名条目不会重复。
  foreach ($e in $entries) {
    $name = $e.item_id + '@' + $e.item_version + '.json'
    if ($queued.ContainsKey($name) -or $done.ContainsKey($name)) { continue }
    $queued[$name] = $true
    $e['first_seen_at'] = $now
    try { Write-Atomic (Join-Path $queue $name) (ConvertTo-JsJson $e) $work $false } catch { }
  }

  $issues = [ordered]@{}
  $oldIssues = Get-Field $previous 'issues'
  if ($oldIssues -is [System.Collections.IDictionary]) {
    foreach ($k in $oldIssues.Keys) { if (Test-Number $oldIssues[$k]) { $issues[[string]$k] = [long]$oldIssues[$k] } }
  }
  foreach ($k in $script:Issues.Keys) { $issues[[string]$k] = [long]$issues[[string]$k] + $script:Issues[$k] }
  $position = [ordered]@{ path = $path; format = $format; offset = $newOffset; size = $size; mtime = $mtime; head_bytes = $headBytes;
    head_sha256 = $headSha; lines = $n; state = $script:St; issues = $issues; updated_at = $now }
  Write-Atomic $positionPath (ConvertTo-JsJson $position) $work $true
}

# World Capture 组件的私有目录（Electron 的 userData 下的 capture\）。迁移只读它；它在采集时这里有 agent-channel.json。
function Get-ComponentDir {
  if (-not $env:APPDATA) { return $null }
  return Join-Path (Join-Path ([string]$env:APPDATA) 'World Capture') 'capture'
}

function Test-Exists([string]$path) { return [System.IO.File]::Exists($path) -or [System.IO.Directory]::Exists($path) }

function Test-ComponentCapturing {
  $dir = Get-ComponentDir
  return ($null -ne $dir) -and (Test-Exists (Join-Path $dir 'agent-channel.json'))
}

# 后台轮不起的原因写进 paused.json（首次和最近一次碰到的时刻）；原因不在了，下一次钩子删掉它。
function Write-Paused([string]$file, [string]$reason, [string]$work) {
  $now = Get-Now
  $first = $now
  if ([System.IO.File]::Exists($file)) {
    try { $m = [regex]::Match((Read-SharedText $file), '"first_seen_at":"([0-9TZ:-]*)"'); if ($m.Success) { $first = $m.Groups[1].Value } } catch { }
  }
  Write-Atomic $file (ConvertTo-JsJson ([ordered]@{ reason = $reason; first_seen_at = $first; last_seen_at = $now })) $work $true
}

# 起轮决定：队列规则（最早入队的一条等了 30 分钟以上，或会话结束；队列空时不起）加上组件、间隔与锁。
# 设了 TKOS_CAPTURE_DECISION_FILE 时把决定写出来，供测试核对。
function Write-Decision([string]$agent, [string]$hookEvent, [string]$format, [string]$queue, [string]$work, [string]$stateDir) {
  $target = $env:TKOS_CAPTURE_DECISION_FILE
  $seen = New-Object System.Collections.Generic.List[string]
  foreach ($f in [System.IO.Directory]::GetFiles($queue, 'entry-*.json')) {
    try { $m = [regex]::Match((Read-SharedText $f), '"first_seen_at":"([^"]*)"') } catch { continue }
    if ($m.Success) { $seen.Add($m.Groups[1].Value) }
  }
  $oldest = $null
  foreach ($t in $seen) { if (($null -eq $oldest) -or ([string]::CompareOrdinal($t, $oldest) -lt 0)) { $oldest = $t } }
  $reason = $null
  if ($seen.Count -gt 0) {
    if ($hookEvent -ceq 'SessionEnd') { $reason = 'session_end' }
    else {
      $since = [DateTime]::MinValue
      $styles = [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal'
      if ([DateTime]::TryParseExact($oldest, "yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Invariant, $styles, [ref]$since)) {
        if (([DateTime]::UtcNow - $since).TotalSeconds -ge 1800) { $reason = 'waited' }
      }
    }
  }
  $decision = [ordered]@{ agent = $agent; event = $hookEvent; format = $format; due = ($null -ne $reason); reason = $reason;
    queued = $seen.Count; oldest_first_seen_at = $oldest; decided_at = (Get-Now) }
  $gate = Get-Gate (Join-Path $stateDir 'rounds') $format
  $lock = Join-Path $stateDir 'round.lock'
  $locked = [System.IO.Directory]::Exists($lock) -and -not (Test-LockStale $lock)
  # World Capture 组件正在采集（它的 agent-channel.json 在）时不起后台轮：同一时间只有一方送。原因记进 paused.json。
  $capturing = Test-ComponentCapturing
  $pausedFile = Join-Path $stateDir 'paused.json'
  if ($capturing) { Write-Paused $pausedFile 'component_capturing' $work }
  elseif ([System.IO.File]::Exists($pausedFile)) { [System.IO.File]::Delete($pausedFile) }
  $blocked = $null
  if ($decision.due) { if ($capturing) { $blocked = 'component_capturing' } elseif ($locked) { $blocked = 'round_running' } elseif ($gate.too_soon) { $blocked = 'too_soon' } }
  $decision['run'] = $decision.due -and ($null -eq $blocked)
  $decision['blocked'] = $blocked
  $decision['failures'] = $gate.failures
  $decision['next_round_at'] = $gate.next_round_at
  if ($target) { Write-Atomic $target (ConvertTo-JsJson $decision) $work $true }
  if ($decision.run) { Invoke-Round $agent $format $stateDir $queue $work $reason }
}

# ---------- 后台轮（ADR 决定三、九）：判断、落盘、送出、回执 ----------
# 与 capture.sh 加 round.jq 同一套规则。一轮里每次模型调用是一次单独的 claude -p 或 codex exec：判断那次只有两个只读工具，
# 交回的判断由这里核对、落盘；送出那次只有送出和读回两个工具，参数是这里算好的骨架加上已落盘的判断；最后一次只报运行回执。

function Initialize-Round {
  # 后台轮的 world 连接：服务名 world 和地址要与 world 插件的 mcp.json 逐字一致，令牌按这两样找。
  $script:WorldUrl = 'https://world.tokenkingos.com/app/mcp'
  $script:ClaudePrefix = 'mcp__plugin_world_world__'
  $script:RoundTools = @{ judge = @('world_app_sources_read', 'world_app_sources_targets');
    send = @('world_app_sources_ingest', 'world_app_sources_imports'); report = @('world_app_sources_report_run') }
  # 一轮最多 5 批、每批 20 条；每条原文最多交 8000 字，一批合计最多 60000 字；每份骨架最多 50 条、一轮最多 5 份。
  # 读回导入每页 10 条：一页太大时 Claude Code 只给模型看一句「已存到文件」（约 50 KB 起，实测），模型看不到 next_cursor。
  $script:Limits = @{ batches = 5; batch = 20; item_chars = 8000; batch_chars = 60000; increment = 50; increments = 5; readback_pages = 20; readback_page = 10; pending = 200 }
  $script:ItemFields = @('classification', 'target_ref', 'field_key', 'value', 'quote', 'occurred_at', 'links', 'source_event_ref', 'constraint')
  # 一轮的硬时限（秒）。各次调用的时限按它的比例算，锁比它再老 LockMargin 秒就当持锁的进程已不在。
  $script:RoundLimit = 1200
  $limitText = [string]$env:TKOS_CAPTURE_ROUND_LIMIT
  if ($limitText -cmatch '\A[0-9]+\z') { $script:RoundLimit = [int]$limitText }
  $script:LockMargin = 600
  $script:Held = $null
  $script:Child = $null
}

# 带 null 的 JSON 字段：JavaScriptSerializer 把 null 存成键在、值为 $null。
function Test-NullField($obj, [string]$key) { return (Test-HasKey $obj $key) -and ($null -eq $obj[$key]) }

function ConvertFrom-JsText([string]$text) { return $script:Json.DeserializeObject($text) }

# 字段是数组时交出它（不让管道拆开），否则是空数组。不要写 @(Get-Field ...)：那会把整个数组再包一层。
function Get-List($obj, [string]$key) {
  $v = Get-Field $obj $key
  if ($v -is [System.Collections.IList]) { return , $v }
  return , @()
}

# 时限按一轮硬时限的比例取整（同 sh 的整数除法）。
function Get-Share([int]$num, [int]$den) { return [int][math]::Floor($script:RoundLimit * $num / $den) }

# 键按序号排好的 JSON，用来比两份参数是否相同（模型交回的参数键序可能不同）。
function ConvertTo-Canonical($v) {
  if ($v -is [System.Collections.IDictionary]) {
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($k in $v.Keys) { $keys.Add([string]$k) }
    $sorted = $keys.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $sorted) { $parts.Add((ConvertTo-JsString $k) + ':' + (ConvertTo-Canonical $v[$k])) }
    return '{' + ($parts -join ',') + '}'
  }
  if (($v -is [System.Collections.IEnumerable]) -and -not ($v -is [string])) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($x in $v) { $parts.Add((ConvertTo-Canonical $x)) }
    return '[' + ($parts -join ',') + ']'
  }
  return ConvertTo-JsJson $v
}

function Test-SameJson($a, $b) { return (ConvertTo-Canonical $a) -ceq (ConvertTo-Canonical $b) }

# 码点数（jq 与服务端都按码点算长度）。
function Get-CodePointLength([string]$s) {
  $n = $s.Length
  for ($i = 0; $i -lt $s.Length - 1; $i++) { if ([char]::IsSurrogatePair($s[$i], $s[$i + 1])) { $n--; $i++ } }
  return $n
}

function Get-CodePoints([string]$s) {
  $list = New-Object System.Collections.Generic.List[string]
  $i = 0
  while ($i -lt $s.Length) {
    if (($i -lt $s.Length - 1) -and [char]::IsSurrogatePair($s[$i], $s[$i + 1])) { $list.Add($s.Substring($i, 2)); $i += 2 }
    else { $list.Add($s.Substring($i, 1)); $i++ }
  }
  return , $list
}

function Get-Name($e) { return (ConvertTo-JsTemplate (Get-Field $e 'item_id')) + '@' + (ConvertTo-JsTemplate (Get-Field $e 'item_version')) }

function Format-Template([string]$template, $values) {
  foreach ($k in $values.Keys) { $template = $template.Replace('{{' + $k + '}}', [string]$values[$k]) }
  return $template
}

# round-prompt.md 里 <!-- 段名 --> 之后、下一个标记之前的一段。
function Get-PromptSection([string]$text, [string]$kind) {
  $marker = '<!-- ' + $kind + ' -->'
  $at = $text.IndexOf($marker, $script:Ordinal)
  if ($at -lt 0) { return '' }
  $rest = $text.Substring($at + $marker.Length)
  $end = $rest.IndexOf("`n<!-- ", $script:Ordinal)
  if ($end -ge 0) { $rest = $rest.Substring(0, $end) }
  return $rest.Trim()
}

function Get-RoundPrompts { return (Read-SharedText (Join-Path (Split-Path -Parent $script:Self) 'round-prompt.md')).Replace("`r`n", "`n") }

# world-source-extract 技能里 rules-from 那一段列出的各节，按技能里的顺序原样交给判断轮。
function Get-SkillRules([string]$skill, [string]$names) {
  $wanted = @($names.Split([char]10) | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
  $kept = New-Object System.Collections.Generic.List[string]
  foreach ($part in $skill.Replace("`r`n", "`n").Split(@("`n## "), [System.StringSplitOptions]::None)) {
    foreach ($n in $wanted) { if ($part.StartsWith($n + "`n", $script:Ordinal)) { $kept.Add('## ' + $part); break } }
  }
  if ($kept.Count -ne $wanted.Count) { return $null }
  return ($kept -join "`n").TrimEnd()
}

function Get-CodeBlock($v) { return '```json' + "`n" + (ConvertTo-JsJson $v) + "`n" + '```' }

# ---------- 计划：这一轮要做的事（同 round.jq 的 plan） ----------

function Get-DeliveredSet([string]$text) {
  $done = @{}
  foreach ($line in $text.Split([char]10)) {
    try { $d = ConvertFrom-JsText $line } catch { continue }
    if ($d -is [System.Collections.IDictionary]) { $done[(Get-Name $d)] = $true }
  }
  return $done
}

function Get-Clipped($entry, [string]$omitted) {
  $text = [string]$entry.text
  $length = Get-CodePointLength $text
  if ($length -le $script:Limits.item_chars) { return $entry }
  $points = Get-CodePoints $text
  $head = ($points.GetRange(0, 6000) -join '')
  $tail = ($points.GetRange($points.Count - 2000, 2000) -join '')
  $entry['text'] = $head + "`n" + (Format-Template $omitted ([ordered]@{ n = ($length - 8000).ToString($script:Invariant) })) + "`n" + $tail
  $entry['truncated'] = $length
  return $entry
}

function Get-Plan([string]$queueDir, [string]$resultsDir, [string]$deliveredPath, [string]$format, [string]$omitted) {
  $done = @{}
  if ([System.IO.File]::Exists($deliveredPath)) { $done = Get-DeliveredSet (Read-SharedText $deliveredPath) }
  $stored = @{}
  if ([System.IO.Directory]::Exists($resultsDir)) {
    foreach ($f in [System.IO.Directory]::GetFiles($resultsDir, 'entry-*.json')) {
      try { $v = ConvertFrom-JsText (Read-SharedText $f) } catch { continue }
      if (($v -is [System.Collections.IDictionary]) -and (Test-Is (Get-Field $v 'format') $format)) {
        $stored[[System.IO.Path]::GetFileNameWithoutExtension($f)] = $v
      }
    }
  }
  $open = New-Object System.Collections.Generic.List[object]
  $stale = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  foreach ($f in [System.IO.Directory]::GetFiles($queueDir, 'entry-*.json')) {
    try { $e = ConvertFrom-JsText (Read-SharedText $f) } catch { continue }
    if (-not (($e -is [System.Collections.IDictionary]) -and ((Get-Field $e 'item_id') -is [string]))) { continue }
    $name = Get-Name $e
    if ($done.ContainsKey($name)) { $stale.Add($name); continue }
    if ($seen.ContainsKey($name)) { continue }
    $seen[$name] = $true
    $e['name'] = $name
    $open.Add($e)
  }
  # 同 jq 的 sort_by：按码点比，不按区域设置。
  $sorted = $open.ToArray()
  $keys = New-Object string[] $sorted.Length
  for ($i = 0; $i -lt $sorted.Length; $i++) {
    $keys[$i] = [string]$sorted[$i]['first_seen_at'] + [char]0 + [string]$sorted[$i]['reported_at'] + [char]0 + [string]$sorted[$i]['item_id']
  }
  [System.Array]::Sort($keys, $sorted, [System.StringComparer]::Ordinal)
  foreach ($name in $stored.Keys) { if (-not $seen.ContainsKey($name)) { $stale.Add($name) } }
  $plan = @{ backlog = $sorted.Count; pending = (New-Object System.Collections.Generic.List[object]);
    settle = (New-Object System.Collections.Generic.List[object]); judge = (New-Object System.Collections.Generic.List[object]);
    send = (New-Object System.Collections.Generic.List[object]); readback = (New-Object System.Collections.Generic.List[object]);
    stale = $stale }
  $judgeRows = New-Object System.Collections.Generic.List[object]
  $sendRows = New-Object System.Collections.Generic.List[object]
  foreach ($e in $sorted) {
    $plan.pending.Add([ordered]@{ item_id = $e['item_id']; item_version = $e['item_version'] })
    $s = $stored[$e['name']]
    $row = [ordered]@{ name = $e['name']; item_id = $e['item_id']; item_version = $e['item_version'] }
    if (($null -ne $s) -and (Test-HasKey $s 'result') -and ($null -eq $s['result'])) {
      $row['dropped'] = Get-Field $s 'dropped'
      $plan.settle.Add($row)
    }
    elseif (($null -eq $s) -or -not (Test-HasKey $s 'result')) {
      $row['role'] = $e['role']; $row['reported_at'] = $e['reported_at']; $row['text'] = $e['text']
      $rejected = Get-Field $s 'rejected'
      if (($rejected -is [System.Collections.IList]) -and ($rejected.Count -gt 0)) {
        $row['rejected'] = Get-Field $rejected[$rejected.Count - 1] 'code'
        $attempt = Get-Field $s 'attempt'
        if ($null -eq $attempt) { $attempt = 1 }
        $row['attempt'] = $attempt
      }
      $judgeRows.Add((Get-Clipped $row $omitted))
    }
    elseif (Test-Truthy (Get-Field $s 'conflict')) {
      $row['stored'] = $s
      $plan.readback.Add($row)
    }
    elseif ($sendRows.Count -lt ($script:Limits.increment * $script:Limits.increments)) {
      $row['locator'] = $e['locator']; $row['reported_at'] = $e['reported_at']; $row['result'] = $s['result']; $row['stored'] = $s
      $sendRows.Add($row)
    }
  }
  $current = New-Object System.Collections.Generic.List[object]
  $chars = 0
  foreach ($row in $judgeRows) {
    if ($plan.judge.Count -ge $script:Limits.batches) { break }
    $length = Get-CodePointLength ([string]$row['text'])
    if (($current.Count -gt 0) -and (($current.Count -ge $script:Limits.batch) -or ($chars + $length -gt $script:Limits.batch_chars))) {
      $plan.judge.Add($current); $current = New-Object System.Collections.Generic.List[object]; $chars = 0
    }
    $current.Add($row); $chars += $length
  }
  if (($current.Count -gt 0) -and ($plan.judge.Count -lt $script:Limits.batches)) { $plan.judge.Add($current) }
  for ($i = 0; $i -lt $sendRows.Count; $i += $script:Limits.increment) {
    $plan.send.Add($sendRows.GetRange($i, [math]::Min($script:Limits.increment, $sendRows.Count - $i)))
  }
  return $plan
}

# ---------- 提示词 ----------

function Get-Since($batch) {
  $min = $null
  foreach ($e in $batch) {
    $t = [DateTime]::ParseExact(([string]$e['reported_at']).Substring(0, 19), "yyyy-MM-dd'T'HH:mm:ss", $script:Invariant,
      [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
    if (($null -eq $min) -or ($t -lt $min)) { $min = $t }
  }
  return $min.AddDays(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Invariant)
}

function Get-JudgePrompt([string]$prompts, [string]$rules, $cfg, $batch) {
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($e in $batch) {
    $item = [ordered]@{}
    foreach ($k in $e.Keys) { if (@('name', 'attempt') -notcontains $k) { $item[$k] = $e[$k] } }
    $items.Add($item)
  }
  $data = [ordered]@{ selection_id = $cfg.selection_id; selection_version = $cfg.selection_version; since = (Get-Since $batch); items = $items }
  return (Format-Template (Get-PromptSection $prompts 'judge') ([ordered]@{ rules = $rules; batch = (Get-CodeBlock $data) })) + "`n"
}

function Get-SendPrompt([string]$prompts, $cfg, $increments, $readback) {
  $steps = New-Object System.Collections.Generic.List[string]
  if ($readback.Count -gt 0) {
    $steps.Add((Format-Template (Get-PromptSection $prompts 'send-readback') ([ordered]@{
      pages = $script:Limits.readback_pages.ToString($script:Invariant);
      args = (Get-CodeBlock ([ordered]@{ selection_id = $cfg.selection_id; limit = $script:Limits.readback_page })) })))
  }
  foreach ($inc in $increments) { $steps.Add((Format-Template (Get-PromptSection $prompts 'send-ingest') ([ordered]@{ args = (Get-CodeBlock $inc) }))) }
  $numbered = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $steps.Count; $i++) { $numbered.Add(($i + 1).ToString($script:Invariant) + '. ' + $steps[$i]) }
  return (Format-Template (Get-PromptSection $prompts 'send') ([ordered]@{ steps = ($numbered -join "`n`n") })) + "`n"
}

function Get-ReportPrompt([string]$prompts, $reportArgs) {
  return (Format-Template (Get-PromptSection $prompts 'report') ([ordered]@{ args = (Get-CodeBlock $reportArgs) })) + "`n"
}

# ---------- 两种 CLI 的输出 ----------

function Get-FirstText($content) {
  if ($content -is [string]) { return $content }
  if ($content -is [System.Collections.IList]) {
    foreach ($block in $content) { if ((Test-Is (Get-Field $block 'type') 'text') -and ((Get-Field $block 'text') -is [string])) { return $block['text'] } }
  }
  return $null
}

function Read-Lines([string]$text) {
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($line in $text.Split([char]10)) {
    if ($line.Trim().Length -eq 0) { continue }
    try { $rows.Add((ConvertFrom-JsText $line)) } catch { }
  }
  return , $rows
}

function Add-Usage($total, $inTokens, $cachedTokens, $outTokens) {
  return [ordered]@{ input_tokens = [long]$total.input_tokens + $inTokens; cached_input_tokens = [long]$total.cached_input_tokens + $cachedTokens;
    output_tokens = [long]$total.output_tokens + $outTokens }
}

# claude -p --output-format stream-json --verbose 的每一行。init 里有 world 连接的状态，result 里有用量与最终答复。
function Read-ClaudeStream($rows) {
  $parsed = @{ events = $rows.Count; mcp = $null; calls = (New-Object System.Collections.Generic.List[object]); final = $null;
    errors = (New-Object System.Collections.Generic.List[string]); api_status = $null; usage = $null }
  $outs = @{}
  $uses = New-Object System.Collections.Generic.List[object]
  $init = $null; $result = $null
  foreach ($r in $rows) {
    if (-not ($r -is [System.Collections.IDictionary])) { continue }
    $type = Get-Field $r 'type'
    if ((Test-Is $type 'system') -and (Test-Is (Get-Field $r 'subtype') 'init') -and ($null -eq $init)) { $init = $r }
    elseif (Test-Is $type 'result') { $result = $r }
    elseif ((Test-Is $type 'assistant') -or (Test-Is $type 'user')) {
      $content = Get-Field (Get-Field $r 'message') 'content'
      if (-not ($content -is [System.Collections.IList])) { continue }
      # 工具返回超过约 50 KB 时，content 里只剩一句「已存到文件」，完整的返回在这一行的 tool_use_result 里（实测）。
      $results = @($content | Where-Object { Test-Is (Get-Field $_ 'type') 'tool_result' })
      $full = Get-Field $r 'tool_use_result'
      foreach ($block in $content) {
        if ((Test-Is $type 'assistant') -and (Test-Is (Get-Field $block 'type') 'tool_use')) { $uses.Add($block) }
        if ((Test-Is $type 'user') -and (Test-Is (Get-Field $block 'type') 'tool_result')) {
          $out = @{ is_error = (Get-Field $block 'is_error'); content = (Get-Field $block 'content') }
          if (($results.Count -eq 1) -and ($null -ne $full)) { $out.content = $full }
          $outs[(ConvertTo-JsTemplate (Get-Field $block 'tool_use_id'))] = $out
        }
      }
    }
  }
  if ($null -ne $init) {
    $parsed.mcp = 'missing'
    foreach ($server in (Get-List $init 'mcp_servers')) { if (Test-Is (Get-Field $server 'name') 'plugin:world:world') { $parsed.mcp = Get-Field $server 'status' } }
  }
  foreach ($use in $uses) {
    $name = [string](Get-Field $use 'name')
    if (-not $name.StartsWith($script:ClaudePrefix, $script:Ordinal)) { continue }
    $out = $outs[(ConvertTo-JsTemplate (Get-Field $use 'id'))]
    $parsed.calls.Add(@{ tool = $name.Substring($script:ClaudePrefix.Length); args = (Get-Field $use 'input');
      text = (Get-FirstText (Get-Field $out 'content')); failed = (($null -eq $out) -or ((Get-Field $out 'is_error') -eq $true)) })
  }
  if ($null -ne $result) {
    if ((Get-Field $result 'result') -is [string]) { $parsed.final = $result['result'] }
    if ((Get-Field $result 'is_error') -eq $true) { $parsed.errors.Add([string](Get-Field $result 'result')) }
    $parsed.api_status = Get-Field $result 'api_error_status'
    $u = Get-Field $result 'usage'
    if ($u -is [System.Collections.IDictionary]) {
      $cached = [long](Get-Field $u 'cache_read_input_tokens')
      $parsed.usage = [ordered]@{ input_tokens = [long](Get-Field $u 'input_tokens') + [long](Get-Field $u 'cache_creation_input_tokens') + $cached;
        cached_input_tokens = $cached; output_tokens = [long](Get-Field $u 'output_tokens') }
    }
  }
  return $parsed
}

# codex exec --json 的每一行。world 连接设成 required，连不上时 codex 不起会话、只在标准错误里说。
function Read-CodexStream($rows) {
  $parsed = @{ events = $rows.Count; mcp = $null; calls = (New-Object System.Collections.Generic.List[object]); final = $null;
    errors = (New-Object System.Collections.Generic.List[string]); api_status = $null; usage = $null }
  foreach ($r in $rows) {
    if (-not ($r -is [System.Collections.IDictionary])) { continue }
    $type = Get-Field $r 'type'
    $item = Get-Field $r 'item'
    if ((Test-Is $type 'item.completed') -and (Test-Is (Get-Field $item 'type') 'mcp_tool_call') -and (Test-Is (Get-Field $item 'server') 'world')) {
      $parsed.calls.Add(@{ tool = (Get-Field $item 'tool'); args = (Get-Field $item 'arguments'); text = (Get-FirstText (Get-Field (Get-Field $item 'result') 'content'));
        failed = ((-not (Test-Is (Get-Field $item 'status') 'completed')) -or ($null -ne (Get-Field $item 'error'))) })
    }
    elseif ((Test-Is $type 'item.completed') -and (Test-Is (Get-Field $item 'type') 'agent_message')) { $parsed.final = Get-Field $item 'text' }
    elseif ((Test-Is $type 'item.completed') -and (Test-Is (Get-Field $item 'type') 'error')) { $parsed.errors.Add([string](Get-Field $item 'message')) }
    elseif (Test-Is $type 'error') { $parsed.errors.Add([string](Get-Field $r 'message')) }
    elseif (Test-Is $type 'turn.failed') { $parsed.errors.Add([string](Get-Field (Get-Field $r 'error') 'message')) }
    elseif (Test-Is $type 'turn.completed') {
      $u = Get-Field $r 'usage'
      if ($null -eq $parsed.usage) { $parsed.usage = [ordered]@{ input_tokens = 0; cached_input_tokens = 0; output_tokens = 0 } }
      $parsed.usage = Add-Usage $parsed.usage ([long](Get-Field $u 'input_tokens')) ([long](Get-Field $u 'cached_input_tokens')) ([long](Get-Field $u 'output_tokens'))
    }
  }
  return $parsed
}

function New-Failure([string]$class, [string]$detail) { return [ordered]@{ class = $class; detail = $detail } }

# 失败分五类（ADR 决定九）：找不到程序、账号或登录失效、world 工具不可用、网络、其他。
function Get-Failure($parsed, [string]$agent, [int]$status, [bool]$timedOut, [string]$stderr) {
  $text = ($parsed.errors -join "`n") + "`n" + $stderr
  if ($timedOut) { return New-Failure 'other' 'timeout' }
  if (($status -eq 126) -or ($status -eq 127)) { return New-Failure 'program_missing' ('exit ' + $status) }
  if (($agent -ceq 'claude') -and (($parsed.api_status -eq 401) -or ($parsed.api_status -eq 403))) { return New-Failure 'login_invalid' ('api ' + $parsed.api_status) }
  if ($text -cmatch 'required MCP servers failed to initialize') {
    if ($text -cmatch 'error sending request|dns error|[Cc]onnection refused|timed out|[Nn]etwork') { return New-Failure 'network' 'world' }
    return New-Failure 'world_unavailable' 'mcp_not_ready'
  }
  if ($text -cmatch '401 Unauthorized|403 Forbidden|[Ii]nvalid API key|/login|[Nn]ot logged in|log in again|refresh token|suspended|authentication_error') {
    return New-Failure 'login_invalid' 'auth'
  }
  if ($text -cmatch 'error sending request|stream disconnected|[Cc]onnection refused|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|Unable to connect|fetch failed|getaddrinfo') {
    return New-Failure 'network' 'model'
  }
  if ($parsed.events -eq 0) { return New-Failure 'other' 'output_unreadable' }
  if (($agent -ceq 'claude') -and -not (Test-Is $parsed.mcp 'connected')) { return New-Failure 'world_unavailable' ('mcp_' + (ConvertTo-JsTemplate $parsed.mcp)) }
  if ($status -ne 0) { return New-Failure 'other' ('exit ' + $status) }
  return $null
}

# ---------- 判断轮的结果 ----------

function Test-BoundedText($v, [int]$min, [int]$max) {
  if (-not ($v -is [string])) { return $false }
  $n = Get-CodePointLength $v
  return ($n -ge $min) -and ($n -le $max)
}

function Test-ValidItem($r) {
  if (-not ($r -is [System.Collections.IDictionary])) { return $false }
  foreach ($k in $r.Keys) { if ($script:ItemFields -cnotcontains [string]$k) { return $false } }
  if (@('fact', 'decision', 'suggestion', 'question', 'unknown') -cnotcontains [string](Get-Field $r 'classification')) { return $false }
  if (-not ((Get-Field $r 'classification') -is [string])) { return $false }
  $v = Get-Field $r 'target_ref'
  if (($null -ne $v) -and -not (($v -is [string]) -and ($v -cmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@[1-9][0-9]*\z'))) { return $false }
  $v = Get-Field $r 'field_key'
  if (($null -ne $v) -and -not (Test-BoundedText $v 1 300)) { return $false }
  $v = Get-Field $r 'value'
  if ($null -ne $v) {
    if ($v -is [System.Collections.IList]) {
      if ($v.Count -gt 50) { return $false }
      foreach ($x in $v) { if (-not (Test-BoundedText $x 0 2048)) { return $false } }
    }
    elseif (-not (Test-BoundedText $v 0 4000)) { return $false }
  }
  $v = Get-Field $r 'quote'
  if (($null -ne $v) -and -not (Test-BoundedText $v 1 2000)) { return $false }
  $v = Get-Field $r 'occurred_at'
  if (($null -ne $v) -and -not (($v -is [string]) -and ($v -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})\z'))) { return $false }
  $v = Get-Field $r 'links'
  if ($null -ne $v) {
    if (-not (($v -is [System.Collections.IList]) -and ($v.Count -le 20))) { return $false }
    foreach ($x in $v) { if (-not (Test-BoundedText $x 1 2048)) { return $false } }
  }
  $v = Get-Field $r 'source_event_ref'
  if (($null -ne $v) -and -not (($v -is [string]) -and ($v -cmatch '\Aevent:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'))) { return $false }
  $v = Get-Field $r 'constraint'
  if (($null -ne $v) -and (@('none', 'upstream_blocked', 'pending_contract_unverified') -cnotcontains [string]$v)) { return $false }
  return $true
}

function Get-ToolBody($parsed, [string]$tool) {
  $found = $null
  foreach ($c in $parsed.calls) {
    if ((Test-Is $c.tool $tool) -and -not $c.failed) { try { $found = ConvertFrom-JsText ([string]$c.text) } catch { } }
  }
  return $found
}

function Get-ToolError($parsed, [string]$tool) {
  $code = $null
  foreach ($c in $parsed.calls) {
    if (-not (Test-Is $c.tool $tool)) { continue }
    $b = $null
    try { $b = ConvertFrom-JsText ([string]$c.text) } catch { }
    $e = Get-Field (Get-Field $b 'error') 'code'
    if ($null -ne $e) { $code = $e } elseif ($c.failed) { $code = 'tool_failed' }
  }
  return $code
}

function Get-Answer($parsed) {
  $m = [regex]::Match([string]$parsed.final, '\{[\s\S]*\}')
  if (-not $m.Success) { return $null }
  try { return ConvertFrom-JsText $m.Value } catch { return $null }
}

# 只认这一次调用里真的读到了生效的选择和非空的目标：world 连不上时模型照样会交一份全是 null 的结果，不能收。
function Get-JudgeOutcome($parsed, $batch, $cfg) {
  $outcome = @{ failure = $null; accepted = (New-Object System.Collections.Generic.List[object]); invalid = (New-Object System.Collections.Generic.List[object]);
    mismatches = (New-Object System.Collections.Generic.List[object]); unanswered = (New-Object System.Collections.Generic.List[string]) }
  $selection = Get-Field (Get-ToolBody $parsed 'world_app_sources_read') 'selection'
  $targets = Get-Field (Get-ToolBody $parsed 'world_app_sources_targets') 'targets'
  if (($null -eq $selection) -or -not ($targets -is [System.Collections.IList])) {
    $code = Get-ToolError $parsed 'world_app_sources_read'
    if ($null -eq $code) { $code = Get-ToolError $parsed 'world_app_sources_targets' }
    $class = 'world_unavailable'
    if (Test-Is $code 'HTTP_UNAVAILABLE') { $class = 'network' }
    if ($null -eq $code) { $code = 'tools_not_called' }
    $outcome.failure = New-Failure $class $code
    return $outcome
  }
  if (-not ((Test-Is (Get-Field $selection 'selection_id') $cfg.selection_id) -and (Test-Is (Get-Field $selection 'status') 'active') -and
      ((Get-Field $selection 'version') -eq $cfg.selection_version))) { $outcome.failure = New-Failure 'other' 'selection_changed'; return $outcome }
  if ($targets.Count -eq 0) { $outcome.failure = New-Failure 'other' 'targets_empty'; return $outcome }
  $answer = Get-Field (Get-Answer $parsed) 'results'
  if (-not ($answer -is [System.Collections.IList])) { $outcome.failure = New-Failure 'other' 'answer_unreadable'; return $outcome }
  $by = @{}
  foreach ($e in $batch) { $by[$e['name']] = $e }
  $seen = @{}
  foreach ($r in $answer) {
    $name = ''
    if ($r -is [System.Collections.IDictionary]) { $name = Get-Name $r }
    if (-not $by.ContainsKey($name)) {
      $outcome.mismatches.Add([ordered]@{ item_id = (Get-Field $r 'item_id'); item_version = (Get-Field $r 'item_version'); reason = 'not_in_batch' })
    }
    elseif ($seen.ContainsKey($name)) { $outcome.mismatches.Add([ordered]@{ item_id = $r['item_id']; item_version = $r['item_version']; reason = 'duplicate' }) }
    elseif (-not (Test-HasKey $r 'result')) {
      $outcome.mismatches.Add([ordered]@{ item_id = $r['item_id']; item_version = $r['item_version']; reason = 'no_result' }); $seen[$name] = $true
    }
    elseif ($null -eq $r['result']) { $outcome.accepted.Add(@{ row = $by[$name]; result = $null }); $seen[$name] = $true }
    elseif (Test-ValidItem $r['result']) {
      $clean = [ordered]@{}
      foreach ($k in $r['result'].Keys) { if ($null -ne $r['result'][$k]) { $clean[$k] = $r['result'][$k] } }
      $outcome.accepted.Add(@{ row = $by[$name]; result = $clean }); $seen[$name] = $true
    }
    else { $outcome.invalid.Add($by[$name]); $seen[$name] = $true }
  }
  foreach ($e in $batch) { if (-not $seen.ContainsKey($e['name'])) { $outcome.unanswered.Add($e['name']) } }
  return $outcome
}

# ---------- 送出 ----------

function Get-Increments($groups, $cfg, [string]$round) {
  $list = New-Object System.Collections.Generic.List[object]
  $k = 0
  foreach ($group in $groups) {
    $k++
    $ready = $null
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($row in $group) {
      if (($null -eq $ready) -or (Test-Before $ready ([string]$row['reported_at']))) { $ready = [string]$row['reported_at'] }
      $item = [ordered]@{ item_id = $row['item_id']; item_version = $row['item_version'] }
      foreach ($key in $row['result'].Keys) { $item[$key] = $row['result'][$key] }
      $item['locator'] = $row['locator']
      $items.Add($item)
    }
    $list.Add([ordered]@{ selection_id = $cfg.selection_id; selection_version = $cfg.selection_version;
      increment = [ordered]@{ format = 'world-source-increment/0.1'; source_id = $cfg.source_id; snapshot_version = ('queue-' + $round);
        batch_id = ('batch-' + $round + '-' + $k.ToString($script:Invariant)); source_ready_at = $ready; items = $items } })
  }
  return , $list
}

function Get-SentNames($c) {
  $names = New-Object System.Collections.Generic.List[string]
  $items = Get-Field (Get-Field $c.args 'increment') 'items'
  if ($items -is [System.Collections.IList]) { foreach ($i in $items) { if ($i -is [System.Collections.IDictionary]) { $names.Add((Get-Name $i)) } } }
  return , $names
}

# 每份骨架的结果。只认工具返回里的 imports（world 的回执），不认模型自己说的。参数和骨架不一致的也照回执记，另记 copy_mismatch。
function Get-SendOutcome($parsed, $increments) {
  $ingests = @($parsed.calls | Where-Object { Test-Is $_.tool 'world_app_sources_ingest' })
  $outcome = @{ increments = (New-Object System.Collections.Generic.List[object]); unknown = (New-Object System.Collections.Generic.List[object]);
    readback = @{ complete = $false; found = @{} } }
  $all = @{}
  for ($k = 0; $k -lt $increments.Count; $k++) {
    $inc = $increments[$k]
    $mine = New-Object System.Collections.Generic.List[string]
    foreach ($i in $inc.increment.items) { $mine.Add((Get-Name $i)); $all[(Get-Name $i)] = $true }
    $call = $null; $exact = $false
    foreach ($c in $ingests) { if (Test-SameJson $c.args $inc) { $call = $c; $exact = $true; break } }
    if ($null -eq $call) {
      foreach ($c in $ingests) { foreach ($n in (Get-SentNames $c)) { if ($mine.Contains($n)) { $call = $c } }; if ($null -ne $call) { break } }
    }
    $b = $null
    if ($null -ne $call) { try { $b = ConvertFrom-JsText ([string]$call.text) } catch { } }
    $imports = New-Object System.Collections.Generic.List[object]
    foreach ($v in (Get-List $b 'imports')) {
      if ($v -is [System.Collections.IDictionary]) {
        $imports.Add(@{ name = ((ConvertTo-JsTemplate $v['source_item_id']) + '@' + (ConvertTo-JsTemplate $v['source_version'])); import_id = $v['import_id'] })
      }
    }
    $rejected = New-Object System.Collections.Generic.List[object]
    foreach ($v in (Get-List (Get-Field $b 'error') 'rejected')) { if ($v -is [System.Collections.IDictionary]) { $rejected.Add(@{ name = (Get-Name $v); code = $v['code'] }) } }
    $code = Get-Field (Get-Field $b 'error') 'code'
    if (($null -eq $code) -and ($null -ne $call) -and ($null -eq $b)) { $code = 'tool_failed' }
    $outcome.increments.Add(@{ index = $k; items = $mine; sent = ($null -ne $call); exact = $exact; imports = $imports; error = $code; rejected = $rejected })
  }
  foreach ($c in $ingests) {
    $names = Get-SentNames $c
    $ours = $false
    foreach ($n in $names) { if ($all.ContainsKey($n)) { $ours = $true } }
    if (-not $ours) { $outcome.unknown.Add($names) }
  }
  $last = $null
  foreach ($c in $parsed.calls) {
    if ((Test-Is $c.tool 'world_app_sources_imports') -and -not $c.failed) {
      try { $b = ConvertFrom-JsText ([string]$c.text) } catch { continue }
      $last = $b
      foreach ($v in (Get-List $b 'items')) {
        if ($v -is [System.Collections.IDictionary]) { $outcome.readback.found[((ConvertTo-JsTemplate $v['source_item_id']) + '@' + (ConvertTo-JsTemplate $v['source_version']))] = $v['import_id'] }
      }
    }
  }
  $outcome.readback.complete = ($null -ne $last) -and (Test-NullField $last 'next_cursor')
  return $outcome
}

# ---------- 落盘 ----------
# Invoke-Effects 按 deliver（追加进 delivered）、remove（删队列文件和 results/）、write（写 results/）的顺序做。

function New-Effects { return @{ deliver = (New-Object System.Collections.Generic.List[string]); remove = (New-Object System.Collections.Generic.List[string]);
  write = (New-Object System.Collections.Generic.List[object]) } }

function Get-DeliveredLine($row, [string]$status, [string]$round, [string]$at, $extra) {
  $line = [ordered]@{ item_id = $row['item_id']; item_version = $row['item_version']; import_id = $extra['import_id']; status = $status; round_id = $round; at = $at }
  foreach ($k in $extra.Keys) { if ($k -cne 'import_id') { $line[$k] = $extra[$k] } }
  return ConvertTo-JsJson $line
}

function Invoke-Effects($effects) {
  if ($effects.deliver.Count -gt 0) { [System.IO.File]::AppendAllText($script:Delivered, (($effects.deliver -join "`n") + "`n"), $script:Utf8) }
  foreach ($name in $effects.remove) {
    foreach ($f in @((Join-Path $script:QueueDir ($name + '.json')), (Join-Path $script:ResultsDir ($name + '.json')))) {
      if ([System.IO.File]::Exists($f)) { [System.IO.File]::Delete($f) }
    }
  }
  # 新判断只在还没有这一条时写：已有的判断不改，重送用的就是落盘的那一份。
  foreach ($w in $effects.write) { Write-Atomic (Join-Path $script:ResultsDir ($w.name + '.json')) (ConvertTo-JsJson $w.value) $script:Work ($w.mode -ceq 'replace') }
}

function Get-SettleEffects($plan, [string]$round, [string]$at) {
  $effects = New-Effects
  foreach ($row in $plan.settle) {
    if ($null -ne $row['dropped']) { $effects.deliver.Add((Get-DeliveredLine $row 'dropped' $round $at ([ordered]@{ code = $row['dropped'] }))) }
    else { $effects.deliver.Add((Get-DeliveredLine $row 'null' $round $at ([ordered]@{}))) }
    $effects.remove.Add($row['name'])
  }
  foreach ($name in $plan.stale) { $effects.remove.Add($name) }
  return $effects
}

# 判断轮交回的：合规的照收；不合规的算被拒一次（invalid_increment），第二次就当 null，免得一直重判。
function Get-JudgeEffects($outcome, [string]$format, [string]$round, [string]$at) {
  $effects = New-Effects
  foreach ($a in $outcome.accepted) {
    $row = $a.row
    $attempt = 1; $mode = 'new'
    if ($null -ne $row['attempt']) { $attempt = [int]$row['attempt'] + 1; $mode = 'replace' }
    $effects.write.Add(@{ name = $row['name']; mode = $mode; value = [ordered]@{ format = $format; item_id = $row['item_id']; item_version = $row['item_version'];
      result = $a.result; attempt = $attempt; round_id = $round; judged_at = $at } })
  }
  foreach ($row in $outcome.invalid) {
    $attempt = 1; $mode = 'new'
    if ($null -ne $row['attempt']) { $attempt = [int]$row['attempt'] + 1; $mode = 'replace' }
    if ($attempt -ge 2) {
      $value = [ordered]@{ format = $format; item_id = $row['item_id']; item_version = $row['item_version']; result = $null; dropped = 'invalid_increment';
        attempt = $attempt; round_id = $round; judged_at = $at }
    }
    else {
      $value = [ordered]@{ format = $format; item_id = $row['item_id']; item_version = $row['item_version'];
        rejected = @([ordered]@{ code = 'invalid_increment'; round_id = $round }); attempt = $attempt }
    }
    $effects.write.Add(@{ name = $row['name']; mode = $mode; value = $value })
  }
  return $effects
}

# 送出之后：收到回执的记 imported（带导入 id）；被拒的下一轮带着 code 重判，已经判过两次的当 null；
# 报 IDEMPOTENCY_CONFLICT 的整份骨架标上 conflict，下一轮先读回；读回找到的记 conflict（带导入 id），读完没找到的去掉标记照常重送。
function Get-SendEffects($plan, $outcome, [string]$round, [string]$at) {
  $effects = New-Effects
  $rows = @{}
  foreach ($group in $plan.send) { foreach ($row in $group) { $rows[$row['name']] = $row } }
  foreach ($inc in $outcome.increments) {
    $got = @{}; foreach ($i in $inc.imports) { $got[$i.name] = $i.import_id }
    $why = @{}; foreach ($r in $inc.rejected) { $why[$r.name] = $r.code }
    foreach ($name in $inc.items) {
      $row = $rows[$name]
      if ($null -eq $row) { continue }
      $attempt = Get-Field $row['stored'] 'attempt'
      if ($null -eq $attempt) { $attempt = 1 }
      if ($got.ContainsKey($name)) {
        $extra = [ordered]@{ import_id = $got[$name] }
        if (-not $inc.exact) { $extra['copy_mismatch'] = $true }
        $effects.deliver.Add((Get-DeliveredLine $row 'imported' $round $at $extra)); $effects.remove.Add($name)
      }
      elseif ($why.ContainsKey($name)) {
        if ([int]$attempt -ge 2) {
          $effects.deliver.Add((Get-DeliveredLine $row 'dropped' $round $at ([ordered]@{ code = $why[$name] }))); $effects.remove.Add($name)
        }
        else {
          $history = New-Object System.Collections.Generic.List[object]
          foreach ($h in (Get-List $row['stored'] 'rejected')) { if ($null -ne $h) { $history.Add($h) } }
          $history.Add([ordered]@{ code = $why[$name]; round_id = $round })
          $effects.write.Add(@{ name = $name; mode = 'replace'; value = [ordered]@{ format = (Get-Field $row['stored'] 'format'); item_id = $row['item_id'];
            item_version = $row['item_version']; rejected = $history; attempt = $attempt } })
        }
      }
      elseif (Test-Is $inc.error 'IDEMPOTENCY_CONFLICT') {
        $value = [ordered]@{}
        foreach ($k in $row['stored'].Keys) { $value[$k] = $row['stored'][$k] }
        $value['conflict'] = $round
        $effects.write.Add(@{ name = $name; mode = 'replace'; value = $value })
      }
    }
  }
  foreach ($row in $plan.readback) {
    $name = $row['name']
    if ($outcome.readback.found.ContainsKey($name)) {
      $effects.deliver.Add((Get-DeliveredLine $row 'conflict' $round $at ([ordered]@{ import_id = $outcome.readback.found[$name] }))); $effects.remove.Add($name)
    }
    elseif ($outcome.readback.complete) {
      $value = [ordered]@{}
      foreach ($k in $row['stored'].Keys) { if ($k -cne 'conflict') { $value[$k] = $row['stored'][$k] } }
      $effects.write.Add(@{ name = $name; mode = 'replace'; value = $value })
    }
  }
  return $effects
}

# ---------- 运行回执 ----------

function Get-ReportArgs($cfg, [string]$round, [string]$started, [string]$finished, $plan, $files, $outcome, [int]$taken) {
  $backlog = [int]$plan.backlog
  $ids = New-Object System.Collections.Generic.List[object]
  $planned = 0; $accepted = 0; $blocked = $false
  if ($null -ne $outcome) {
    foreach ($inc in $outcome.increments) {
      $planned++
      if ($inc.sent -and ($null -eq $inc.error)) { $accepted++ }
      if ((Test-Is $inc.error 'SOURCE_ITEMS_REJECTED') -or (Test-Is $inc.error 'IDEMPOTENCY_CONFLICT')) { $blocked = $true }
      foreach ($i in $inc.imports) { $ids.Add($i.import_id) }
    }
  }
  if ($backlog -gt 0) { $status = 'partial'; $code = 'coverage_incomplete' }
  else {
    $status = 'ready'
    if ($ids.Count -gt 0) { $code = 'increment_ready' } elseif ($taken -gt 0) { $code = 'no_business_increment' } else { $code = 'no_new_content' }
  }
  if ($accepted -eq $planned) { if ($backlog -gt 0) { $delivery = 'accepted_with_gaps' } else { $delivery = 'accepted' } }
  elseif ($blocked) { $delivery = 'blocked' } else { $delivery = 'unknown' }
  $issues = New-Object System.Collections.Generic.List[object]
  if ($backlog -gt 0) { $issues.Add([ordered]@{ code = 'extraction_pending' }) }
  $pending = New-Object System.Collections.Generic.List[object]
  foreach ($p in $plan.pending) {
    if ($pending.Count -ge $script:Limits.pending) { break }
    $pending.Add([ordered]@{ item_id = $p.item_id; reason = 'extraction_pending'; item_version = $p.item_version })
  }
  if ($ids.Count -gt 1000) { $ids = $ids.GetRange(0, 1000) }
  return [ordered]@{ selection_id = $cfg.selection_id; request_key = ('run-' + $round); selection_version = $cfg.selection_version; trigger = 'source_change';
    observed_at = $started; started_at = $started; finished_at = $finished; coverage_status = $status; coverage_code = $code;
    discovered_files = $files.files; read_files = $files.files; read_bytes = $files.bytes; issue_count = $issues.Count; issues = $issues;
    pending_count = $backlog; pending = $pending; planned_batches = $planned; accepted_batches = $accepted; delivery_status = $delivery;
    import_count = $ids.Count; import_ids = $ids }
}

# ---------- 间隔与锁 ----------

function ConvertTo-UtcTime([string]$iso) {
  $t = [DateTime]::MinValue
  if ([DateTime]::TryParseExact($iso, "yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Invariant, [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal', [ref]$t)) { return $t }
  return $null
}

# 上一轮开始后至少隔 30 分钟再起；连续失败几轮，间隔就翻几倍，最长 4 小时（ADR 决定九）。
function Get-Gate([string]$roundsDir, [string]$format) {
  $rounds = New-Object System.Collections.Generic.List[object]
  if ([System.IO.Directory]::Exists($roundsDir)) {
    $files = [System.IO.Directory]::GetFiles($roundsDir, '*.json')
    [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
    foreach ($f in $files) {
      try { $r = ConvertFrom-JsText (Read-SharedText $f) } catch { continue }
      if (($r -is [System.Collections.IDictionary]) -and (Test-Is (Get-Field $r 'format') $format)) { $rounds.Add($r) }
    }
  }
  # 按开始时刻排（同一秒里的两轮 round_id 只差随机后缀，不能单按它排）。
  $sorted = $rounds.ToArray()
  $keys = New-Object string[] $sorted.Length
  for ($i = 0; $i -lt $sorted.Length; $i++) { $keys[$i] = [string](Get-Field $sorted[$i] 'started_at') + [char]0 + [string](Get-Field $sorted[$i] 'round_id') }
  [System.Array]::Sort($keys, $sorted, [System.StringComparer]::Ordinal)
  $rounds = New-Object System.Collections.Generic.List[object]
  foreach ($r in $sorted) { $rounds.Add($r) }
  $failures = 0
  for ($i = $rounds.Count - 1; $i -ge 0; $i--) { if ($null -ne (Get-Field $rounds[$i] 'failure')) { $failures++ } else { break } }
  $gap = [math]::Min(1800 * [math]::Pow(2, $failures), 14400)
  $gate = @{ failures = $failures; next_round_at = $null; too_soon = $false }
  if ($rounds.Count -gt 0) {
    $at = ConvertTo-UtcTime ([string](Get-Field $rounds[$rounds.Count - 1] 'started_at'))
    if ($null -ne $at) {
      $next = $at.AddSeconds($gap)
      $gate.next_round_at = $next.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Invariant)
      $gate.too_soon = [DateTime]::UtcNow -lt $next
    }
  }
  return $gate
}

function Test-LockStale([string]$lock) {
  try { return [System.IO.Directory]::GetLastWriteTimeUtc($lock) -lt [DateTime]::UtcNow.AddSeconds(-($script:RoundLimit + $script:LockMargin)) } catch { return $false }
}

# 锁是目录：New-Item 要么建成、要么失败。比时限再老一截的锁说明持锁的进程已经不在了，挪开重来。
# Only remove our own lock: after this round was judged stale and another round took over, the owner file is theirs.
function Exit-RoundLock([string]$lock) {
  try {
    $owner = ConvertFrom-JsText ([System.IO.File]::ReadAllText((Join-Path $lock 'owner'), $script:Utf8))
    if ($owner['round_id'] -ceq $script:RoundId) { [System.IO.Directory]::Delete($lock, $true) }
  } catch { }
  $script:Held = $null
}

function Enter-RoundLock([string]$lock) {
  try { [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop); return $true } catch { }
  if (-not (Test-LockStale $lock)) { return $false }
  try { [System.IO.Directory]::Move($lock, (Join-Path $script:Work 'stale-lock')) } catch { return $false }
  try { [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop); return $true } catch { return $false }
}

# ---------- 程序、已装的 world 插件、子进程 ----------

# 程序位置：TKOS_CAPTURE_CLAUDE / TKOS_CAPTURE_CODEX 指定的；否则钩子环境里的 PATH；再找常见的安装位置。
function Find-Program([string]$agent) {
  if ($agent -ceq 'claude') { $override = $env:TKOS_CAPTURE_CLAUDE } else { $override = $env:TKOS_CAPTURE_CODEX }
  if ($override) { if ([System.IO.File]::Exists($override)) { return $override } else { return $null } }
  foreach ($dir in ([string]$env:PATH).Split(';')) {
    if ($dir.Trim().Length -eq 0) { continue }
    foreach ($ext in @('.exe', '.cmd', '.bat')) {
      try { $candidate = Join-Path $dir.Trim() ($agent + $ext) } catch { continue }
      if ([System.IO.File]::Exists($candidate)) { return $candidate }
    }
  }
  if ($agent -ceq 'claude') { $candidates = @((Join-Path ([string]$env:USERPROFILE) '.local\bin\claude.exe'), [string]$env:CLAUDE_CODE_EXECPATH) }
  else { $candidates = @((Join-Path ([string]$env:APPDATA) 'npm\codex.cmd')) }
  foreach ($candidate in $candidates) { if ($candidate -and [System.IO.File]::Exists($candidate)) { return $candidate } }
  return $null
}

# 已装的 world 插件里的提炼技能。Claude Code 从 installed_plugins.json 取 installPath（版本升级后目录会变）；
# Codex 没有这样的索引，取插件缓存里 tkos-world\world 下版本号最大的目录。
function Get-WorldSkill([string]$agent) {
  $relative = 'skills\world-source-extract\SKILL.md'
  if ($agent -ceq 'claude') {
    if ($env:CLAUDE_CONFIG_DIR) { $config = $env:CLAUDE_CONFIG_DIR } else { $config = Join-Path ([string]$env:USERPROFILE) '.claude' }
    $installed = Join-Path $config 'plugins\installed_plugins.json'
    if (-not [System.IO.File]::Exists($installed)) { return $null }
    try { $data = ConvertFrom-JsText (Read-SharedText $installed) } catch { return $null }
    $entries = Get-Field (Get-Field $data 'plugins') 'world@tkos-world'
    if (-not ($entries -is [System.Collections.IList])) { return $null }
    $ordered = @($entries | Where-Object { Test-Is (Get-Field $_ 'scope') 'user' }) + @($entries)
    foreach ($e in $ordered) {
      $path = Get-Field $e 'installPath'
      if (($path -is [string]) -and [System.IO.Path]::IsPathRooted($path) -and [System.IO.File]::Exists((Join-Path $path $relative))) {
        return @{ plugin = $path; skill = (Join-Path $path $relative) }
      }
    }
    return $null
  }
  if ($env:CODEX_HOME) { $codexHome = $env:CODEX_HOME } else { $codexHome = Join-Path ([string]$env:USERPROFILE) '.codex' }
  $cache = Join-Path $codexHome 'plugins\cache\tkos-world\world'
  if (-not [System.IO.Directory]::Exists($cache)) { return $null }
  $best = $null; $bestKey = $null
  foreach ($dir in [System.IO.Directory]::GetDirectories($cache)) {
    $name = [System.IO.Path]::GetFileName($dir)
    if (-not ($name -cmatch '\A([0-9]+)\.([0-9]+)\.([0-9]+)\z')) { continue }
    $key = @([long]$Matches[1], [long]$Matches[2], [long]$Matches[3])
    $better = $null -eq $bestKey
    if (-not $better) { for ($i = 0; $i -lt 3; $i++) { if ($key[$i] -ne $bestKey[$i]) { $better = $key[$i] -gt $bestKey[$i]; break } } }
    if ($better) { $best = $dir; $bestKey = $key }
  }
  if (($null -eq $best) -or -not [System.IO.File]::Exists((Join-Path $best $relative))) { return $null }
  return @{ plugin = $best; skill = (Join-Path $best $relative) }
}

# Windows 命令行的引号规则（CommandLineToArgvW）：空格、制表符、引号要加引号，引号前的反斜杠加倍。
function ConvertTo-ArgString([string]$a) {
  if (($a.Length -gt 0) -and -not ($a -match '[\s"]')) { return $a }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($ch in $a.ToCharArray()) {
    if ($ch -eq [char]92) { $slashes++; continue }
    if ($ch -eq [char]34) { [void]$sb.Append([string]::new([char]92, 2 * $slashes + 1)); [void]$sb.Append('"'); $slashes = 0; continue }
    if ($slashes -gt 0) { [void]$sb.Append([string]::new([char]92, $slashes)); $slashes = 0 }
    [void]$sb.Append($ch)
  }
  [void]$sb.Append([string]::new([char]92, 2 * $slashes))
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Get-CliArguments([string]$kind) {
  $list = New-Object System.Collections.Generic.List[string]
  if ($script:Agent -ceq 'claude') {
    $tools = @($script:RoundTools[$kind] | ForEach-Object { $script:ClaudePrefix + $_ }) -join ','
    $model = $env:TKOS_CAPTURE_CLAUDE_MODEL
    if (-not $model) { $model = 'sonnet' }
    foreach ($a in @('-p', '--no-session-persistence', '--setting-sources', '', '--plugin-dir', $script:WorldPlugin, '--tools', '', '--allowedTools', $tools,
        '--permission-mode', 'dontAsk', '--output-format', 'stream-json', '--verbose', '--model', $model)) { $list.Add($a) }
    return , $list
  }
  $enabled = '[' + ((@($script:RoundTools[$kind] | ForEach-Object { '"' + $_ + '"' })) -join ',') + ']'
  foreach ($a in @('exec', '--ephemeral', '--ignore-user-config', '--skip-git-repo-check', '--sandbox', 'read-only', '-C', $script:CliWork,
      '-c', 'features.shell_tool=false', '-c', 'features.view_image=false', '-c', 'web_search="disabled"',
      '-c', 'tools.experimental_request_user_input.enabled=false', '-c', 'agents.enabled=false', '-c', 'features.goals=false',
      '-c', 'features.sleep_tool=false', '-c', 'features.image_generation=false', '-c', 'features.tool_suggest=false', '-c', 'features.apps=false',
      '-c', 'cloud.skills.enabled=false', '-c', 'features.code_mode=false',
      '-c', ('mcp_servers.world.url="' + $script:WorldUrl + '"'), '-c', ('mcp_servers.world.enabled_tools=' + $enabled),
      '-c', 'mcp_servers.world.default_tools_approval_mode="approve"', '-c', 'mcp_servers.world.required=true',
      '-c', 'mcp_servers.world.omit_tools_from=["deferred","code_mode"]', '--json', '-')) { $list.Add($a) }
  return , $list
}

# 子进程只拿到这些环境变量：不带钩子环境里 Agent 会话自己的变量（会话 id、消息通道之类）。
function Set-ChildEnvironment($psi) {
  $keep = @('SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'HOME', 'APPDATA', 'LOCALAPPDATA',
    'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'USERNAME', 'USERDOMAIN',
    'COMPUTERNAME', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'OS', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME')
  $values = @{}
  foreach ($k in $keep) { $v = [Environment]::GetEnvironmentVariable($k); if ($v) { $values[$k] = $v } }
  $psi.EnvironmentVariables.Clear()
  foreach ($k in $values.Keys) { $psi.EnvironmentVariables[$k] = $values[$k] }
  $system = Join-Path ([string]$env:SystemRoot) 'System32'
  $psi.EnvironmentVariables['PATH'] = (Split-Path -Parent $script:Program) + ';' + $system + ';' + [string]$env:SystemRoot + ';' +
    (Join-Path $system 'WindowsPowerShell\v1.0') + ';' + [string]$env:PATH
  $psi.EnvironmentVariables['TEMP'] = $script:CliTemp
  $psi.EnvironmentVariables['TMP'] = $script:CliTemp
  $psi.EnvironmentVariables['WORLD_AUTO_EXTRACT_ROUND'] = $script:RoundId
}

# 起一次 CLI，最多等 $limit 秒，到点连同子进程一起结束（taskkill /T）。返回退出码、是否超时和两路输出。
function Invoke-Cli([string]$kind, [int]$limit, [string]$prompt) {
  if ($limit -lt 1) { $limit = 1 }
  New-Directory $script:CliTemp
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:Program
  # Get-CliArguments 交出的是整个 List（return , $list），先接住再逐个加引号，不能直接接管道。
  $arguments = Get-CliArguments $kind
  $quoted = foreach ($a in $arguments) { ConvertTo-ArgString $a }
  $psi.Arguments = $quoted -join ' '
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $script:Utf8
  $psi.StandardErrorEncoding = $script:Utf8
  $psi.WorkingDirectory = $script:CliWork
  Set-ChildEnvironment $psi
  $started = [DateTime]::UtcNow
  try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return @{ status = 127; timed_out = $false; out = ''; err = ''; seconds = 0 } }
  $script:Child = $p
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  try {
    $bytes = $script:Utf8.GetBytes($prompt)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
  }
  catch { }
  $timedOut = -not $p.WaitForExit($limit * 1000)
  if ($timedOut) {
    $taskkill = Join-Path ([string]$env:SystemRoot) 'System32\taskkill.exe'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $taskkill '/T' '/F' '/PID' $p.Id.ToString($script:Invariant) > $null 2> $null } finally { $ErrorActionPreference = $previous }
    [void]$p.WaitForExit(10000)
  }
  else { $p.WaitForExit() }
  $status = 137
  if ($p.HasExited) { $status = $p.ExitCode }
  $out = ''; $err = ''
  try { if ($outTask.Wait(5000)) { $out = $outTask.Result } } catch { }
  try { if ($errTask.Wait(5000)) { $err = $errTask.Result } } catch { }
  $script:Child = $null
  return @{ status = $status; timed_out = $timedOut; out = $out; err = $err; seconds = [int]([DateTime]::UtcNow - $started).TotalSeconds }
}

# claude -p 每次在 projects 下按工作目录留一个只有空 memory\ 的目录（核查 9）；只删空的。
function Remove-ClaudeProject {
  if ($env:CLAUDE_CONFIG_DIR) { $config = $env:CLAUDE_CONFIG_DIR } else { $config = Join-Path ([string]$env:USERPROFILE) '.claude' }
  $dir = Join-Path (Join-Path $config 'projects') ([regex]::Replace($script:CliWork, '[^A-Za-z0-9]', '-'))
  if (-not [System.IO.Directory]::Exists($dir)) { return }
  # 工具返回超过约 50 KB 时还有 <会话 id>\tool-results\ 下存的完整返回（--no-session-persistence 也存，实测）：删掉存下的返回再删空目录。
  foreach ($session in [System.IO.Directory]::GetDirectories($dir)) {
    $results = Join-Path $session 'tool-results'
    if (-not [System.IO.Directory]::Exists($results)) { continue }
    foreach ($f in [System.IO.Directory]::GetFiles($results, 'toolu_*')) { try { [System.IO.File]::Delete($f) } catch { } }
    foreach ($d in @($results, $session)) {
      try { if ([System.IO.Directory]::GetFileSystemEntries($d).Count -eq 0) { [System.IO.Directory]::Delete($d) } } catch { }
    }
  }
  foreach ($d in @((Join-Path $dir 'memory'), $dir)) {
    try { if ([System.IO.Directory]::Exists($d) -and ([System.IO.Directory]::GetFileSystemEntries($d).Count -eq 0)) { [System.IO.Directory]::Delete($d) } } catch { }
  }
}

# ---------- 一轮 ----------

function Set-RoundFailure($failure) { if (($null -ne $failure) -and ($null -eq $script:State.failure)) { $script:State.failure = $failure } }

function Get-Left { return $script:RoundLimit - [int]([DateTime]::UtcNow - $script:RoundStart).TotalSeconds }

# 一次模型调用：记进这一轮的经过，交出解析好的输出（带 failure）。
function Invoke-Call([string]$kind, [int]$limit, [string]$prompt) {
  $run = Invoke-Cli $kind $limit $prompt
  if ($script:Agent -ceq 'claude') { Remove-ClaudeProject; $parsed = Read-ClaudeStream (Read-Lines $run.out) }
  else { $parsed = Read-CodexStream (Read-Lines $run.out) }
  $tail = [string]$run.err
  if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
  $parsed.failure = Get-Failure $parsed $script:Agent ([int]$run.status) ([bool]$run.timed_out) $tail
  $script:State.calls.Add([ordered]@{ kind = $kind; exit_code = $run.status; seconds = $run.seconds; timed_out = $run.timed_out; failure = $parsed.failure; usage = $parsed.usage })
  $script:State.exit_code = $run.status
  if ($null -ne $parsed.usage) {
    if ($null -eq $script:State.usage) { $script:State.usage = [ordered]@{ input_tokens = 0; cached_input_tokens = 0; output_tokens = 0 } }
    $script:State.usage = Add-Usage $script:State.usage $parsed.usage.input_tokens $parsed.usage.cached_input_tokens $parsed.usage.output_tokens
  }
  return $parsed
}

function Get-CurrentPlan { return Get-Plan $script:QueueDir $script:ResultsDir $script:Delivered $script:Format (Get-PromptSection $script:Prompts 'omitted') }

function Invoke-Settle($plan) {
  $effects = Get-SettleEffects $plan $script:RoundId (Get-Now)
  Invoke-Effects $effects
  $script:State.nulls += @($effects.deliver | Where-Object { $_.Contains('"status":"null"') }).Count
}

function Invoke-JudgeBatch($plan, [int]$i) {
  $budget = (Get-Left) - (Get-Share 9 20)
  if ($budget -le (Get-Share 1 20)) { return 2 }
  $budget = [math]::Min($budget, (Get-Share 1 4))
  $batch = $plan.judge[$i]
  $parsed = Invoke-Call 'judge' $budget (Get-JudgePrompt $script:Prompts $script:Rules $script:Cfg $batch)
  if ($null -ne $parsed.failure) { Set-RoundFailure $parsed.failure; return 1 }
  $outcome = Get-JudgeOutcome $parsed $batch $script:Cfg
  if ($null -ne $outcome.failure) { Set-RoundFailure $outcome.failure; return 1 }
  Invoke-Effects (Get-JudgeEffects $outcome $script:Format $script:RoundId (Get-Now))
  $script:State.taken += $outcome.accepted.Count + $outcome.invalid.Count
  foreach ($m in $outcome.mismatches) { $m['call'] = 'judge'; $script:State.mismatches.Add($m) }
  foreach ($n in $outcome.unanswered) { $script:State.mismatches.Add([ordered]@{ name = $n; reason = 'unanswered'; call = 'judge' }) }
  return 0
}

function Invoke-SendBatch($plan) {
  $budget = [math]::Min((Get-Left) - (Get-Share 1 4), (Get-Share 1 5))
  if ($budget -lt 1) { Set-RoundFailure (New-Failure 'other' 'no_time_to_send'); return $null }
  $increments = Get-Increments $plan.send $script:Cfg $script:RoundId
  $parsed = Invoke-Call 'send' $budget (Get-SendPrompt $script:Prompts $script:Cfg $increments $plan.readback)
  $outcome = Get-SendOutcome $parsed $increments
  $effects = Get-SendEffects $plan $outcome $script:RoundId (Get-Now)
  Invoke-Effects $effects
  foreach ($line in $effects.deliver) {
    $d = ConvertFrom-JsText $line
    if (Test-Is $d['status'] 'imported') { $script:State.accepted++ }
    if ($null -ne $d['import_id']) { $script:State.imports.Add([ordered]@{ item_id = $d['item_id']; item_version = $d['item_version']; import_id = $d['import_id'] }) }
  }
  foreach ($inc in $outcome.increments) {
    if ($inc.sent -and -not $inc.exact) { $script:State.mismatches.Add([ordered]@{ items = $inc.items; reason = 'copy_mismatch'; call = 'send' }) }
    $script:State.rejected += $inc.rejected.Count
    if ($null -ne $inc.error) { $script:State.send_errors.Add([ordered]@{ items = $inc.items; error = $inc.error }) }
  }
  foreach ($names in $outcome.unknown) { $script:State.mismatches.Add([ordered]@{ items = $names; reason = 'unknown_import'; call = 'send' }) }
  if ($null -ne $parsed.failure) { Set-RoundFailure $parsed.failure; return $null }
  return $outcome
}

function Invoke-ReportRun($plan, $outcome) {
  $budget = [math]::Min((Get-Left), (Get-Share 1 4))
  if ($budget -lt 1) { $script:State.report = [ordered]@{ status = 'skipped'; reason = 'no_time' }; return }
  $count = 0; $bytes = [long]0
  $transcripts = Join-Path $script:StateDir 'transcripts'
  if ([System.IO.Directory]::Exists($transcripts)) {
    foreach ($f in [System.IO.Directory]::GetFiles($transcripts, '*.json')) {
      try { $p = ConvertFrom-JsText (Read-SharedText $f) } catch { continue }
      if (Test-Is (Get-Field $p 'format') $script:Format) { $count++; $bytes += [long](Get-Field $p 'offset') }
    }
  }
  $reportArgs = Get-ReportArgs $script:Cfg $script:RoundId $script:RoundStarted (Get-Now) $plan @{ files = $count; bytes = $bytes } $outcome $script:State.taken
  $parsed = Invoke-Call 'report' $budget (Get-ReportPrompt $script:Prompts $reportArgs)
  $runs = @($parsed.calls | Where-Object { Test-Is $_.tool 'world_app_sources_report_run' })
  $report = [ordered]@{ status = 'not_called' }
  foreach ($c in $runs) {
    $b = $null
    try { $b = ConvertFrom-JsText ([string]$c.text) } catch { }
    if ((Test-SameJson $c.args $reportArgs) -and -not $c.failed -and ($null -eq (Get-Field $b 'error'))) { $report = [ordered]@{ status = 'reported' }; break }
    if (-not (Test-SameJson $c.args $reportArgs)) { $report = [ordered]@{ status = 'copy_mismatch' } }
    else { $report = [ordered]@{ status = 'failed'; error = (Get-Field (Get-Field $b 'error') 'code') } }
  }
  $script:State.report = $report
  $script:State.backlog = $plan.backlog
}

function Invoke-RoundSteps {
  $configText = Read-SharedText (Join-Path $script:StateDir 'config.json')
  $entry = Get-ConfigEntry $configText $script:Agent $script:Format
  if ($null -eq $entry) { Set-RoundFailure (New-Failure 'other' 'config_changed'); return }
  $e = Get-Field (Get-Field (ConvertFrom-JsText $configText) 'agents') $script:Agent
  $script:Cfg = @{ selection_id = $e['selection_id']; selection_version = $e['selection_version']; source_id = $e['source_id'] }
  $script:Program = Find-Program $script:Agent
  if ($null -eq $script:Program) { Set-RoundFailure (New-Failure 'program_missing' 'not_found'); return }
  $world = Get-WorldSkill $script:Agent
  if ($null -eq $world) { Set-RoundFailure (New-Failure 'world_unavailable' 'world_plugin_missing'); return }
  $script:WorldPlugin = $world.plugin
  $script:Rules = Get-SkillRules (Read-SharedText $world.skill) (Get-PromptSection $script:Prompts 'rules-from')
  if ($null -eq $script:Rules) { Set-RoundFailure (New-Failure 'world_unavailable' 'skill_rules_missing'); return }
  $plan = Get-CurrentPlan
  Invoke-Settle $plan
  for ($i = 0; $i -lt $plan.judge.Count; $i++) {
    $done = Invoke-JudgeBatch $plan $i
    if ($done -eq 2) { break }
    if ($done -ne 0) { return }
  }
  $plan = Get-CurrentPlan
  Invoke-Settle $plan
  $outcome = $null
  if (($plan.send.Count + $plan.readback.Count) -gt 0) {
    $outcome = Invoke-SendBatch $plan
    if ($null -ne $script:State.failure) { return }
  }
  Invoke-ReportRun (Get-CurrentPlan) $outcome
}

function Invoke-Round([string]$agent, [string]$format, [string]$stateDir, [string]$queue, [string]$work, [string]$trigger) {
  $lock = Join-Path $stateDir 'round.lock'
  $script:Work = $work
  $script:RoundStart = [DateTime]::UtcNow
  $script:RoundStarted = Get-Now
  $script:RoundId = $script:RoundStart.ToString("yyyyMMdd'T'HHmmss'Z'", $script:Invariant) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  if (-not (Enter-RoundLock $lock)) { return }
  $script:Held = $lock
  try {
    $script:Agent = $agent; $script:Format = $format; $script:StateDir = $stateDir; $script:QueueDir = $queue
    [System.IO.File]::WriteAllText((Join-Path $lock 'owner'), (ConvertTo-JsJson ([ordered]@{ pid = $PID; round_id = $script:RoundId; started_at = $script:RoundStarted })), $script:Utf8)
    foreach ($d in @('rounds', 'results', 'delivered', 'work')) { New-Directory (Join-Path $stateDir $d) }
    $script:ResultsDir = Join-Path $stateDir 'results'
    $script:CliWork = Join-Path $stateDir 'work'
    $script:CliTemp = Join-Path $work 'tmp'
    $deliveredDir = Join-Path (Join-Path $stateDir 'delivered') ($format.Split('/')[0])
    New-Directory $deliveredDir
    $script:Delivered = Join-Path (Join-Path $stateDir 'delivered') ($format.Replace('/', '\') + '.jsonl')
    $script:Prompts = Get-RoundPrompts
    $script:State = [ordered]@{ taken = 0; accepted = 0; nulls = 0; rejected = 0; calls = (New-Object System.Collections.Generic.List[object]);
      mismatches = (New-Object System.Collections.Generic.List[object]); imports = (New-Object System.Collections.Generic.List[object]);
      send_errors = (New-Object System.Collections.Generic.List[object]); usage = $null; exit_code = $null; failure = $null; report = $null; backlog = $null }
    try { Invoke-RoundSteps } catch { Set-RoundFailure (New-Failure 'other' 'launcher_error') }
    $record = [ordered]@{ round_id = $script:RoundId; agent = $agent; format = $format; trigger = $trigger; started_at = $script:RoundStarted; finished_at = (Get-Now) }
    foreach ($k in $script:State.Keys) { $record[$k] = $script:State[$k] }
    $roundsDir = Join-Path $stateDir 'rounds'
    Write-Atomic (Join-Path $roundsDir ($script:RoundId + '.json')) (ConvertTo-JsJson $record) $work $true
    $old = [System.IO.Directory]::GetFiles($roundsDir, '*.json')
    [System.Array]::Sort($old, [System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $old.Length - 400; $i++) { try { [System.IO.File]::Delete($old[$i]) } catch { } }
  }
  finally {
    Exit-RoundLock $lock
  }
}

# ---------- 钩子 ----------

# 这台机器上采集能不能工作：不能时交出原因，能时是 $null（顺带准备好 JSON 解析器）。
function Get-SupportReason {
  if ($PSVersionTable.PSEdition -ceq 'Core') { return 'powershell_core' }
  try {
    Add-Type -AssemblyName System.Web.Extensions
    $script:Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $script:Json.MaxJsonLength = [int]::MaxValue
    $script:Json.RecursionLimit = 1000
  }
  catch { return 'json_parser_unavailable' }
  return $null
}

# 钩子用：不能工作时只把原因写进 unsupported.json（临时文件再改名），别的什么都不做。
function Test-Unsupported([string]$stateDir) {
  $reason = Get-SupportReason
  if ($null -eq $reason) { return $false }
  try {
    New-Directory $stateDir
    $file = Join-Path $stateDir 'unsupported.json'
    $now = Get-Now
    $first = $now
    if ([System.IO.File]::Exists($file)) {
      $m = [regex]::Match((Read-SharedText $file), '"first_seen_at":"([0-9TZ:-]*)"')
      if ($m.Success) { $first = $m.Groups[1].Value }
    }
    $record = [ordered]@{ reason = $reason; system = 'Windows'; os_version = [Environment]::OSVersion.Version.ToString();
      first_seen_at = $first; last_seen_at = $now }
    Write-Atomic $file (ConvertTo-JsJson $record) $stateDir $true
  }
  catch { }
  return $true
}

# ---------- 「开始采集」与迁移（ADR 决定七、八）：对话里的 Agent 调用的三个子命令，同 setup.jq ----------
# capture.ps1 <check|enable|import> <claude|codex> [选择记录文件]：标准输出上交一行 JSON（UTF-8），拒绝时退出码 1。

function Write-Out($value) {
  $bytes = $script:Utf8.GetBytes((ConvertTo-JsJson $value) + "`n")
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
  $out.Flush()
  $script:Answered = $true
}

function Write-Refusal([string]$reason) {
  $script:ExitCode = 1
  Write-Out ([ordered]@{ ok = $false; reason = $reason })
}

# 读一个 JSON 文件：present 是文件在不在，ok 是读不读得出（文件内容是 null 时 value 也是 $null）。
function Read-JsonFile([string]$path) {
  if ((-not $path) -or (-not [System.IO.File]::Exists($path))) { return @{ present = $false; ok = $true; value = $null } }
  try { $v = ConvertFrom-JsText (Read-SharedText $path) } catch { return @{ present = $true; ok = $false; value = $null } }
  return @{ present = $true; ok = $true; value = $v }
}

# 文件在、读出来却不是对象（或读不出）：不能拿来改写。
function Test-Unusable($file) {
  return $file.present -and ((-not $file.ok) -or (($null -ne $file.value) -and -not ($file.value -is [System.Collections.IDictionary])))
}

function Test-Uuid($v) { return ($v -is [string]) -and ($v -cmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') }

function Test-ItemShape($e) {
  $id = Get-Field $e 'item_id'
  $version = Get-Field $e 'item_version'
  return ($id -is [string]) -and ($id -cmatch '\Aentry-[0-9a-f]{64}\z') -and ($version -is [string]) -and ($version -cmatch '\A[0-9a-f]{64}\z')
}

# 这种 Agent 的数据目录下要读的文件夹：Claude Code 是 projects，Codex 是 sessions（钩子只读其中未压缩的 .jsonl）。
function Get-DataFolder([string]$agent) {
  if ($agent -ceq 'claude') {
    if ($env:CLAUDE_CONFIG_DIR) { $base = $env:CLAUDE_CONFIG_DIR } else { $base = Join-Path ([string]$env:USERPROFILE) '.claude' }
    return Join-Path $base 'projects'
  }
  if ($env:CODEX_HOME) { $base = $env:CODEX_HOME } else { $base = Join-Path ([string]$env:USERPROFILE) '.codex' }
  return Join-Path $base 'sessions'
}

function Get-DataDirName([string]$agent) {
  if ($agent -ceq 'claude') { if ($env:CLAUDE_CONFIG_DIR) { return 'CLAUDE_CONFIG_DIR' } else { return '~/.claude' } }
  if ($env:CODEX_HOME) { return 'CODEX_HOME' } else { return '~/.codex' }
}

# 组件的 settings.json（host.mjs 的格式）：合用时交出要用的几项，否则 $null。
function Get-ComponentSettings($s) {
  if (-not ($s -is [System.Collections.IDictionary])) { return $null }
  if (-not (Test-Is (Get-Field $s 'format') 'world-capture-host/1')) { return $null }
  $device = Get-Field $s 'device_id'
  if (-not (($device -is [string]) -and ($device -cmatch '\A[0-9a-f-]{36}\z'))) { return $null }
  $format = Get-Field $s 'source_format'
  if (-not ($format -is [string])) { $format = $null }
  $selection = Get-Field $s 'selection_id'
  if (-not (Test-Uuid $selection)) { $selection = $null }
  $root = Get-Field (Get-Field $s 'location') 'root'
  if (-not ($root -is [string])) { $root = $null }
  $open = Get-Field $s 'open_at_login'
  return @{ device_id = $device; source_format = $format; selection_id = $selection; root = $root; capture_enabled = (Get-Bool $s 'capture_enabled');
    open_at_login = -not (($open -is [bool]) -and (-not $open)) }
}

function Read-ComponentSettings {
  $dir = Get-ComponentDir
  if ($null -eq $dir) { return $null }
  return (Read-JsonFile (Join-Path $dir 'settings.json')).value
}

function Get-ConfigDevice($config) {
  $d = Get-Field $config 'device_id'
  if (($d -is [string]) -and ($d -cmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z')) { return $d }
  return $null
}

# 这台设备的 id：已有 config.json 的；没有就用组件的（迁移时来源标识要和组件建的选择对得上）；都没有是 $null。
function Get-DeviceChoice($config, $settings) {
  $c = Get-ConfigDevice $config
  if ($null -ne $c) { return @{ device = $c; from = 'config' } }
  $comp = Get-ComponentSettings $settings
  if ($null -ne $comp) { return @{ device = $comp.device_id; from = 'component' } }
  return $null
}

# 选择记录对得上这台设备这种 Agent 的本机采集时，交出 config.json 里的那一项和设备 id；否则 @{ refused = code }。
# $mode 是确认方式：对话里新建的是 current_dialogue，迁移沿用的组件选择是 component_window。$device 为 $null 时设备 id 要是 UUID。
function Get-SelectionEntry($sel, [string]$agent, [string]$format, [string]$mode, $device, [string]$folder) {
  if (-not ($sel -is [System.Collections.IDictionary])) { return @{ refused = 'selection_unreadable' } }
  $version = Get-Field $sel 'version'
  if ((-not (Test-Uuid (Get-Field $sel 'selection_id'))) -or (-not ((Test-NonNegativeInteger $version) -and ($version -ge 1)))) { return @{ refused = 'selection_unreadable' } }
  if (-not (Test-Is (Get-Field $sel 'status') 'active')) { return @{ refused = 'selection_not_active' } }
  $choice = Get-Field $sel 'choice'
  $src = Get-Field $choice 'source'
  $history = Get-Field $choice 'history'
  $k = Get-Field $sel 'confirmation'
  $sid = Get-Field $src 'source_id'
  $prefix = 'local-capture-' + $agent + '-'
  $own = $null
  if (($sid -is [string]) -and $sid.StartsWith($prefix, $script:Ordinal)) { $own = $sid.Substring($prefix.Length) }
  if ((-not (Test-Is (Get-Field $src 'adapter') 'work-increment/0.1')) -or ($null -eq $own) -or (-not ($sid -cmatch '\A[A-Za-z0-9][A-Za-z0-9._:/@+~-]{0,199}\z')) `
      -or (-not (Test-Is (Get-Field $src 'locator') ('local-capture:' + $sid)))) { return @{ refused = 'source_mismatch' } }
  if ((($null -ne $device) -and (-not ($own -ceq $device))) -or (($null -eq $device) -and (-not (Test-Uuid $own)))) { return @{ refused = 'device_mismatch' } }
  $start = Get-Field $history 'start_at'
  if ((-not (Test-Is (Get-Field $choice 'version_scope') 'authorized_increments')) -or ($null -eq (ConvertTo-Utc $start)) -or ($null -ne (Get-Field $history 'end_at'))) {
    return @{ refused = 'history_mismatch' }
  }
  if (-not (Test-Is (Get-Field $k 'mode') $mode)) { return @{ refused = 'confirmation_mismatch' } }
  if ($mode -ceq 'current_dialogue') {
    $text = Get-Field $k 'text'
    if (-not ($text -is [string])) { return @{ refused = 'scope_not_confirmed' } }
    foreach ($word in $script:ScopeWords[$agent]) { if ($text.IndexOf($word, $script:Ordinal) -lt 0) { return @{ refused = 'scope_not_confirmed' } } }
  }
  $entry = [ordered]@{ selection_id = (Get-Field $sel 'selection_id'); selection_version = $version; source_id = $sid; format = $format; history_from = $start;
    confirmed_at = (Get-Field $k 'confirmed_at'); folder = $folder }
  return @{ device = $own; entry = $entry }
}

function New-ConfigWithEntry($config, [string]$agent, [string]$device, $entry) {
  $agents = [ordered]@{}
  $old = Get-Field $config 'agents'
  if ($old -is [System.Collections.IDictionary]) { foreach ($k in $old.Keys) { $agents[[string]$k] = $old[$k] } }
  $agents[$agent] = $entry
  return [ordered]@{ device_id = $device; agents = $agents }
}

# check：能不能采、设备 id 与来源标识、要读的文件夹名（不交路径）、已在采的选择、组件在不在。什么都不写。
function Invoke-Check([string]$agent, [string]$format, [string]$stateDir) {
  $system = [Environment]::OSVersion.Version.ToString()
  $reason = Get-SupportReason
  if ($null -ne $reason) { Write-Out ([ordered]@{ supported = $false; reason = $reason; system = 'Windows'; os_version = $system }); return }
  $config = (Read-JsonFile (Join-Path $stateDir 'config.json')).value
  $settings = Read-ComponentSettings
  $choice = Get-DeviceChoice $config $settings
  if ($null -eq $choice) { $device = [guid]::NewGuid().ToString(); $from = 'new' } else { $device = $choice.device; $from = $choice.from }
  $capturing = $null
  if ($null -ne (Get-ConfigEntryOf $config $agent $format)) {
    $e = Get-Field (Get-Field $config 'agents') $agent
    $capturing = [ordered]@{ selection_id = (Get-Field $e 'selection_id'); selection_version = (Get-Field $e 'selection_version');
      history_from = (Get-Field $e 'history_from'); confirmed_at = (Get-Field $e 'confirmed_at') }
  }
  $comp = Get-ComponentSettings $settings
  $component = $null
  if ($null -ne $comp) {
    $component = [ordered]@{ selection_id = $comp.selection_id; source_format = $comp.source_format; capture_enabled = $comp.capture_enabled;
      running = (Test-ComponentCapturing); open_at_login = $comp.open_at_login }
  }
  $folder = Get-DataFolder $agent
  Write-Out ([ordered]@{ supported = $true; system = 'Windows'; os_version = $system; agent = $agent; format = $format; data_dir = (Get-DataDirName $agent);
    folder = [System.IO.Path]::GetFileName($folder); folder_present = [System.IO.Directory]::Exists($folder); device_id = $device; device_from = $from;
    source_id = ('local-capture-' + $agent + '-' + $device); capturing = $capturing; component = $component })
}

# enable：对话里确认、world 已建好的选择（selection 对象的 JSON 文件）写进 config.json。读的文件夹按数据目录算，不由 Agent 给。
function Invoke-Enable([string]$agent, [string]$format, [string]$stateDir, [string]$file) {
  $reason = Get-SupportReason
  if ($null -ne $reason) { Write-Refusal $reason; return }
  if ((-not $file) -or (-not [System.IO.File]::Exists($file))) { Write-Refusal 'selection_file_missing'; return }
  # 数据目录是相对路径时，钩子按会话的工作目录解释它，读的范围对不上，从此静默不采；直接拒。
  if (-not ((Get-DataFolder $agent) -cmatch '\A(?:[A-Za-z]:[\\/]|\\\\)')) { Write-Refusal 'data_dir_not_absolute'; return }
  $configFile = Read-JsonFile (Join-Path $stateDir 'config.json')
  if (Test-Unusable $configFile) { Write-Refusal 'config_unreadable'; return }
  $config = $configFile.value
  $choice = Get-DeviceChoice $config (Read-ComponentSettings)
  $expected = $null
  if ($null -ne $choice) { $expected = $choice.device }
  $r = Get-SelectionEntry (Read-JsonFile $file).value $agent $format 'current_dialogue' $expected (Get-DataFolder $agent)
  if ($r.refused) { Write-Refusal $r.refused; return }
  $old = Get-Field (Get-Field (Get-Field $config 'agents') $agent) 'selection_id'
  New-PrivateRoot $stateDir
  Write-Atomic (Join-Path $stateDir 'config.json') (ConvertTo-JsJson (New-ConfigWithEntry $config $agent $r.device $r.entry)) $stateDir $true
  $replaced = $null
  if (($null -ne $old) -and -not ($old -ceq $r.entry.selection_id)) { $replaced = $old }
  Write-Out ([ordered]@{ ok = $true; agent = $agent; selection_id = $r.entry.selection_id; selection_version = $r.entry.selection_version;
    history_from = $r.entry.history_from; replaced = $replaced })
}

function Test-CheckpointShape($cp) {
  if (-not ($cp -is [System.Collections.IDictionary])) { return $false }
  if (-not (Test-Is (Get-Field $cp 'format') 'world-source-run-checkpoint/0.1')) { return $false }
  $progress = Get-Field $cp 'progress'
  if ($null -eq $progress) { return $true }
  return ($progress -is [System.Collections.IDictionary]) -and (Test-Is (Get-Field $progress 'format') 'world-capture-progress/0.1') `
    -and ((Get-Field $progress 'entries') -is [System.Collections.IDictionary])
}

function Test-ExtractionShape($ex, [string]$format) {
  return ($ex -is [System.Collections.IDictionary]) -and (Test-Is (Get-Field $ex 'format') 'world-capture-extraction/0.1') `
    -and (Test-Is (Get-Field $ex 'source_format') $format) -and ((Get-Field $ex 'pending') -is [System.Collections.IList]) `
    -and ((Get-Field $ex 'results') -is [System.Collections.IList])
}

# 确认过的文件夹里的会话文件，递归找，不进重解析点（同 sh 版 find 不跟符号链接）。
function Get-SessionFiles([string]$root) {
  $found = New-Object System.Collections.Generic.List[string]
  if (-not [System.IO.Directory]::Exists($root)) { return , $found }
  $pending = New-Object System.Collections.Generic.Stack[string]
  $pending.Push($root)
  while ($pending.Count -gt 0) {
    $dir = $pending.Pop()
    try {
      foreach ($f in [System.IO.Directory]::GetFiles($dir, '*.jsonl')) { $found.Add($f) }
      foreach ($d in [System.IO.Directory]::GetDirectories($dir)) { if (-not (Test-ReparsePoint $d)) { $pending.Push($d) } }
    }
    catch { }
  }
  return , $found
}

function Get-NameSet([string]$dir, [string]$pattern) {
  $names = @{}
  foreach ($f in [System.IO.Directory]::GetFiles($dir, $pattern)) { $names[[System.IO.Path]::GetFileNameWithoutExtension($f)] = $true }
  return $names
}

# import：沿用组件在窗口里建的选择（selection 对象的 JSON 文件），接过它的进度。组件目录只读不写。
# 顺序：已处理的进 delivered\，补读文件夹里的会话文件，交回未送的进 results\，记下读不到原文的，最后写 config.json；
# 中途断了重跑，每一步都按已有的状态推（delivered 不重记、队列与 results\ 不覆盖、位置文件接着读）。
function Invoke-Import([string]$agent, [string]$format, [string]$stateDir, [string]$file) {
  $reason = Get-SupportReason
  if ($null -ne $reason) { Write-Refusal $reason; return }
  if ((-not $file) -or (-not [System.IO.File]::Exists($file))) { Write-Refusal 'selection_file_missing'; return }
  $component = Get-ComponentDir
  if (($null -eq $component) -or (-not [System.IO.File]::Exists((Join-Path $component 'settings.json')))) { Write-Refusal 'component_missing'; return }
  if (Test-Exists (Join-Path $component 'agent-channel.json')) { Write-Refusal 'component_running'; return }
  $s = Get-ComponentSettings (Read-JsonFile (Join-Path $component 'settings.json')).value
  $checkpoint = @{ present = $false; ok = $true; value = $null }
  $extraction = @{ present = $false; ok = $true; value = $null }
  if (($null -ne $s) -and ($null -ne $s.selection_id)) {
    $checkpoint = Read-JsonFile (Join-Path $component ('source-' + $s.selection_id + '.json'))
    $extraction = Read-JsonFile (Join-Path $component ('extraction-' + $s.selection_id + '.json'))
  }
  $configFile = Read-JsonFile (Join-Path $stateDir 'config.json')
  $config = $configFile.value
  $sel = (Read-JsonFile $file).value
  if ($null -eq $s) { Write-Refusal 'component_settings_unreadable'; return }
  if (-not (Test-Is $s.source_format $format)) { Write-Refusal 'component_format_mismatch'; return }
  if ($null -eq $s.selection_id) { Write-Refusal 'component_no_selection'; return }
  if ($s.capture_enabled) { Write-Refusal 'component_capture_enabled'; return }
  if (-not (Test-RootedPath $s.root)) { Write-Refusal 'component_location_unreadable'; return }
  if (Test-Unusable $configFile) { Write-Refusal 'config_unreadable'; return }
  $configDevice = Get-ConfigDevice $config
  if (($null -ne $configDevice) -and -not ($configDevice -ceq $s.device_id)) { Write-Refusal 'device_mismatch'; return }
  if (-not (Test-Is (Get-Field $sel 'selection_id') $s.selection_id)) { Write-Refusal 'selection_mismatch'; return }
  $r = Get-SelectionEntry $sel $agent $format 'component_window' $s.device_id $s.root
  if ($r.refused) { Write-Refusal $r.refused; return }
  if ($null -ne (Get-ConfigEntryOf $config $agent $format)) {
    if (Test-Is (Get-Field (Get-Field (Get-Field $config 'agents') $agent) 'selection_id') $s.selection_id) {
      Write-Out ([ordered]@{ ok = $true; agent = $agent; selection_id = $s.selection_id; already = $true })
      return
    }
    Write-Refusal 'agent_already_configured'; return
  }
  if (Test-Unusable $checkpoint) { Write-Refusal 'checkpoint_unreadable'; return }
  if (($null -ne $checkpoint.value) -and -not (Test-CheckpointShape $checkpoint.value)) { Write-Refusal 'checkpoint_unreadable'; return }
  if (Test-Unusable $extraction) { Write-Refusal 'extraction_unreadable'; return }
  if (($null -ne $extraction.value) -and -not (Test-ExtractionShape $extraction.value $format)) { Write-Refusal 'extraction_unreadable'; return }
  $planPending = ($null -ne $checkpoint.value) -and ($null -ne (Get-Field $checkpoint.value 'pending'))

  $state = Initialize-State $stateDir $format
  $work = $state.work
  try {
    foreach ($d in @('delivered', 'results')) { New-Directory (Join-Path $stateDir $d) }
    New-Directory (Join-Path (Join-Path $stateDir 'delivered') ($format.Split('/')[0]))
    $doneFile = Join-Path (Join-Path $stateDir 'delivered') ($format.Replace('/', '\') + '.jsonl')
    $resultsDir = Join-Path $stateDir 'results'
    $at = Get-Now
    $done = @{}
    if ([System.IO.File]::Exists($doneFile)) { $done = Get-DeliveredSet (Read-SharedText $doneFile) }
    $lines = New-Object System.Collections.Generic.List[string]
    $entries = Get-Field (Get-Field $checkpoint.value 'progress') 'entries'
    if ($entries -is [System.Collections.IDictionary]) {
      foreach ($key in $entries.Keys) {
        $row = @{ item_id = [string]$key; item_version = $entries[$key] }
        if (-not (Test-ItemShape $row)) { continue }
        $name = $row.item_id + '@' + $row.item_version
        if ($done.ContainsKey($name)) { continue }
        $done[$name] = $true
        $lines.Add((ConvertTo-JsJson ([ordered]@{ item_id = $row.item_id; item_version = $row.item_version; import_id = $null; status = 'component'; round_id = $null; at = $at })))
      }
    }
    if ($lines.Count -gt 0) { [System.IO.File]::AppendAllText($doneFile, (($lines -join "`n") + "`n"), $script:Utf8) }

    # 补读确认过的文件夹：组件检查点里记着的和之后新出现的会话文件都在这里，按读增量的同一套规则从头读。唯一一次扫目录。
    $entry = @{ source_id = $r.entry.source_id; start = (ConvertTo-Utc $r.entry.history_from); folder = $s.root }
    $since = ConvertTo-UtcTime ($entry.start.Substring(0, 19) + 'Z')
    $before = (Get-NameSet $state.queue 'entry-*.json').Count
    $files = 0
    $skipped = 0
    foreach ($path in (Get-SessionFiles $s.root)) {
      if (-not (Test-Transcript $path $s.root)) { continue }
      # 最后修改早于历史起点的文件里没有起点以后的条目（与库相同）。
      if ([System.IO.File]::GetLastWriteTimeUtc($path) -lt $since) { $skipped++; continue }
      $files++
      Read-Increment $format $entry $path $state.transcripts $state.queue $work $stateDir
    }
    $queuedNames = Get-NameSet $state.queue 'entry-*.json'
    $queued = $queuedNames.Count - $before

    # 组件交回了、还没送出的结果：重送时内容与当初逐字相同，world 认得出同一条。
    $judged = Get-NameSet $resultsDir '*.json'
    $carried = 0
    $seen = @{}
    foreach ($row in (Get-List $extraction.value 'results')) {
      if (-not (($row -is [System.Collections.IDictionary]) -and (Test-ItemShape $row) -and (Test-HasKey $row 'result'))) { continue }
      $name = Get-Name $row
      if ($seen.ContainsKey($name) -or (-not $queuedNames.ContainsKey($name)) -or $judged.ContainsKey($name)) { continue }
      $seen[$name] = $true
      $submitted = Get-Field $row 'submitted_at'
      if (-not ($submitted -is [string])) { $submitted = $null }
      $target = Join-Path $resultsDir ($name + '.json')
      if ([System.IO.File]::Exists($target)) { continue }
      Write-Atomic $target (ConvertTo-JsJson ([ordered]@{ format = $format; item_id = $row['item_id']; item_version = $row['item_version']; result = $row['result'];
        attempt = 1; round_id = 'import'; judged_at = $submitted })) $work $false
      $carried++
    }

    # 组件的待提炼和交回的结果里，补读之后既不在待提炼、也不在已送出的：原文已经读不到，是覆盖缺口。
    $missing = New-Object System.Collections.Generic.List[object]
    $missed = @{}
    foreach ($key in @('pending', 'results')) {
      foreach ($row in (Get-List $extraction.value $key)) {
        if (-not (($row -is [System.Collections.IDictionary]) -and (Test-ItemShape $row))) { continue }
        $name = Get-Name $row
        if ($missed.ContainsKey($name) -or $queuedNames.ContainsKey($name) -or $done.ContainsKey($name)) { continue }
        $missed[$name] = $true
        $missing.Add([ordered]@{ item_id = $row['item_id']; item_version = $row['item_version'] })
      }
    }

    $record = [ordered]@{ format = 'world-capture-import/0.1'; agent = $agent; selection_id = $s.selection_id; imported_at = $at; delivered = $lines.Count;
      queued = $queued; results = $carried; missing = $missing.Count; missing_items = $missing; files = $files; skipped_files = $skipped;
      component_plan_pending = $planPending; open_at_login = $s.open_at_login }
    Write-Atomic (Join-Path $stateDir 'import.json') (ConvertTo-JsJson $record) $work $true
    # 最后写 config.json：钩子要等它才读这种 Agent 的会话、起后台轮。
    Write-Atomic (Join-Path $stateDir 'config.json') (ConvertTo-JsJson (New-ConfigWithEntry $config $agent $s.device_id $r.entry)) $work $true
    Write-Out ([ordered]@{ ok = $true; agent = $agent; selection_id = $s.selection_id; already = $false; delivered = $lines.Count; queued = $queued;
      results = $carried; missing = $missing.Count; files = $files; skipped_files = $skipped; component_plan_pending = $planPending; open_at_login = $s.open_at_login })
  }
  finally { try { [System.IO.Directory]::Delete($work, $true) } catch { } }
}

function Read-Stdin {
  $stream = [Console]::OpenStandardInput()
  $memory = New-Object System.IO.MemoryStream
  $stream.CopyTo($memory)
  return $script:Utf8.GetString($memory.ToArray()).TrimStart([char]0xFEFF)
}

function Invoke-Main($cli) {
  $mode = 'hook'
  $at = 0
  if (($cli.Count -gt 0) -and (@('check', 'enable', 'import') -ccontains [string]$cli[0])) { $mode = [string]$cli[0]; $at = 1; $script:Command = $mode }
  elseif (($cli.Count -gt 0) -and ($cli[0] -ceq '__worker')) { $mode = 'worker'; $at = 1 }
  $agent = [string]$cli[$at]
  $hookEvent = [string]$cli[$at + 1]
  if ($agent -ceq 'claude') { $format = 'claude-session-jsonl/1' }
  elseif ($agent -ceq 'codex') { $format = 'codex-rollout-jsonl/1' }
  else { if ($script:Command) { Write-Refusal 'unknown_agent' }; return }
  if ((-not $script:Command) -and -not ($hookEvent -cmatch '\A[A-Za-z]+\z')) { return }
  if ($env:TKOS_CAPTURE_HOME) { $stateDir = $env:TKOS_CAPTURE_HOME }
  elseif ($env:USERPROFILE) { $stateDir = Join-Path $env:USERPROFILE '.tkos-world\capture' }
  else { if ($script:Command) { Write-Refusal 'no_home' }; return }
  if ($mode -ceq 'check') { Invoke-Check $agent $format $stateDir; return }
  if ($mode -ceq 'enable') { Invoke-Enable $agent $format $stateDir $hookEvent; return }
  if ($mode -ceq 'import') { Invoke-Import $agent $format $stateDir $hookEvent; return }

  if (Test-Unsupported $stateDir) { return }
  if ($mode -ceq 'worker') {
    Invoke-Worker $agent $hookEvent $format $stateDir ([string]$env:TKOS_CAPTURE_TRANSCRIPT)
    return
  }
  $unsupported = Join-Path $stateDir 'unsupported.json'
  if ([System.IO.File]::Exists($unsupported)) { [System.IO.File]::Delete($unsupported) }
  $configPath = Join-Path $stateDir 'config.json'
  if (-not [System.IO.File]::Exists($configPath)) { return }
  if ($null -eq (Get-ConfigEntry (Read-SharedText $configPath) $agent $format)) { return }
  try { $payload = $script:Json.DeserializeObject((Read-Stdin)) } catch { return }
  $path = Get-Field $payload 'transcript_path'
  if (-not ($path -is [string])) { return }
  if ($env:TKOS_CAPTURE_FOREGROUND -ceq '1') {
    Invoke-Worker $agent $hookEvent $format $stateDir $path
    return
  }
  # 脱离：新进程不继承钩子的标准输入输出，钩子马上返回；会话文件路径经环境变量传，免得命令行引号出错。
  $env:TKOS_CAPTURE_TRANSCRIPT = $path
  $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script:Self + '" __worker ' + $agent + ' ' + $hookEvent
  Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden
}

# 钩子任何情况下都退出码 0、什么都不输出；子命令出了意外也交一行拒绝。
$script:ExitCode = 0
$script:Command = $null
$script:Answered = $false
try { Initialize-Capture; $null = Invoke-Main @($args) }
catch { if ($script:Command -and -not $script:Answered) { try { Write-Refusal 'failed' } catch { } } }
exit $script:ExitCode
