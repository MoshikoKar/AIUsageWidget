#requires -Version 5.1
param(
  [string]$ConfigJson,
  [string]$ConfigPath,
  [switch]$Demo,
  [string]$Root = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
if ($ConfigPath) { $ConfigJson = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) }
if (-not $ConfigJson) { throw 'ConfigJson or ConfigPath is required' }
Add-Type -AssemblyName System.Security
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class AesGcmDec {
    [StructLayout(LayoutKind.Sequential)]
    struct AuthInfo {
        public int cbSize; public int dwInfoVersion;
        public IntPtr pbNonce; public int cbNonce;
        public IntPtr pbAuthData; public int cbAuthData;
        public IntPtr pbTag; public int cbTag;
        public IntPtr pbMacContext; public int cbMacContext;
        public int cbAAD; public long cbData; public int dwFlags;
    }
    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)] static extern uint BCryptOpenAlgorithmProvider(out IntPtr alg, string id, string impl, uint flags);
    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)] static extern uint BCryptSetProperty(IntPtr obj, string prop, byte[] input, int cb, uint flags);
    [DllImport("bcrypt.dll")] static extern uint BCryptGenerateSymmetricKey(IntPtr alg, out IntPtr key, IntPtr keyObj, int cbKeyObj, byte[] secret, int cbSecret, uint flags);
    [DllImport("bcrypt.dll")] static extern uint BCryptDecrypt(IntPtr key, byte[] input, int cbInput, ref AuthInfo pad, byte[] iv, int cbIv, byte[] output, int cbOutput, out int result, uint flags);
    [DllImport("bcrypt.dll")] static extern uint BCryptDestroyKey(IntPtr key);
    [DllImport("bcrypt.dll")] static extern uint BCryptCloseAlgorithmProvider(IntPtr alg, uint flags);

    public static byte[] Decrypt(byte[] key, byte[] nonce, byte[] ct, byte[] tag) {
        IntPtr alg, hKey = IntPtr.Zero;
        uint st = BCryptOpenAlgorithmProvider(out alg, "AES", null, 0);
        if (st != 0) throw new Exception("BCryptOpenAlgorithmProvider 0x" + st.ToString("X"));
        GCHandle hn = GCHandle.Alloc(nonce, GCHandleType.Pinned);
        GCHandle ht = GCHandle.Alloc(tag, GCHandleType.Pinned);
        try {
            byte[] mode = Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            st = BCryptSetProperty(alg, "ChainingMode", mode, mode.Length, 0);
            if (st != 0) throw new Exception("BCryptSetProperty 0x" + st.ToString("X"));
            st = BCryptGenerateSymmetricKey(alg, out hKey, IntPtr.Zero, 0, key, key.Length, 0);
            if (st != 0) throw new Exception("BCryptGenerateSymmetricKey 0x" + st.ToString("X"));
            AuthInfo info = new AuthInfo();
            info.cbSize = Marshal.SizeOf(typeof(AuthInfo)); info.dwInfoVersion = 1;
            info.pbNonce = hn.AddrOfPinnedObject(); info.cbNonce = nonce.Length;
            info.pbTag = ht.AddrOfPinnedObject(); info.cbTag = tag.Length;
            byte[] output = new byte[ct.Length]; int len;
            st = BCryptDecrypt(hKey, ct, ct.Length, ref info, null, 0, output, output.Length, out len, 0);
            if (st != 0) throw new Exception("BCryptDecrypt 0x" + st.ToString("X"));
            Array.Resize(ref output, len);
            return output;
        } finally {
            hn.Free(); ht.Free();
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            BCryptCloseAlgorithmProvider(alg, 0);
        }
    }
}
"@
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfg = $ConfigJson | ConvertFrom-Json
$UA  = 'ai-usage-widget/1.0'


[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfg = $ConfigJson | ConvertFrom-Json
$UA  = 'ai-usage-widget/1.0'

function NormReset($reset) {
    if ($null -eq $reset -or "$reset" -eq '') { return $null }
    if ($reset -is [datetime] -or $reset -is [datetimeoffset]) {
        return ([DateTimeOffset]$reset).UtcDateTime.ToString('o')
    }
    if ($reset -is [string] -and $reset -match '[T:\-]') { return $reset }
    try {
        $n = [int64]$reset
        if ($n -gt 10000000000) { $n = [int64][math]::Floor($n / 1000) }
        return FromUnix $n
    } catch { return "$reset" }
}
function W($pct, $reset) { @{ pct = [math]::Round([double]$pct, 1); reset = (NormReset $reset) } }
function FromUnix($s) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$s).UtcDateTime.ToString('o') }
function Slot([double]$seconds) {
    if ($seconds -le 6 * 3600) { 'session' } elseif ($seconds -le 36 * 3600) { 'daily' }
    elseif ($seconds -le 10 * 86400) { 'weekly' } else { 'monthly' }
}
function Decode-Jwt($t) {
    $parts = "$t".Split('.')
    if ($parts.Count -lt 3) { throw 'token is not a JWT' }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}
function Assert-NotExpired($jwt, $tool) {
    $exp = $null
    try { $exp = (Decode-Jwt $jwt).exp } catch {}
    if ($exp -and [DateTimeOffset]::FromUnixTimeSeconds([int64]$exp).UtcDateTime -lt [DateTime]::UtcNow) {
        throw "login expired - open $tool כדי לחדש"
    }
}
function Friendly($err) {
    $code = $null
    try { $code = [int]$err.Exception.Response.StatusCode } catch {}
    if ($code -eq 401 -or $code -eq 403) { return "re-login required ($code)" }
    if ($code) { return "server error ($code)" }
    return $err.Exception.Message
}

# Claude (claude.ai Pro/Max): same numbers as /usage in Claude Code.
function Get-Claude {
    $p = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (-not (Test-Path $p)) { throw 'Claude Code login not found' }
    $o = (Get-Content $p -Raw | ConvertFrom-Json).claudeAiOauth
    if (-not $o -or -not $o.accessToken) { throw 'Claude Code not signed in to a plan' }
    if ($o.expiresAt -and [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$o.expiresAt).UtcDateTime -lt [DateTime]::UtcNow) {
        throw 'login expired - open Claude Code'
    }
    $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -UserAgent $UA -TimeoutSec 20 `
        -Headers @{ Authorization = "Bearer $($o.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
    $w = @{}
    if ($r.five_hour) { $w.session = W $r.five_hour.utilization $r.five_hour.resets_at }
    if ($r.seven_day) { $w.weekly  = W $r.seven_day.utilization $r.seven_day.resets_at }
    if ($r.extra_usage -and $r.extra_usage.is_enabled -and $null -ne $r.extra_usage.utilization) {
        $w.monthly = W $r.extra_usage.utilization $null
    }
    @{ plan = $o.subscriptionType; windows = $w }
}

# Codex (ChatGPT Plus/Pro): same numbers as /status in Codex.
function Get-Codex {
    $p = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path $p)) { throw 'Codex login not found' }
    $t = (Get-Content $p -Raw | ConvertFrom-Json).tokens
    if (-not $t -or -not $t.access_token) { throw 'Codex is using an API key, not a subscription' }
    Assert-NotExpired $t.access_token 'Codex'
    $h = @{ Authorization = "Bearer $($t.access_token)" }
    if ($t.account_id) { $h['ChatGPT-Account-Id'] = $t.account_id }
    $r = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' -Headers $h -UserAgent 'codex_cli_rs' -TimeoutSec 20
    $w = @{}
    foreach ($win in @($r.rate_limit.primary_window, $r.rate_limit.secondary_window)) {
        if (-not $win) { continue }
        $reset = $null
        if ($win.reset_at) { $reset = FromUnix $win.reset_at }
        elseif ($win.reset_after_seconds) { $reset = [DateTime]::UtcNow.AddSeconds([double]$win.reset_after_seconds).ToString('o') }
        $secs = 5 * 3600
        if ($win.limit_window_seconds) { $secs = [double]$win.limit_window_seconds }
        $w[(Slot $secs)] = W $win.used_percent $reset
    }
    @{ plan = $r.plan_type; windows = $w }
}

# Grok Bot (desktop app): weekly usage, same numbers as its "Weekly usage" screen.
function Unprotect-ElectronSecret($value, $localStatePath) {
    if ($value.StartsWith('plaintext:v1:')) { return $value.Substring(13) }
    $bytes = [Convert]::FromBase64String($value)
    $prefix = [Text.Encoding]::ASCII.GetString($bytes, 0, [math]::Min(3, $bytes.Length))
    if ($prefix -eq 'v10' -or $prefix -eq 'v11') {
        $ls = Get-Content $localStatePath -Raw | ConvertFrom-Json
        $ek = [Convert]::FromBase64String($ls.os_crypt.encrypted_key)
        $ek = [byte[]]$ek[5..($ek.Length - 1)]                                  # drop the "DPAPI" marker
        $key = [Security.Cryptography.ProtectedData]::Unprotect($ek, $null, 'CurrentUser')
        $nonce = [byte[]]$bytes[3..14]
        $ct    = [byte[]]$bytes[15..($bytes.Length - 17)]
        $tag   = [byte[]]$bytes[($bytes.Length - 16)..($bytes.Length - 1)]
        return [Text.Encoding]::UTF8.GetString([AesGcmDec]::Decrypt($key, $nonce, $ct, $tag))
    }
    return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser'))
}
# Checksum header required by Grok Bot's Sand dashboard API.
function Sand-Checksum($machineId, $nowMs = $null) {
    if ($null -eq $nowMs) { $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $t = [int32][math]::Floor([double]$nowMs / 1e6)
    $b = New-Object byte[] 6
    # Same bytes as the app's JavaScript (shift counts wrap at 32, so >>40 is >>8 and >>32 is >>0).
    $shifts = 8, 0, 24, 16, 8, 0
    for ($i = 0; $i -lt 6; $i++) { $b[$i] = [byte](($t -shr $shifts[$i]) -band 255) }
    $k = 165
    for ($i = 0; $i -lt 6; $i++) { $b[$i] = [byte]((($b[$i] -bxor $k) + $i) -band 255); $k = $b[$i] }
    ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_') + $machineId
}
function Get-GrokBot {
    $dir = Join-Path $env:APPDATA 'Grok Bot'
    $sf = Join-Path $dir 'sand-secrets.json'
    if (-not (Test-Path $sf)) { throw 'Grok Bot not found or not signed in' }
    $j = Get-Content $sf -Raw | ConvertFrom-Json

    # Walk the whole file: the token key may be nested per account and/or carry a scope prefix.
    $cands = New-Object System.Collections.ArrayList
    $names = New-Object System.Collections.ArrayList
    $walk = {
        param($o, $path, $depth)
        if ($depth -gt 6 -or $null -eq $o) { return }
        foreach ($p in $o.PSObject.Properties) {
            $here = "$path/$($p.Name)"
            if ($names.Count -lt 25) { [void]$names.Add($here) }
            if ($p.Value -is [string]) {
                if ($p.Name -like '*access-token*' -or $p.Name -like '*accessToken*') { [void]$cands.Add(@{ path = $here; value = $p.Value }) }
            } elseif ($p.Value -is [pscustomobject]) { & $walk $p.Value $here ($depth + 1) }
        }
    }
    $ls = Join-Path $dir 'Local State'
    & $walk $j '' 0

    # Accounts live inside "cursor-accounts" ({active, accounts:{scope:{key:value}}}), stored encrypted as one value.
    $active = $null
    $acctRaw = $j.'cursor-accounts'
    if ($acctRaw) {
        $doc = $acctRaw
        if ($acctRaw -is [string]) {
            $plain = $acctRaw
            try { $plain = Unprotect-ElectronSecret $acctRaw $ls } catch {}
            try { $doc = $plain | ConvertFrom-Json } catch { throw "cursor-accounts decrypt failed | len=$($acctRaw.Length)" }
        }
        if ($doc -is [pscustomobject]) {
            $names.Clear()
            & $walk $doc '/cursor-accounts' 0
            if ($doc.active) { $active = "$($doc.active)" }
        }
    }
    if ($cands.Count -eq 0) { throw "no Grok Bot token found | keys: $(($names | Select-Object -First 12) -join ', ')" }

    # Prefer the account Grok Bot has selected.
    if (-not $active) { try { $active = "$((Get-Content (Join-Path $env:USERPROFILE '.grokbot\settings.json') -Raw | ConvertFrom-Json).activeAccountScope)" } catch {} }
    $ordered = @($cands | Sort-Object { if ($active -and $_.path -like "*$active*") { 0 } else { 1 } })

    $tok = $null; $why = @()
    foreach ($c in $ordered) {
        try {
            $plain = $c.value
            if ($plain -notmatch '^eyJ') { $plain = Unprotect-ElectronSecret $c.value $ls }
            if ($plain -match 'eyJ[\w-]+\.[\w-]+\.[\w-]+') {
                $cand = $Matches[0]
                $exp = $null; try { $exp = (Decode-Jwt $cand).exp } catch {}
                if ($exp -and [DateTimeOffset]::FromUnixTimeSeconds([int64]$exp).UtcDateTime -lt [DateTime]::UtcNow) { $why += "$($c.path): expired"; continue }
                $tok = $cand; break
            }
            $why += "$($c.path): not JWT"
        } catch { $why += "$($c.path): $($_.Exception.Message)" }
    }
    if (-not $tok) { throw "could not read Grok Bot login | $($why -join '; ')" }
    $mid = $null
    if ($j.'cursor-machine-id' -is [string]) {
        $mid = $j.'cursor-machine-id'
        try { $mid = Unprotect-ElectronSecret $mid $ls } catch {}
        if ($mid -notmatch '^[\w-]{8,128}$') { $mid = $null }
    }
    if (-not $mid) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $mid = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$env:COMPUTERNAME|ai-usage-widget")) | ForEach-Object { $_.ToString('x2') })
    }
    $h = @{
        Authorization              = "Bearer $tok"
        'connect-protocol-version' = '1'
        'x-ghost-mode'             = 'true'
        'x-cursor-client-version'  = 'sand-desktop'
        'x-cursor-client-os'       = 'CLIENT_OS_WINDOWS'
        'x-cursor-checksum'        = (Sand-Checksum $mid)
    }
    $r = Invoke-RestMethod -Method Post -Uri 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus' `
        -Headers $h -ContentType 'application/json' -Body '{}' -TimeoutSec 20 `
        -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Sand/0.79.2 Safari/537.36'
    if ($r.usesPooledEnterpriseAllowance) { throw 'pooled enterprise allowance - no personal percent' }
    $w = @{}
    if ($null -ne $r.usagePercent) { $w.weekly = W $r.usagePercent $r.nextResetTimestampUtc }
    @{ plan = $r.grokPlanLabel; windows = $w }
}

function Get-Manual($s) {
    $w = @{}
    foreach ($k in 'session', 'daily', 'weekly', 'monthly') {
        $v = $null
        if ($s.manual) { $v = $s.manual.$k }
        if ($null -ne $v -and "$v" -ne '') { $w[$k] = W $v $null }
    }
    @{ plan = 'manual'; windows = $w }
}

function Get-Demo($s) {
    $n = [DateTime]::UtcNow
    switch ($s.type) {
        'claude'  { @{ plan = 'pro';       windows = @{ session = (W 42 $n.AddHours(2.4).ToString('o')); weekly = (W 67 $n.AddDays(3.2).ToString('o')) } } }
        'codex'   { @{ plan = 'plus';      windows = @{ session = (W 18 $n.AddHours(4.1).ToString('o')); weekly = (W 81 $n.AddDays(5.6).ToString('o')) } } }
        'grokbot' { @{ plan = 'Grok Bot Plan'; windows = @{ weekly = (W 24 $n.AddDays(4.5).ToString('o')) } } }
        default   { @{ plan = 'manual';      windows = @{ session = (W 30 $null); weekly = (W 55 $null) } } }
    }
}

$out = New-Object System.Collections.ArrayList
foreach ($s in @($cfg.services)) {
    if ($s.enabled -eq $false) { continue }
    $res = @{ id = $s.id; name = $s.name; color = $s.color; type = $s.type; status = 'ok'; message = $null; plan = $null; windows = @{} }
    try {
        $d = $null
        if ($Demo) { $d = Get-Demo $s }
        elseif ($s.type -eq 'claude')  { $d = Get-Claude }
        elseif ($s.type -eq 'codex')   { $d = Get-Codex }
        elseif ($s.type -eq 'grokbot') { $d = Get-GrokBot }
        elseif ($s.type -eq 'manual')  { $d = Get-Manual $s; $res.status = 'manual' }
        else { throw "kind שירות לא מוכר: $($s.type)" }
        $res.plan = $d.plan
        $res.windows = $d.windows
    } catch {
        $res.status = 'error'
        $res.message = Friendly $_
    }
    [void]$out.Add($res)
}
ConvertTo-Json -InputObject @($out) -Depth 6 -Compress
