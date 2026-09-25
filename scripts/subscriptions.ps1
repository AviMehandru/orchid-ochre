<#
.SYNOPSIS
    Subscriptions and scheduled checks: a stored list of sources, and an
    OS-native timer that downloads what is new in them.

.DESCRIPTION
    This is the file that turns `ytdl` from a command into a service. Before
    it, keeping a channel archived meant re-running `ytdl <url> --sync` by
    hand, per channel, forever: nothing stored the list of sources, nothing
    ran on a timer, and the app queues did not repeat.

    WHY THIS LIVES IN THE PIPELINE AND NOT IN THE APPS.
    Every frontend could have grown a timer of its own. Each would only fire
    while its window happened to be open -- the one time a scheduler is not
    needed -- and two of them would race each other on the same channel and
    the same manifests, which is exactly the problem every app's strictly
    sequential queue exists to avoid. So the list and the timer are here,
    once, and a frontend manages them the way it manages everything else:
    by building a `ytdl` command line. Nothing in this file knows any
    frontend exists.

    THE TIMER IS A HEARTBEAT, AND THE SCHEDULE IS DATA.
    `ytdl --schedule install` registers ONE hourly job with the operating
    system -- a systemd user timer on Linux, a launchd agent on macOS, a
    Task Scheduler task on Windows -- and that job runs
    `ytdl --run-subscriptions`, which works out for itself which
    subscriptions are due. Each subscription carries its own interval
    (every_hours) in configs/subscriptions.json. So changing an interval,
    pausing a channel or adding one never touches the operating system at
    all: the OS job is installed once and is the same text for everyone,
    which is also what makes it testable on a machine that is not the one
    it will run on.

    WHY AN OS TIMER RATHER THAN A DAEMON.
    A long-running `ytdl --daemon` would have to be started at login by
    something, restarted when it crashed, and kept from running twice --
    which is the job systemd, launchd and Task Scheduler already do, with
    catch-up after sleep (Persistent=true, launchd's coalescing,
    StartWhenAvailable) that a hand-written loop would get wrong.

    CONCURRENCY. Three locks, all under the install root:

      configs/.subscriptions.lock  Held for each read-modify-write of the
                                   list, never across a download.
      .subscriptions-run.lock      Held for the whole of a --run-subscriptions.
                                   A second runner exits 3 at once rather
                                   than queueing behind the first; the
                                   operating systems each refuse a second
                                   instance of the job too, so this is the
                                   belt to their braces, and the one that
                                   covers a hand-typed run.
      .session.lock                Held SHARED by every run_ytdlp.ps1 for
                                   its whole session. The scheduled runner
                                   tries it EXCLUSIVELY before each
                                   subscription, and if any download is
                                   running -- a terminal, an app's queue --
                                   it stops and leaves the rest due for the
                                   next heartbeat. See the note at
                                   Test-SessionIdle for what that does and
                                   does not protect.

    Scheduled sessions also log to their own file,
    Archive Logs/Logs/download.subscriptions.log, never to download.log.
    postprocess.ps1 builds each video's video_complete.log by slicing its
    session log from the most recent session-start marker, and a scheduled
    session starting while a manual one is running would otherwise hand
    the manual session's videos a log that begins in the middle of
    somebody else's run.

.NOTES
    Invoked by ytdl.ps1 -- the only parser -- with named parameters, the
    same way probe.ps1 and run_ytdlp.ps1 are. Never type these parameters
    yourself; `ytdl --help`'s Subscriptions section is the interface, and
    docs/subscriptions.md is the contract a frontend reads.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("subscribe", "list", "unsubscribe", "edit", "run", "schedule")]
    [string]$Action,

    # subscribe. Base64, because a bare video id is a legal `ytdl` URL and
    # about one in thirty starts with "-", which `pwsh -File` would bind as
    # a parameter name. ytdl.ps1's own help has the long version.
    [Parameter(Mandatory = $false)][string]$UrlB64 = "",
    # A JSON array of ytdl option tokens, base64-encoded for the array-
    # crossing reason ytdl.ps1 documents at -YtdlpArgsB64. Already
    # validated by ytdl.ps1, and already canonical: --no-audio is --mode
    # video-only by now, a cookie path is absolute, and --path is NOT in
    # here (it is -DataRoot below).
    [Parameter(Mandatory = $false)][string]$OptionsB64 = "",
    [Parameter(Mandatory = $false)][string]$DataRoot = "",

    # subscribe / edit
    [Parameter(Mandatory = $false)][ValidateRange(0, 720)][int]$EveryHours = 0,
    # The name crosses as base64 because `pwsh -File` hands a value that
    # starts with "-" to the parameter binder as a parameter NAME, and a
    # label is free text that may well start with one.
    [Parameter(Mandatory = $false)][string]$NameB64 = "",
    [Parameter(Mandatory = $false)][switch]$SetName,
    [Parameter(Mandatory = $false)][switch]$Paused,
    [Parameter(Mandatory = $false)][switch]$Resume,

    # unsubscribe / edit
    [Parameter(Mandatory = $false)][string]$Id = "",

    # run: a JSON array of ids, or ["all"]; empty means "the due ones".
    [Parameter(Mandatory = $false)][string]$IdsB64 = "",

    # list / schedule status
    [Parameter(Mandatory = $false)][switch]$Json,

    # schedule
    [Parameter(Mandatory = $false)][ValidateSet("", "install", "remove", "status")][string]$ScheduleAction = "",
    [Parameter(Mandatory = $false)][switch]$DryRun
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# The version of configs/subscriptions.json AND of the `--subscriptions
# --json` document. One number for both because the second is the first
# plus computed fields. Bumped when a field is removed or changes meaning,
# not when one is added -- the rule $ArchiveLayoutVersion and $ProbeVersion
# already follow.
$SubscriptionsVersion = 1

# Every interval is a whole number of hours, because the heartbeat is
# hourly: a 20-minute interval would be a promise the timer cannot keep.
$DefaultEveryHours = 24

# How early a subscription counts as due. The heartbeat fires on the hour
# with up to five minutes of random delay, and a subscription that last
# started at 03:04 would otherwise not be due at 03:02 the next day --
# so it would run at 04:02 instead, and drift an hour later every day. Half
# the heartbeat absorbs the jitter without ever running anything twice in
# one tick.
$DueSlackMinutes = 30

# The session log scheduled runs write to. See the header for why it is
# not download.log. ytdl.ps1 reads YTDL_SESSION_LOG and hands it to
# run_ytdlp.ps1 as -SessionLog, which validates the shape.
$ScheduledSessionLog = "download.subscriptions.log"

# Names the operating systems know the job by. The same on every machine,
# so `ytdl --schedule remove` can always find what `install` wrote.
$SystemdUnitName = "ytdl-subscriptions"
$LaunchdLabel    = "io.github.avimehandru.ytdl-subscriptions"
$TaskName        = "ytdl-subscriptions"

function Write-Err  { param([string]$m) [Console]::Error.WriteLine($m) }
function Write-Info { param([string]$m) [Console]::Out.WriteLine($m) }
function Fail {
    param([string]$m, [int]$Code = 1)
    Write-Err "Error: $m"
    exit $Code
}

# =====================================================================
# PLATFORM RESOLUTION
# =====================================================================
# The install-root default, duplicated from ytdl.ps1 for the reason
# ytdl.ps1 gives: a file that has to find the pipeline cannot ask the
# pipeline where it is. 087-subscriptions asserts the two agree.
if ($IsWindows) {
    $defaultInstallRoot = "C:/yt-dlp"
} else {
    $defaultInstallRoot = Join-Path $HOME "yt-dlp"
}
$installRoot = if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    $defaultInstallRoot
} else {
    $env:YTDLP_INSTALL_ROOT
}
$scriptsRoot     = Join-Path $installRoot "scripts"
$configsRoot     = Join-Path $installRoot "configs"
$storePath       = Join-Path $configsRoot "subscriptions.json"
$storeLockPath   = Join-Path $configsRoot ".subscriptions.lock"
$runLockPath     = Join-Path $installRoot ".subscriptions-run.lock"
$sessionLockPath = Join-Path $installRoot ".session.lock"
# The runner's own log sits with the DEFAULT data root's logs, because the
# runner belongs to the install, not to any one data root: a subscription
# with --path elsewhere writes its session log under that path, and one
# line about it here.
$runnerLogPath   = Join-Path (Join-Path (Join-Path $installRoot "Archive Logs") "Logs") "subscriptions.log"
$ytdlScript      = Join-Path $scriptsRoot "ytdl.ps1"

# The interpreter running THIS script, so the timer runs the same pwsh that
# installed it rather than whatever a PATH lookup finds at 3am in an
# environment with a different PATH. [Environment]::ProcessPath is .NET 6+,
# which every pwsh 7.2+ is.
$pwshPath = [Environment]::ProcessPath
if (-not $pwshPath) { $pwshPath = (Get-Process -Id $PID).Path }

# =====================================================================
# TIME
# =====================================================================
# Every timestamp in the store and in the JSON document is Unix seconds,
# UTC. Not ISO 8601 strings, for two reasons that each bit before being
# written down: ConvertFrom-Json turns an ISO-looking string into a local
# [datetime] on read and ConvertTo-Json writes it back with whatever offset
# the reading machine has, so a round trip through this script would move
# every timestamp; and the three apps that read this parse an integer
# identically in C, Swift and C#, which is not true of fractional seconds.
function Get-NowUnix { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Format-Ago {
    param([long]$Then, [long]$Now)
    $s = [Math]::Max(0, $Now - $Then)
    if ($s -lt 90)     { return "just now" }
    if ($s -lt 5400)   { return "$([Math]::Round($s / 60)) min ago" }
    if ($s -lt 129600) { return "$([Math]::Round($s / 3600)) h ago" }
    return "$([Math]::Round($s / 86400)) d ago"
}

function Format-In {
    param([long]$When, [long]$Now)
    $s = $When - $Now
    if ($s -le 0)      { return "now" }
    if ($s -lt 5400)   { return "in $([Math]::Max(1, [Math]::Round($s / 60))) min" }
    if ($s -lt 129600) { return "in $([Math]::Round($s / 3600)) h" }
    return "in $([Math]::Round($s / 86400)) d"
}

function Format-Every {
    param([int]$Hours)
    if ($Hours % 24 -eq 0) { return "every $($Hours / 24)d" }
    return "every $($Hours)h"
}

# =====================================================================
# LOCKS
# =====================================================================
# The same primitive postprocess.ps1's Enter-Lock uses: a file opened with
# FileShare.None. On Linux and macOS .NET implements that with flock(), so
# it is released by the kernel when the process dies -- a killed runner
# never leaves a stale lock behind, which a PID file would.
function Enter-FileLock {
    param([string]$Path, [int]$TimeoutMs = 10000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) { return $null }
            Start-Sleep -Milliseconds (Get-Random -Minimum 40 -Maximum 120)
        }
    }
}
function Exit-FileLock {
    param($Handle)
    if ($Handle) { $Handle.Dispose() }
}

# Is anything downloading right now?
#
# run_ytdlp.ps1 holds .session.lock SHARED for as long as a session runs,
# so an EXCLUSIVE open succeeds exactly when no session holds it. The open
# is released at once: this is a question, not a reservation, because the
# scheduled session about to start has to take the same lock shared.
#
# What this protects: a scheduled check never STARTS while you are
# downloading, from a terminal or from an app, so the two cannot both pick
# up the same new upload of the same channel and write the same .part file.
# What it does not: a download you start WHILE a scheduled check is
# running goes ahead, exactly as a second terminal always has. Making it
# wait would mean an app's Add button doing nothing for as long as a
# first-time check of a large channel takes, and the two sessions write
# different session logs and share only what postprocess.ps1 already locks.
function Test-SessionIdle {
    if (-not (Test-Path -LiteralPath $sessionLockPath)) { return $true }
    try {
        $probe = [System.IO.File]::Open($sessionLockPath, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $probe.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Test-RunnerBusy {
    if (-not (Test-Path -LiteralPath $runLockPath)) { return $false }
    try {
        $probe = [System.IO.File]::Open($runLockPath, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $probe.Dispose()
        return $false
    } catch {
        return $true
    }
}

# =====================================================================
# THE STORE
# =====================================================================

# One subscription, with every field present and in a fixed order. Called
# on everything read from disk, so a file written by hand or by an older
# copy of this script comes back in one known shape, and the JSON written
# out is diffable run to run.
function ConvertTo-SubscriptionRecord {
    param($s)
    $last = $null
    if ($null -ne $s.last_run) {
        $lr = $s.last_run
        $last = [ordered]@{
            started   = [long]$lr.started
            finished  = [long]$lr.finished
            # ok | errors | failed. "errors" is a session that finished
            # (exit 0) but whose summary counted ERROR lines -- usually one
            # video out of several that could not be fetched, which is
            # worth seeing and not worth calling a failure.
            result    = [string]$lr.result
            exit_code = [int]$lr.exit_code
            touched   = [int]$lr.touched
            skipped   = [int]$lr.skipped
            errors    = [int]$lr.errors
            warnings  = [int]$lr.warnings
            # schedule | manual
            trigger   = [string]$lr.trigger
            # The last line the session printed, when it failed; null
            # otherwise. Bounded, because it is shown in a list row.
            message   = if ($lr.message) { [string]$lr.message } else { $null }
        }
    }
    return [ordered]@{
        id          = [string]$s.id
        url         = [string]$s.url
        name        = if ($s.name) { [string]$s.name } else { $null }
        # [string[]] with the @() INSIDE the cast: an options list of one
        # element must stay an array through ConvertTo-Json, and an absent
        # one must become [] rather than null.
        options     = [string[]]@($s.options | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        data_root   = if ($s.data_root) { [string]$s.data_root } else { $null }
        every_hours = [int]$s.every_hours
        enabled     = [bool]$s.enabled
        added       = [long]$s.added
        updated     = [long]$s.updated
        last_run    = $last
    }
}

function Read-Store {
    if (-not (Test-Path -LiteralPath $storePath)) {
        return [ordered]@{ subscriptions_version = $SubscriptionsVersion; subscriptions = @() }
    }
    $raw = [System.IO.File]::ReadAllText($storePath)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{ subscriptions_version = $SubscriptionsVersion; subscriptions = @() }
    }
    try {
        $doc = $raw | ConvertFrom-Json
    } catch {
        # Refused rather than treated as empty. An empty list written back
        # over a file somebody hand-edited into invalid JSON would delete
        # every subscription in it, silently, the next time anything was
        # added.
        Fail "$storePath is not valid JSON ($($_.Exception.Message)). Fix or remove it; nothing has been changed."
    }
    $version = [int]$doc.subscriptions_version
    if ($version -gt $SubscriptionsVersion) {
        Fail "$storePath was written by a newer pipeline (subscriptions_version $version; this one reads $SubscriptionsVersion). Update the pipeline rather than letting an older one rewrite the file."
    }
    return [ordered]@{
        subscriptions_version = $SubscriptionsVersion
        subscriptions = @(@($doc.subscriptions) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-SubscriptionRecord $_ })
    }
}

# Written to a temporary file beside the real one and then moved over it,
# so a crash or a full disk mid-write leaves the previous list intact
# rather than a truncated one. The temporary file is chmod 600 BEFORE the
# content goes in: the list can hold a proxy password and a cookie path,
# and a window in which it sits world-readable is the window that matters.
function Write-Store {
    param($Store)
    if (-not (Test-Path -LiteralPath $configsRoot)) {
        New-Item -ItemType Directory -Path $configsRoot -Force | Out-Null
    }
    $doc = [ordered]@{
        subscriptions_version = $SubscriptionsVersion
        subscriptions = @($Store.subscriptions)
    }
    $text = ConvertTo-Json -InputObject $doc -Depth 8
    $tmp = "$storePath.tmp-$PID"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, "", $utf8NoBom)
    if (-not $IsWindows) { & chmod 600 -- $tmp }
    [System.IO.File]::WriteAllText($tmp, $text + "`n", $utf8NoBom)
    [System.IO.File]::Move($tmp, $storePath, $true)
}

# Read, change, write, under the store lock. $Mutator receives the store
# and changes it in place; whatever it returns is returned from here.
function Update-Store {
    param([scriptblock]$Mutator)
    $lock = Enter-FileLock -Path $storeLockPath -TimeoutMs 15000
    if (-not $lock) { Fail "Timed out waiting for $storeLockPath. Is another ytdl stuck while saving subscriptions?" }
    try {
        $store = Read-Store
        $result = & $Mutator $store
        Write-Store $store
        return $result
    } finally {
        Exit-FileLock $lock
    }
}

function Find-Subscription {
    param($Store, [string]$Key)
    foreach ($s in @($Store.subscriptions)) {
        if ($s.id -eq $Key) { return $s }
    }
    # A URL is accepted too, when it names exactly one subscription -- the
    # thing a person remembers is the channel, not an eight-character id.
    $byUrl = @(@($Store.subscriptions) | Where-Object { $_.url -eq $Key })
    if ($byUrl.Count -eq 1) { return $byUrl[0] }
    return $null
}

function New-SubscriptionId {
    param($Store)
    $taken = @(@($Store.subscriptions) | ForEach-Object { $_.id })
    while ($true) {
        $candidate = [guid]::NewGuid().ToString("N").Substring(0, 8)
        if ($taken -notcontains $candidate) { return $candidate }
    }
}

# A proxy's user:password@ becomes ***@ wherever the options are shown --
# in a terminal listing, in the JSON a frontend reads, in the runner log.
# The same rule ytdl.ps1 and run_ytdlp.ps1 apply to their own output.
function Hide-OptionSecrets {
    param([string[]]$Options)
    $out = @()
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $out += $Options[$i]
        if ($Options[$i] -eq "--proxy" -and $i + 1 -lt $Options.Count) {
            $out += ($Options[$i + 1] -replace '(?<=://)[^/@]*@', '***@')
            $i++
        }
    }
    # The comma keeps the array an array. Returned bare, PowerShell unrolls
    # it into the pipeline, so an empty list comes back as $null and a
    # one-element list as a bare string -- and "options": null is what a
    # frontend would then read for a subscription with no options.
    return ,([string[]]$out)
}

function Get-DisplayName {
    param($s)
    if ($s.name) { return $s.name }
    return $s.url
}

# When a subscription next comes due, as Unix seconds. Never run means now.
function Get-NextDue {
    param($s, [long]$Now)
    if ($null -eq $s.last_run -or [long]$s.last_run.started -le 0) { return $Now }
    return [long]$s.last_run.started + ([long]$s.every_hours * 3600)
}

function Test-Due {
    param($s, [long]$Now)
    if (-not $s.enabled) { return $false }
    return $Now -ge ((Get-NextDue $s $Now) - ($DueSlackMinutes * 60))
}

# =====================================================================
# >>> SCHEDULE TEXT GENERATORS
# =====================================================================
# Pure functions: everything they need comes in as a parameter and they
# return text. That is what lets 087-subscriptions assert the systemd
# units, the launchd plist and the Task Scheduler XML on ONE machine,
# rather than the macOS and Windows halves being checked only by whoever
# next installs on those platforms. The test suite extracts this region by
# its two marker comments and runs it on its own -- keep them where they
# are.

# systemd unit-file quoting. Inside double quotes a backslash and a double
# quote need a backslash; "%" is a specifier character in every directive
# and "$" is variable expansion in Exec lines, and both are doubled to be
# literal. A path with none of these comes out exactly as it went in.
function ConvertTo-SystemdQuoted {
    param([string]$Value, [switch]$Exec)
    $v = $Value.Replace('\', '\\').Replace('"', '\"').Replace('%', '%%')
    if ($Exec) { $v = $v.Replace('$', '$$') }
    return '"' + $v + '"'
}

function ConvertTo-XmlText {
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-SystemdUnitText {
    param(
        [string]$PwshPath, [string]$YtdlScript, [string]$PathValue,
        [string]$InstallRootOverride = ""
    )
    $envLines = @("Environment=" + (ConvertTo-SystemdQuoted "PATH=$PathValue"))
    if ($InstallRootOverride) {
        $envLines += "Environment=" + (ConvertTo-SystemdQuoted "YTDLP_INSTALL_ROOT=$InstallRootOverride")
    }
    $exec = "ExecStart=" + ((@($PwshPath, "-NoProfile", "-File", $YtdlScript, "--run-subscriptions") |
        ForEach-Object { ConvertTo-SystemdQuoted $_ -Exec }) -join " ")
    $service = @(
        "# Written by ``ytdl --schedule install``. Remove it with"
        "# ``ytdl --schedule remove``, which disables the timer as well."
        "[Unit]"
        "Description=ytdl: download what is new in your subscriptions"
        "Documentation=https://github.com/AviMehandru/orchid-ochre/blob/main/docs/subscriptions.md"
        ""
        "[Service]"
        # oneshot: the unit is "activating" for as long as the check runs,
        # and a timer never starts a unit that is still activating -- so a
        # check that takes longer than an hour is not joined by a second.
        "Type=oneshot"
        # PATH is the one captured when `--schedule install` ran. A user
        # manager's own PATH lacks ~/.local/bin, which is where setup put
        # yt-dlp and deno, so without this every scheduled run would fail
        # to find yt-dlp.
    ) + $envLines + @(
        $exec
        # A background job should give way to whatever you are doing.
        "Nice=10"
    )
    $timer = @(
        "# Written by ``ytdl --schedule install``."
        "[Unit]"
        "Description=ytdl: check subscriptions every hour"
        ""
        "[Timer]"
        "OnCalendar=hourly"
        # Up to five minutes of jitter, so a machine that is also running
        # other hourly jobs does not start them all in the same second.
        "RandomizedDelaySec=300"
        # A check missed while the machine was off runs once at boot,
        # rather than waiting for the next hour.
        "Persistent=true"
        ""
        "[Install]"
        "WantedBy=timers.target"
    )
    return [pscustomobject]@{
        Service = ($service -join "`n") + "`n"
        Timer   = ($timer -join "`n") + "`n"
    }
}

function Get-LaunchdPlistText {
    param(
        [string]$Label, [string]$PwshPath, [string]$YtdlScript,
        [string]$PathValue, [string]$ErrorLogPath, [string]$InstallRootOverride = ""
    )
    $programArgs = @($PwshPath, "-NoProfile", "-File", $YtdlScript, "--run-subscriptions") |
        ForEach-Object { "        <string>$(ConvertTo-XmlText $_)</string>" }
    $envEntries = @(
        "        <key>PATH</key>"
        "        <string>$(ConvertTo-XmlText $PathValue)</string>"
    )
    if ($InstallRootOverride) {
        $envEntries += "        <key>YTDLP_INSTALL_ROOT</key>"
        $envEntries += "        <string>$(ConvertTo-XmlText $InstallRootOverride)</string>"
    }
    $lines = @(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        # NO DOUBLE HYPHEN in this comment, which is why it does not quote
        # the command that wrote it. "--" is illegal inside an XML comment,
        # a plist is XML, and launchctl refuses a plist that does not
        # parse. It is the easiest XML mistake there is to make in a file
        # full of command-line options -- the first draft of this one made
        # it -- so 087-subscriptions parses this output to keep it out.
        '<!-- Written by the ytdl schedule install command. Remove it with the matching remove command, not by hand. -->'
        '<plist version="1.0">'
        '<dict>'
        '    <key>Label</key>'
        "    <string>$(ConvertTo-XmlText $Label)</string>"
        '    <key>ProgramArguments</key>'
        '    <array>'
    ) + $programArgs + @(
        '    </array>'
        # launchd starts agents with PATH=/usr/bin:/bin:/usr/sbin:/sbin,
        # which has neither Homebrew's ffmpeg nor ~/.local/bin's yt-dlp.
        '    <key>EnvironmentVariables</key>'
        '    <dict>'
    ) + $envEntries + @(
        '    </dict>'
        # Seconds. launchd does not start a second copy while one is still
        # running, and after sleep it runs a missed interval once, not once
        # per interval missed.
        '    <key>StartInterval</key>'
        '    <integer>3600</integer>'
        # Once at login as well, so a laptop opened in the morning checks
        # then rather than up to an hour later.
        '    <key>RunAtLoad</key>'
        '    <true/>'
        '    <key>ProcessType</key>'
        '    <string>Background</string>'
        '    <key>Nice</key>'
        '    <integer>10</integer>'
        # stdout is every line of every download, which the session logs
        # already keep. stderr is kept, because it is where pwsh says so if
        # it cannot start at all -- the one failure nothing else records.
        '    <key>StandardOutPath</key>'
        '    <string>/dev/null</string>'
        '    <key>StandardErrorPath</key>'
        "    <string>$(ConvertTo-XmlText $ErrorLogPath)</string>"
        '</dict>'
        '</plist>'
    )
    return ($lines -join "`n") + "`n"
}

function Get-TaskXmlText {
    param(
        [string]$PwshPath, [string]$YtdlScript, [string]$UserId,
        [string]$StartBoundary, [string]$InstallRootOverride = ""
    )
    # Task Scheduler cannot set an environment variable for an action, so a
    # non-default install root goes on the command line instead: -Command
    # rather than -File, setting it before the script runs. The ordinary
    # case keeps -File and stays readable in the Task Scheduler UI.
    if ($InstallRootOverride) {
        $escapedRoot   = $InstallRootOverride.Replace("'", "''")
        $escapedScript = $YtdlScript.Replace("'", "''")
        $arguments = "-NoProfile -WindowStyle Hidden -Command `"`$env:YTDLP_INSTALL_ROOT='$escapedRoot'; & '$escapedScript' --run-subscriptions; exit `$LASTEXITCODE`""
    } else {
        $arguments = "-NoProfile -WindowStyle Hidden -File `"$YtdlScript`" --run-subscriptions"
    }
    $lines = @(
        '<?xml version="1.0" encoding="UTF-16"?>'
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        '  <RegistrationInfo>'
        '    <Description>Written by `ytdl --schedule install`: checks your ytdl subscriptions every hour. Remove it with `ytdl --schedule remove`.</Description>'
        '  </RegistrationInfo>'
        '  <Triggers>'
        '    <TimeTrigger>'
        '      <Repetition>'
        '        <Interval>PT1H</Interval>'
        '        <StopAtDurationEnd>false</StopAtDurationEnd>'
        '      </Repetition>'
        "      <StartBoundary>$(ConvertTo-XmlText $StartBoundary)</StartBoundary>"
        '      <RandomDelay>PT5M</RandomDelay>'
        '      <Enabled>true</Enabled>'
        '    </TimeTrigger>'
        '  </Triggers>'
        '  <Principals>'
        '    <Principal id="Author">'
        "      <UserId>$(ConvertTo-XmlText $UserId)</UserId>"
        # Runs as you, only while you are signed in, with no stored
        # password. "Whether signed in or not" would need your password
        # saved in Task Scheduler, which this will not ask for.
        '      <LogonType>InteractiveToken</LogonType>'
        '      <RunLevel>LeastPrivilege</RunLevel>'
        '    </Principal>'
        '  </Principals>'
        '  <Settings>'
        # A check still running an hour later is left alone, not joined.
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        # A check missed while the machine was off runs as soon as it can.
        '    <StartWhenAvailable>true</StartWhenAvailable>'
        '    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>'
        # The default limit is 72 hours, after which Task Scheduler KILLS
        # the task. The first check of a large channel can outlast that.
        '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'
        '    <Priority>7</Priority>'
        '    <Enabled>true</Enabled>'
        '  </Settings>'
        '  <Actions Context="Author">'
        '    <Exec>'
        "      <Command>$(ConvertTo-XmlText $PwshPath)</Command>"
        "      <Arguments>$(ConvertTo-XmlText $arguments)</Arguments>"
        '    </Exec>'
        '  </Actions>'
        '</Task>'
    )
    return ($lines -join "`r`n") + "`r`n"
}

# The PATH a scheduled run gets: the one `--schedule install` was run with,
# plus the directories setup installs into, when they exist and are not
# already on it. The additions matter when install was run from an app
# started by a desktop session whose PATH never read ~/.bashrc.
function Get-SchedulePathValue {
    param([string]$CurrentPath, [string[]]$Extra)
    $sep = [System.IO.Path]::PathSeparator
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($CurrentPath -split [regex]::Escape([string]$sep))) {
        if ($p -and -not $parts.Contains($p)) { $parts.Add($p) }
    }
    foreach ($p in $Extra) {
        if ($p -and -not $parts.Contains($p)) { $parts.Add($p) }
    }
    return ($parts -join $sep)
}
# =====================================================================
# <<< SCHEDULE TEXT GENERATORS
# =====================================================================

# =====================================================================
# THE SCHEDULE, PER PLATFORM
# =====================================================================

function Get-ScheduleMechanism {
    if ($IsWindows) { return "task-scheduler" }
    if ($IsMacOS)   { return "launchd" }
    return "systemd"
}

function Get-SystemdUnitDir {
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
    return Join-Path (Join-Path $base "systemd") "user"
}

function Get-LaunchdPlistPath {
    return Join-Path (Join-Path (Join-Path $HOME "Library") "LaunchAgents") "$LaunchdLabel.plist"
}

function Get-ExtraPathDirs {
    $dirs = @((Join-Path $HOME ".local/bin"), (Join-Path $HOME ".deno/bin"))
    if ($IsMacOS) { $dirs += @("/opt/homebrew/bin", "/usr/local/bin") }
    return @($dirs | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-InstallRootOverride {
    if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) { return "" }
    return [System.IO.Path]::GetFullPath($env:YTDLP_INSTALL_ROOT)
}

# Runs a native command and returns its output and exit code without
# letting a failure throw. The schedule commands are expected to fail in
# ordinary ways -- "is-active" exits 3 for an inactive unit -- and each
# caller decides what a non-zero exit means.
function Invoke-Quiet {
    param([string]$Command, [string[]]$Arguments)
    try {
        $out = & $Command @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Output = @($out); ExitCode = $LASTEXITCODE }
    } catch {
        return [pscustomobject]@{ Output = @("$($_.Exception.Message)"); ExitCode = 127 }
    }
}

function Get-ScheduleStatus {
    $mechanism = Get-ScheduleMechanism
    $status = [ordered]@{
        mechanism  = $mechanism
        # Whether this platform's scheduler could be reached at all. False
        # on a Linux machine with no systemd user session (WSL1, a
        # container, a login over ssh with no user manager).
        supported  = $true
        installed  = $false
        active     = $false
        # A --run-subscriptions is in progress right now, scheduled or not.
        running    = (Test-RunnerBusy)
        # Unix seconds, or null when the scheduler does not say.
        next_check = $null
        # Linux only: whether the user manager outlives your login. When
        # false, checks run only while you are logged in. Null elsewhere.
        linger     = $null
        # One line a person can read. Always set.
        detail     = ""
    }

    if ($mechanism -eq "systemd") {
        $unitDir = Get-SystemdUnitDir
        $timerPath = Join-Path $unitDir "$SystemdUnitName.timer"
        $status.installed = Test-Path -LiteralPath $timerPath
        if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) {
            $status.supported = $false
            $status.detail = "systemctl is not on PATH, so there is no systemd user session to schedule with."
            return $status
        }
        $active = Invoke-Quiet systemctl @("--user", "is-active", "$SystemdUnitName.timer")
        if (($active.Output -join " ") -match 'Failed to connect to bus|No medium found|not been booted with systemd') {
            $status.supported = $false
            $status.detail = "No systemd user session is reachable: $($active.Output -join ' ')"
            return $status
        }
        $status.active = ($active.ExitCode -eq 0)
        if ($status.active) {
            # --timestamp=unix prints "@1790003600" (systemd 248+). Older
            # systemd prints a local-time string instead, which is left as
            # "unknown" rather than parsed against a guessed locale.
            $show = Invoke-Quiet systemctl @("--user", "show", "$SystemdUnitName.timer", "-p", "NextElapseUSecRealtime", "--timestamp=unix")
            if (($show.Output -join "`n") -match 'NextElapseUSecRealtime=@(\d+)') {
                $status.next_check = [long]$Matches[1]
            }
        }
        $userName = (Invoke-Quiet id @("-un")).Output | Select-Object -First 1
        if ($userName) {
            $linger = Invoke-Quiet loginctl @("show-user", $userName, "-p", "Linger", "--value")
            if ($linger.ExitCode -eq 0) { $status.linger = (($linger.Output -join "") -match '^\s*yes\s*$') }
        }
        $status.detail = if ($status.active) {
            "systemd user timer $SystemdUnitName.timer, hourly"
        } elseif ($status.installed) {
            "systemd user timer installed but not active -- run ``ytdl --schedule install`` again"
        } else {
            "not installed"
        }
        if ($status.active -and $status.linger -eq $false) {
            $status.detail += "; runs only while you are logged in (``loginctl enable-linger`` changes that)"
        }
        return $status
    }

    if ($mechanism -eq "launchd") {
        $plist = Get-LaunchdPlistPath
        $status.installed = Test-Path -LiteralPath $plist
        $uid = (Invoke-Quiet id @("-u")).Output | Select-Object -First 1
        $print = Invoke-Quiet launchctl @("print", "gui/$uid/$LaunchdLabel")
        $status.active = ($print.ExitCode -eq 0)
        $status.detail = if ($status.active) { "launchd agent $LaunchdLabel, hourly" }
                         elseif ($status.installed) { "launchd agent installed but not loaded -- run ``ytdl --schedule install`` again" }
                         else { "not installed" }
        return $status
    }

    # Windows
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    } catch {
        $task = $null
    }
    if ($task) {
        $status.installed = $true
        $status.active = ("$($task.State)" -ne "Disabled")
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
            if ($info.NextRunTime -and $info.NextRunTime.Year -gt 2000) {
                $status.next_check = ([DateTimeOffset]$info.NextRunTime).ToUnixTimeSeconds()
            }
        } catch { }
        $status.detail = if ($status.active) { "Task Scheduler task \$TaskName, hourly while you are signed in" }
                         else { "Task Scheduler task \$TaskName is disabled" }
    } else {
        $status.detail = "not installed"
    }
    return $status
}

function Install-Schedule {
    $mechanism = Get-ScheduleMechanism
    $override = Get-InstallRootOverride
    $pathValue = Get-SchedulePathValue -CurrentPath $env:PATH -Extra (Get-ExtraPathDirs)

    if (-not (Test-Path -LiteralPath $ytdlScript)) {
        Fail "$ytdlScript is not installed. Run setup first -- the schedule runs the installed ytdl, not this copy."
    }

    if ($mechanism -eq "systemd") {
        $units = Get-SystemdUnitText -PwshPath $pwshPath -YtdlScript $ytdlScript -PathValue $pathValue -InstallRootOverride $override
        $unitDir = Get-SystemdUnitDir
        $servicePath = Join-Path $unitDir "$SystemdUnitName.service"
        $timerPath   = Join-Path $unitDir "$SystemdUnitName.timer"
        if ($DryRun) {
            Write-Info "Would write $servicePath`:"; Write-Info $units.Service
            Write-Info "Would write $timerPath`:";   Write-Info $units.Timer
            Write-Info "Would run: systemctl --user daemon-reload"
            Write-Info "Would run: systemctl --user enable --now $SystemdUnitName.timer"
            return 0
        }
        if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) {
            Fail "systemctl is not on PATH, so there is no systemd user session to schedule with. Add this line with ``crontab -e`` instead:`n  0 * * * * '$pwshPath' -NoProfile -File '$ytdlScript' --run-subscriptions"
        }
        New-Item -ItemType Directory -Path $unitDir -Force | Out-Null
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($servicePath, $units.Service, $utf8NoBom)
        [System.IO.File]::WriteAllText($timerPath, $units.Timer, $utf8NoBom)
        $reload = Invoke-Quiet systemctl @("--user", "daemon-reload")
        $enable = if ($reload.ExitCode -eq 0) { Invoke-Quiet systemctl @("--user", "enable", "--now", "$SystemdUnitName.timer") } else { $reload }
        if ($enable.ExitCode -ne 0) {
            # Take the files away again rather than leave a unit that looks
            # installed to --schedule status and never fires.
            Remove-Item -LiteralPath $servicePath, $timerPath -Force -ErrorAction SilentlyContinue
            Fail "systemd refused the timer: $($enable.Output -join ' '). If there is no user session here (WSL1, a container, ssh without lingering), add this line with ``crontab -e`` instead:`n  0 * * * * '$pwshPath' -NoProfile -File '$ytdlScript' --run-subscriptions"
        }
        Write-Info "Scheduled: $SystemdUnitName.timer checks your subscriptions every hour."
        $st = Get-ScheduleStatus
        if ($st.linger -eq $false) {
            Write-Info "Note: systemd stops your user timers when you log out. To keep checking while logged out, run:  loginctl enable-linger $((Invoke-Quiet id @('-un')).Output | Select-Object -First 1)"
        }
        return 0
    }

    if ($mechanism -eq "launchd") {
        $plistPath = Get-LaunchdPlistPath
        $errLog = Join-Path (Split-Path $runnerLogPath -Parent) "subscriptions.launchd.err.log"
        $text = Get-LaunchdPlistText -Label $LaunchdLabel -PwshPath $pwshPath -YtdlScript $ytdlScript `
                                     -PathValue $pathValue -ErrorLogPath $errLog -InstallRootOverride $override
        $uid = (Invoke-Quiet id @("-u")).Output | Select-Object -First 1
        if ($DryRun) {
            Write-Info "Would write $plistPath`:"; Write-Info $text
            Write-Info "Would run: launchctl bootout gui/$uid/$LaunchdLabel   (if already loaded)"
            Write-Info "Would run: launchctl bootstrap gui/$uid $plistPath"
            return 0
        }
        New-Item -ItemType Directory -Path (Split-Path $plistPath -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $errLog -Parent) -Force | Out-Null
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($plistPath, $text, $utf8NoBom)
        # bootout first so a second install replaces the loaded copy rather
        # than failing with "service already loaded". Its failure when
        # nothing was loaded is the expected case and is ignored.
        Invoke-Quiet launchctl @("bootout", "gui/$uid/$LaunchdLabel") | Out-Null
        $boot = Invoke-Quiet launchctl @("bootstrap", "gui/$uid", $plistPath)
        if ($boot.ExitCode -ne 0) {
            Remove-Item -LiteralPath $plistPath -Force -ErrorAction SilentlyContinue
            Fail "launchctl refused the agent: $($boot.Output -join ' ')"
        }
        Write-Info "Scheduled: the launchd agent $LaunchdLabel checks your subscriptions every hour, and once at login."
        Write-Info "macOS may show a 'Background Items Added' notice naming pwsh; that is this agent."
        return 0
    }

    # Windows. The trigger starts at the top of the next hour, so checks
    # land on the hour like the other two platforms rather than at
    # whatever minute install happened to run.
    $next = (Get-Date).AddHours(1)
    $startBoundary = (Get-Date -Year $next.Year -Month $next.Month -Day $next.Day -Hour $next.Hour -Minute 0 -Second 0).ToString("yyyy-MM-dd'T'HH:mm:ss")
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $xml = Get-TaskXmlText -PwshPath $pwshPath -YtdlScript $ytdlScript -UserId $userId `
                           -StartBoundary $startBoundary -InstallRootOverride $override
    if ($DryRun) {
        Write-Info "Would register the Task Scheduler task \$TaskName`:"; Write-Info $xml
        return 0
    }
    try {
        Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force -ErrorAction Stop | Out-Null
    } catch {
        Fail "Task Scheduler refused the task: $($_.Exception.Message)"
    }
    Write-Info "Scheduled: the Task Scheduler task \$TaskName checks your subscriptions every hour while you are signed in."
    Write-Info "A console window may flash briefly when it starts; that is pwsh starting hidden."
    return 0
}

function Remove-Schedule {
    $mechanism = Get-ScheduleMechanism
    if ($mechanism -eq "systemd") {
        $unitDir = Get-SystemdUnitDir
        $servicePath = Join-Path $unitDir "$SystemdUnitName.service"
        $timerPath   = Join-Path $unitDir "$SystemdUnitName.timer"
        if ($DryRun) {
            Write-Info "Would run: systemctl --user disable --now $SystemdUnitName.timer"
            Write-Info "Would remove $servicePath and $timerPath"
            Write-Info "Would run: systemctl --user daemon-reload"
            return 0
        }
        if (-not (Test-Path -LiteralPath $timerPath) -and -not (Test-Path -LiteralPath $servicePath)) {
            Write-Info "No schedule is installed; nothing to remove."
            return 0
        }
        if (Get-Command systemctl -ErrorAction SilentlyContinue) {
            Invoke-Quiet systemctl @("--user", "disable", "--now", "$SystemdUnitName.timer") | Out-Null
        }
        Remove-Item -LiteralPath $servicePath, $timerPath -Force -ErrorAction SilentlyContinue
        if (Get-Command systemctl -ErrorAction SilentlyContinue) {
            Invoke-Quiet systemctl @("--user", "daemon-reload") | Out-Null
        }
        Write-Info "Removed the schedule. Subscriptions are kept; ``ytdl --run-subscriptions`` still checks them by hand."
        return 0
    }
    if ($mechanism -eq "launchd") {
        $plistPath = Get-LaunchdPlistPath
        $uid = (Invoke-Quiet id @("-u")).Output | Select-Object -First 1
        if ($DryRun) {
            Write-Info "Would run: launchctl bootout gui/$uid/$LaunchdLabel"
            Write-Info "Would remove $plistPath"
            return 0
        }
        if (-not (Test-Path -LiteralPath $plistPath)) {
            Write-Info "No schedule is installed; nothing to remove."
            return 0
        }
        Invoke-Quiet launchctl @("bootout", "gui/$uid/$LaunchdLabel") | Out-Null
        Remove-Item -LiteralPath $plistPath -Force -ErrorAction SilentlyContinue
        Write-Info "Removed the schedule. Subscriptions are kept; ``ytdl --run-subscriptions`` still checks them by hand."
        return 0
    }
    if ($DryRun) {
        Write-Info "Would unregister the Task Scheduler task \$TaskName"
        return 0
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Info "No schedule is installed; nothing to remove."
        return 0
    }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    } catch {
        Fail "Task Scheduler would not remove the task: $($_.Exception.Message)"
    }
    Write-Info "Removed the schedule. Subscriptions are kept; ``ytdl --run-subscriptions`` still checks them by hand."
    return 0
}

function Write-ScheduleStatusText {
    param($Status)
    $line = "Scheduled checks: $($Status.detail)"
    if ($Status.next_check) {
        $line += "; next $(Format-In $Status.next_check (Get-NowUnix))"
    }
    Write-Info $line
    if (-not $Status.installed -and $Status.supported) {
        Write-Info "  Turn them on with:  ytdl --schedule install"
    }
    if ($Status.running) {
        Write-Info "  A subscription check is running now."
    }
}

# =====================================================================
# ACTIONS
# =====================================================================

function Invoke-Subscribe {
    if (-not $UrlB64) { Fail "internal: -UrlB64 is required for subscribe" 2 }
    $Url = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($UrlB64))
    $options = @()
    if ($OptionsB64) {
        $options = @([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($OptionsB64)) | ConvertFrom-Json)
    }
    $name = $null
    if ($SetName -and $NameB64) {
        $name = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($NameB64))
    }
    $root = if ($DataRoot) { $DataRoot } else { $null }
    $now = Get-NowUnix

    $outcome = Update-Store {
        param($store)
        # Same URL and same data root is the SAME subscription, and
        # subscribing again replaces its options -- which is how a
        # subscription's options are changed at all. Keyed on the pair,
        # not the URL alone, so one channel can be subscribed twice into
        # two archives (full video to one disk, audio-only to another).
        $sameRoot = {
            param($a, $b)
            if (-not $a -and -not $b) { return $true }
            if (-not $a -or -not $b) { return $false }
            if ($IsWindows) { return [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase) }
            return $a -eq $b
        }
        $existing = @(@($store.subscriptions) | Where-Object { $_.url -eq $Url -and (& $sameRoot $_.data_root $root) })
        if ($existing.Count -gt 0) {
            $s = $existing[0]
            $s.options = [string[]]$options
            if ($EveryHours -gt 0) { $s.every_hours = $EveryHours }
            if ($SetName) { $s.name = $name }
            if ($Paused) { $s.enabled = $false }
            $s.updated = $now
            return [pscustomobject]@{ Created = $false; Record = $s }
        }
        $s = ConvertTo-SubscriptionRecord ([pscustomobject]@{
            id          = (New-SubscriptionId $store)
            url         = $Url
            name        = $name
            options     = $options
            data_root   = $root
            every_hours = if ($EveryHours -gt 0) { $EveryHours } else { $DefaultEveryHours }
            enabled     = -not $Paused
            added       = $now
            updated     = $now
            last_run    = $null
        })
        $store.subscriptions = @($store.subscriptions) + @($s)
        return [pscustomobject]@{ Created = $true; Record = $s }
    }

    $s = $outcome.Record
    $verb = if ($outcome.Created) { "Subscribed" } else { "Updated subscription" }
    $state = if ($s.enabled) { Format-Every $s.every_hours } else { "paused" }
    Write-Info "$verb $($s.id): $(Get-DisplayName $s) ($state)"
    if ($s.options.Count -gt 0) { Write-Info "  options: $((Hide-OptionSecrets $s.options) -join ' ')" }
    if ($s.data_root) { Write-Info "  into:    $($s.data_root)" }
    $st = Get-ScheduleStatus
    if (-not $st.installed -and $st.supported) {
        Write-Info "Nothing checks subscriptions on a timer yet. Turn that on with:  ytdl --schedule install"
    }
    return 0
}

function Invoke-List {
    $store = Read-Store
    $now = Get-NowUnix
    $schedule = Get-ScheduleStatus

    if ($Json) {
        # The contract in docs/subscriptions.md. Written to stdout as ONE
        # document and nothing else, the rule probe.ps1 keeps: a frontend
        # decides whether this worked by whether it got parseable JSON.
        $subs = @(@($store.subscriptions) | ForEach-Object {
            $s = $_
            $o = [ordered]@{}
            foreach ($k in $s.Keys) { $o[$k] = $s[$k] }
            $o.options  = [string[]](Hide-OptionSecrets $s.options)
            $o.next_due = if ($s.enabled) { Get-NextDue $s $now } else { $null }
            $o.due      = Test-Due $s $now
            $o
        })
        $doc = [ordered]@{
            subscriptions_version = $SubscriptionsVersion
            now                   = $now
            schedule              = $schedule
            subscriptions         = $subs
        }
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $doc -Depth 8 -Compress))
        return 0
    }

    Write-ScheduleStatusText $schedule
    $subs = @($store.subscriptions)
    if ($subs.Count -eq 0) {
        Write-Info ""
        Write-Info "No subscriptions. Add one with:"
        Write-Info "  ytdl `"https://www.youtube.com/@SomeChannel/videos`" --sync --subscribe"
        return 0
    }
    Write-Info ""
    foreach ($s in $subs) {
        $when = if (-not $s.enabled) { "paused" } else { Format-Every $s.every_hours }
        $last = if ($null -eq $s.last_run) { "never checked" } else {
            $lr = $s.last_run
            $what = switch ($lr.result) {
                "ok"     { if ($lr.touched -gt 0) { "$($lr.touched) new" } else { "nothing new" } }
                "errors" { "$($lr.touched) new, $($lr.errors) error(s)" }
                default  { "FAILED (exit $($lr.exit_code))" }
            }
            "checked $(Format-Ago $lr.started $now): $what"
        }
        $next = if ($s.enabled) { "next $(Format-In (Get-NextDue $s $now) $now)" } else { "" }
        Write-Info ("{0}  {1}" -f $s.id, (Get-DisplayName $s))
        Write-Info ("          {0} | {1}{2}" -f $when, $last, $(if ($next) { " | $next" } else { "" }))
        if ($s.name) { Write-Info "          $($s.url)" }
        if ($s.options.Count -gt 0) { Write-Info "          $((Hide-OptionSecrets $s.options) -join ' ')" }
        if ($s.data_root) { Write-Info "          into $($s.data_root)" }
        if ($s.last_run -and $s.last_run.message -and $s.last_run.result -eq "failed") {
            Write-Info "          last error: $($s.last_run.message)"
        }
    }
    return 0
}

function Invoke-Unsubscribe {
    $removed = Update-Store {
        param($store)
        $s = Find-Subscription $store $Id
        if (-not $s) { return $null }
        $store.subscriptions = @(@($store.subscriptions) | Where-Object { $_.id -ne $s.id })
        return $s
    }
    if (-not $removed) { Fail "no subscription '$Id'. ``ytdl --subscriptions`` lists them." }
    Write-Info "Unsubscribed $($removed.id): $(Get-DisplayName $removed). Everything it archived stays where it is."
    return 0
}

function Invoke-Edit {
    $name = $null
    if ($SetName -and $NameB64) {
        $name = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($NameB64))
    }
    $edited = Update-Store {
        param($store)
        $s = Find-Subscription $store $Id
        if (-not $s) { return $null }
        if ($EveryHours -gt 0) { $s.every_hours = $EveryHours }
        if ($SetName) { $s.name = $name }
        if ($Paused) { $s.enabled = $false }
        if ($Resume) { $s.enabled = $true }
        $s.updated = Get-NowUnix
        return $s
    }
    if (-not $edited) { Fail "no subscription '$Id'. ``ytdl --subscriptions`` lists them." }
    $state = if ($edited.enabled) { Format-Every $edited.every_hours } else { "paused" }
    Write-Info "Updated subscription $($edited.id): $(Get-DisplayName $edited) ($state)"
    return 0
}

function Write-RunnerLog {
    param([string]$Line)
    try {
        $dir = Split-Path $runnerLogPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        Add-Content -LiteralPath $runnerLogPath -Value "$stamp  $Line" -Encoding utf8
    } catch {
        # The runner log is a convenience. A full disk or a permissions
        # problem there must not stop a check that would otherwise work --
        # the session log is written by run_ytdlp.ps1 regardless.
    }
}

function Invoke-Run {
    $requested = @()
    if ($IdsB64) {
        $requested = @([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($IdsB64)) | ConvertFrom-Json)
    }
    $dueOnly = ($requested.Count -eq 0)
    $trigger = if ($dueOnly) { "schedule" } else { "manual" }

    $runLock = Enter-FileLock -Path $runLockPath -TimeoutMs 0
    if (-not $runLock) {
        Write-Err "[subscriptions] Another subscription check is already running; not starting a second one."
        exit 3
    }
    try {
        $store = Read-Store
        $now = Get-NowUnix
        $all = @($store.subscriptions)

        if ($dueOnly) {
            # Longest-waiting first, so a check cut short by a deferral
            # below does not keep starving the same subscriptions.
            $selected = @($all | Where-Object { Test-Due $_ $now } |
                Sort-Object -Property @{ Expression = { if ($_.last_run) { [long]$_.last_run.started } else { 0 } } })
            if ($selected.Count -eq 0) {
                Write-Info "[subscriptions] Nothing is due."
                return 0
            }
        } elseif ($requested.Count -eq 1 -and $requested[0] -eq "all") {
            $selected = @($all | Where-Object { $_.enabled })
            if ($selected.Count -eq 0) {
                Write-Info "[subscriptions] No subscriptions are enabled."
                return 0
            }
        } else {
            # Named explicitly: run them even if paused. Asking for one by
            # name is a stronger statement than having paused it earlier.
            $selected = @()
            foreach ($key in $requested) {
                $s = Find-Subscription $store $key
                if (-not $s) { Fail "no subscription '$key'. ``ytdl --subscriptions`` lists them." }
                $selected += $s
            }
        }

        $anyFailed = $false
        $index = 0
        foreach ($s in $selected) {
            $index++
            if ($dueOnly -and -not (Test-SessionIdle)) {
                $left = $selected.Count - $index + 1
                Write-Info "[subscriptions] A download is running; leaving $left due subscription(s) for the next check."
                Write-RunnerLog "deferred $left subscription(s): another ytdl session is running"
                break
            }

            Write-Info "[subscriptions] Checking $($s.id) ($index of $($selected.Count)): $(Get-DisplayName $s)"
            $childArgs = @("-NoProfile", "-File", $ytdlScript, $s.url)
            if ($s.data_root) { $childArgs += @("--path", $s.data_root) }
            $childArgs += @($s.options)

            $started = Get-NowUnix
            $summary = $null
            $lastLine = ""
            $previousLog = $env:YTDL_SESSION_LOG
            $env:YTDL_SESSION_LOG = $ScheduledSessionLog
            try {
                # Streamed line by line and passed through UNCHANGED, so a
                # frontend running this in its queue reads the same
                # "[download] NN%" lines and session summary it reads from
                # any other run. The runner's own lines are the ones
                # prefixed [subscriptions].
                & $pwshPath @childArgs 2>&1 | ForEach-Object {
                    $line = "$_"
                    if ($line -match '^-- Session summary: (\d+) video\(s\) touched, (\d+) already archived \(skipped\), (\d+) error\(s\), (\d+) warning\(s\) --') {
                        $summary = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
                    }
                    if ($line.Trim()) { $lastLine = $line.Trim() }
                    # [Console]::Out, not Write-Output: this is inside a
                    # function whose OUTPUT is its exit code, and anything
                    # written to the pipeline here would be collected into
                    # that value instead of reaching the terminal -- the
                    # whole session's output arriving at once, at the end,
                    # as the argument to `exit`.
                    [Console]::Out.WriteLine($line)
                }
                $exit = $LASTEXITCODE
            } finally {
                $env:YTDL_SESSION_LOG = $previousLog
            }
            $finished = Get-NowUnix

            $result = if ($exit -ne 0) { "failed" }
                      elseif ($summary -and $summary[2] -gt 0) { "errors" }
                      else { "ok" }
            if ($result -eq "failed") { $anyFailed = $true }
            $message = if ($result -eq "failed" -and $lastLine) {
                if ($lastLine.Length -gt 300) { $lastLine.Substring(0, 300) } else { $lastLine }
            } else { $null }

            $record = [ordered]@{
                started   = $started
                finished  = $finished
                result    = $result
                exit_code = $exit
                touched   = if ($summary) { $summary[0] } else { 0 }
                skipped   = if ($summary) { $summary[1] } else { 0 }
                errors    = if ($summary) { $summary[2] } else { 0 }
                warnings  = if ($summary) { $summary[3] } else { 0 }
                trigger   = $trigger
                message   = $message
            }
            # Re-read under the lock and write only this subscription's
            # last_run, so an edit made while the check was running -- a new
            # interval, a pause, a whole new subscription -- survives. If
            # the subscription was removed meanwhile, the result is dropped
            # with it.
            $sid = $s.id
            Update-Store {
                param($store)
                $live = Find-Subscription $store $sid
                if ($live) { $live.last_run = $record }
            } | Out-Null

            Write-RunnerLog ("{0}  {1,-6}  touched={2} skipped={3} errors={4} exit={5}  {6}" -f
                $s.id, $result, $record.touched, $record.skipped, $record.errors, $exit, $s.url)
            Write-Info "[subscriptions] $($s.id): $result"
        }
        return $(if ($anyFailed) { 1 } else { 0 })
    } finally {
        Exit-FileLock $runLock
    }
}

switch ($Action) {
    "subscribe"   { exit (Invoke-Subscribe) }
    "list"        { exit (Invoke-List) }
    "unsubscribe" { exit (Invoke-Unsubscribe) }
    "edit"        { exit (Invoke-Edit) }
    "run"         { exit (Invoke-Run) }
    "schedule" {
        switch ($ScheduleAction) {
            "install" { exit (Install-Schedule) }
            "remove"  { exit (Remove-Schedule) }
            default {
                $st = Get-ScheduleStatus
                if ($Json) {
                    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $st -Depth 4 -Compress))
                } else {
                    Write-ScheduleStatusText $st
                }
                exit 0
            }
        }
    }
}
