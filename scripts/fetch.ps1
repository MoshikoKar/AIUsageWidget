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

function W($pct, $reset) { @{ pct = [math]::Round([double]$pct, 1); reset = $reset } }
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

# Cursor: monthly plan usage from cursor.com (needs Python to read Cursor's local login).
function Get-Cursor {
    $db = Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb'
    if (-not (Test-Path $db)) { throw 'Cursor not found' }
    $py = Get-Command python, py -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $py) { throw 'Python required to read Cursor login' }
    $outText = ''
    try { $outText = (& $py.Source -I (Join-Path $Root 'cursor_token.py') $db 2>&1 | Out-String).Trim() } catch { $outText = "ERR:$($_.Exception.Message)" }
    $info = $null
    try { $info = $outText.Split("`n")[-1] | ConvertFrom-Json } catch {}
    if (-not $info) { throw "failed to read login for Cursor נכשלה | $($outText.Split("`n")[-1].Trim())" }
    if (@($info.candidates).Count -eq 0) { throw "no Cursor token found | keys: $(@($info.keys) -join ', ')" }

    $ls = Join-Path $env:APPDATA 'Cursor\Local State'
    $mid = $null
    try { $mid = (Get-Content (Join-Path $env:APPDATA 'Cursor\User\globalStorage\storage.json') -Raw | ConvertFrom-Json).'telemetry.machineId' } catch {}
    if (-not $mid) { $mid = 'ai-usage-widget' }
    $ver = '1.0.0'
    try { $ver = (Get-Content (Join-Path $env:LOCALAPPDATA 'Programs\cursor\resources\app\package.json') -Raw | ConvertFrom-Json).version } catch {}

    # Use the server Cursor itself is signed in to; only accept Cursor's own domains.
    $backend = 'https://api2.cursor.sh'
    if ($info.backend -and $info.backend -match '^https://[a-z0-9.-]+\.cursor\.(sh|com)$') { $backend = $info.backend }

    # Try every candidate (secret store first); report "key -> result" without values if none works.
    $report = @()
    foreach ($c in @($info.candidates)) {
        $short = ($c.key -replace '^secret://', 's://')
        if ($short.Length -gt 48) { $short = $short.Substring(0, 48) + '...' }
        $tok = $null
        try { $tok = Reveal-Token $c.b64 $ls 'Cursor' -AllowOpaque } catch { $report += "$short -> decrypt failed"; continue }
        if ($tok -match '^eyJ[\w-]+\.[\w-]+\.[\w-]+$') {
            $exp = $null; try { $exp = (Decode-Jwt $tok).exp } catch {}
            if ($exp -and [DateTimeOffset]::FromUnixTimeSeconds([int64]$exp).UtcDateTime -lt [DateTime]::UtcNow) { $report += "$short -> expired"; continue }
        }
        try { return (Get-CursorUsage $tok $mid $ver $backend) }
        catch {
            $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code) { $report += "$short -> $code" } else { $report += "$short -> $($_.Exception.Message)" }
        }
    }
    throw "Cursor rejected all tokens | server=$backend | $($report -join '; ')"
}

function Get-CursorUsage($tok, $mid, $ver, $backend) {
    $isJwt = $tok -match '^eyJ[\w-]+\.[\w-]+\.[\w-]+$'
    # Preferred: Cursor's own dashboard RPC (works with any token format, same data as the in-app usage view).
    $firstErr = $null
    try {
        $h = @{
            Authorization              = "Bearer $tok"
            'connect-protocol-version' = '1'
            'x-ghost-mode'             = 'true'
            'x-cursor-client-version'  = $ver
            'x-cursor-checksum'        = (Cursor-Checksum $mid)
        }
        $r = Invoke-RestMethod -Method Post -Uri "$backend/aiserver.v1.DashboardService/GetCurrentPeriodUsage" `
            -Headers $h -ContentType 'application/json' -Body '{}' -TimeoutSec 20 -UserAgent "Cursor/$ver"
        $pu = $r.planUsage
        $pct = $null
        if ($pu) {
            foreach ($f in 'totalPercentUsed', 'percentUsed') { if ($null -eq $pct -and $null -ne $pu.$f) { $pct = [double]$pu.$f } }
            if ($null -eq $pct -and $pu.limit -and [double]$pu.limit -gt 0) {
                $spent = $pu.includedSpend; if ($null -eq $spent) { $spent = $pu.totalSpend }
                $pct = 100.0 * [double]$spent / [double]$pu.limit
            }
        }
        $reset = $null
        if ($r.billingCycleEnd -and [double]$r.billingCycleEnd -gt 0) {
            $reset = [DateTimeOffset]::FromUnixTimeMilliseconds([int64][double]$r.billingCycleEnd).UtcDateTime.ToString('o')
        }
        if ($null -eq $pct) { throw "no plan data in response | fields: $((@($r.PSObject.Properties.Name) + @($pu.PSObject.Properties.Name)) -join ',')" }
        return @{ plan = $null; windows = @{ monthly = (W $pct $reset) } }
    } catch { $firstErr = $_ }

    # Fallback: cursor.com web usage summary (needs a JWT to build the session cookie).
    if (-not $isJwt) { throw $firstErr }
    $uid = ("$((Decode-Jwt $tok).sub)" -split '\|')[-1]
    $r = Invoke-RestMethod -Uri 'https://cursor.com/api/usage-summary' -UserAgent $UA -TimeoutSec 20 `
        -Headers @{ Cookie = "WorkosCursorSessionToken=$uid%3A%3A$tok" }
    $plan = $r.individualUsage.plan
    $pct = $null
    if ($plan -and $null -ne $plan.totalPercentUsed) { $pct = [double]$plan.totalPercentUsed }
    elseif ($plan -and $plan.limit) { $pct = 100.0 * [double]$plan.used / [double]$plan.limit }
    $w = @{}
    if ($null -ne $pct) { $w.monthly = W $pct $r.billingCycleEnd }
    elseif ($r.isUnlimited) { throw 'unlimited plan' }
    @{ plan = $r.membershipType; windows = $w }
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
# Takes base64 bytes that may be: a plain token, base64-of-safeStorage text, or a safeStorage blob.
# Returns the JWT inside, or throws with a short, value-free description of what was found.
function Reveal-Token($b64, $localStatePath, $tool, [switch]$AllowOpaque) {
    $bytes = [Convert]::FromBase64String($b64)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text -match '^eyJ[\w-]+\.[\w-]+\.[\w-]+') { return $Matches[0] }
    $attempts = @($b64)
    if ($text -match '^[A-Za-z0-9+/=\s]{16,}$') { $attempts += $text.Trim() }   # value was itself base64 text
    elseif ($text -match '^[A-Za-z0-9_-]{16,}={0,2}$') {                         # ... or base64url text
        $s = $text.TrimEnd('=').Replace('-', '+').Replace('_', '/')
        switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
        $attempts += $s
    }
    if ($text.StartsWith('plaintext:v1:')) { $attempts = @($text) }
    $why = @()
    foreach ($a in $attempts) {
        try {
            $plain = Unprotect-ElectronSecret $a $localStatePath
            if ($plain.TrimStart().StartsWith('{')) {
                try {
                    $o = $plain | ConvertFrom-Json
                    foreach ($f in 'accessToken', 'access_token', 'token') { if ($o.$f -is [string] -and $o.$f.Length -ge 20) { return $o.$f } }
                } catch {}
            }
            if ($plain -match 'eyJ[\w-]+\.[\w-]+\.[\w-]+') { return $Matches[0] }
            if ($AllowOpaque -and $plain -match '^[\x21-\x7e]{20,4096}$') { return $plain }
            $why += 'decrypted but no token'
        } catch { $why += $_.Exception.Message }
    }
    # Not encrypted and not a JWT: a newer opaque token, usable as-is in a Bearer header.
    if ($AllowOpaque -and $text -match '^[\x21-\x7e]{20,4096}$' -and -not ($text -match '^v1\d')) { return $text }
    $kind = if ($bytes.Length -ge 3 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 3) -match '^v1\d$') { 'v1x' } elseif ($text.StartsWith('{')) { 'json' } else { 'other' }
    throw "failed to read login for $tool נכשלה | kind=$kind len=$($bytes.Length) | $($why -join '; ')"
}
function Cursor-Checksum($machineId, $nowMs = $null) {
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
        'x-cursor-checksum'        = (Cursor-Checksum $mid)
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
        'cursor'  { @{ plan = 'pro';       windows = @{ monthly = (W 93 $n.AddDays(12).ToString('o')) } } }
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
        elseif ($s.type -eq 'cursor')  { $d = Get-Cursor }
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
