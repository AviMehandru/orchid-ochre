<#
.SYNOPSIS
    Ask yt-dlp what a URL actually is, and print the answer as JSON.
    Downloads nothing and writes nothing to the archive.

.DESCRIPTION
    This is the query half of the pipeline. `run_ytdlp.ps1` answers "get me
    this"; this answers "what is this", and it is the only file in the repo
    that runs yt-dlp without intending to keep anything.

    WHY THIS IS A PIPELINE FILE AND NOT FOUR COPIES IN FOUR FRONTENDS.
    Every consumer of this project wants the same three things before a run
    starts -- what the URL is, what formats it really has, and what is in
    the playlist -- and every one of them could get those by running
    `yt-dlp -J` itself. Four of them doing that separately would mean four
    resolutions of the deno path, four PO-token decisions, four mappings
    from yt-dlp's codec spellings onto this pipeline's `--codec` vocabulary,
    and four opinions about what `--container mp4` can actually produce for
    a given video. The last of those is the one that matters: a frontend
    that gets it wrong offers a container the merge cannot make, and the
    user finds out in the Library. So the derivation lives here, once,
    with the test suite behind it, and a frontend only has to read fields.

    WHAT IT DELIBERATELY DOES NOT DO.
    It does not touch $dataRoot at all: no folder self-heal, no session log,
    no Archive History snapshot, no `archive.txt`, no `--download-archive`.
    A probe against a URL you then decide not to download must leave the
    archive byte-for-byte as it found it, which is the same read-only
    contract `archive-viewer.py` keeps from the other direction.

    IT ALSO DOES NOT READ yt-dlp.conf, which is the one surprise in here.
    Every other yt-dlp invocation in this pipeline passes
    `--config-location $confFile`; this one passes `--ignore-config` and
    builds its own short argument list. Three reasons, in order of how
    much they would cost:

      1. The conf starts with `--update`. A GUI that probes as you type
         would trigger a yt-dlp self-update per keystroke-settled URL.
      2. The conf's `-o` templates, `--write-*` sidecar options and
         `--format` expression all describe a download. `-J` ignores most
         of them, and the ones it does not ignore only narrow the format
         list this file exists to report in full.
      3. The conf's retry and backoff tuning is set for a download worth
         waiting an hour for. A probe that a user is watching should fail
         in seconds and say so.

    What it DOES share with a real run is the part that changes the
    answer: the PO token provider, and therefore the player clients yt-dlp
    extracts with. A probe run on default clients can report a thinner
    format table than the download will actually get, which would make the
    preview lie in the one direction a preview must not.

.PARAMETER Url
    The URL, exactly as `ytdl` received it. Single video, playlist or
    channel -- yt-dlp's extractor tells them apart, nothing here does.

.PARAMETER PlaylistItems
    yt-dlp's own --playlist-items syntax, narrowing which entries are
    enumerated. Reuses `ytdl --items` rather than inventing a probe-only
    option, so "show me entries 200-260 of this channel" is the flag the
    user already knows.

.PARAMETER MaxEntries
    Enumeration ceiling, applied when -PlaylistItems does not already cap
    it. A channel with 4,000 uploads must not turn a preview into a
    two-minute hang, so the list is truncated and `entries_truncated` says
    so -- which is a fact the frontend can show, rather than a silence it
    has to guess at.

.OUTPUTS
    ONE JSON document on stdout and nothing else, or nothing on stdout and
    a message on stderr with a non-zero exit. That "or" is the contract:
    a consumer decides whether the probe worked by whether it got parseable
    JSON, so no progress line, no warning and no log message may ever go to
    stdout from here. Everything chatty goes to stderr on purpose.
#>

param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $false)][string]$PlaylistItems = "",
    [Parameter(Mandatory = $false)][ValidateRange(1, 10000)][int]$MaxEntries = 500,
    [Parameter(Mandatory = $false)][ValidateRange(1024, 65535)][int]$PotPort = 4416,
    [Parameter(Mandatory = $false)][switch]$NoPot,
    # The connection options a probe honours, because each changes what
    # yt-dlp can SEE: a members-only video, a geo-blocked one, the Premium
    # bitrate formats. A preview taken without them would describe a
    # different video from the one the download gets -- the one direction
    # a preview must not be wrong in. --limit-rate and --downloader are
    # refused by ytdl.ps1 before this script is reached; a probe moves no
    # media bytes for them to govern.
    [Parameter(Mandatory = $false)][string]$CookiesFromBrowser = "",
    [Parameter(Mandatory = $false)][string]$CookiesFile = "",
    [Parameter(Mandatory = $false)][string]$Proxy = "",
    [Parameter(Mandatory = $false)][string]$YtdlpArgsB64 = ""
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# The version of the JSON shape below. Bumped when a field is removed or
# changes meaning -- NOT when one is added, for the same reason
# $ArchiveLayoutVersion is not bumped for an added manifest field. A
# consumer that reads this and finds a number it does not know should say
# so rather than guess, which is why it is the first field emitted.
$ProbeVersion = 1

# Everything on this channel is for a human reading a terminal or a
# frontend reading a log. stdout belongs to the JSON document alone.
function Write-Note { param([string]$m) [Console]::Error.WriteLine($m) }
function Fail {
    param([string]$m)
    [Console]::Error.WriteLine("ERROR: $m")
    exit 1
}

# =====================================================================
# PLATFORM RESOLUTION
# =====================================================================
# A deliberate, narrow duplicate of the corresponding block in
# run_ytdlp.ps1 -- the install-root default and the deno candidate list.
# ytdl.ps1 already duplicates the first of those and says why: a file that
# has to find the pipeline cannot ask the pipeline where it is.
#
# The duplication is not left to good intentions. `085-probe` asserts that
# this file's $denoCandidates and default install roots agree with
# run_ytdlp.ps1's, per platform, so adding a deno location to one and not
# the other fails the suite instead of producing a probe that silently
# extracts worse than the download does.
if ($IsWindows) {
    $defaultInstallRoot = "C:/yt-dlp"
    $denoCandidates = @(
        (Join-Path $HOME ".deno/bin/deno.exe"),
        (Join-Path $HOME ".local/bin/deno.exe")
    )
} elseif ($IsMacOS) {
    $defaultInstallRoot = Join-Path $HOME "yt-dlp"
    $denoCandidates = @(
        (Join-Path $HOME ".local/bin/deno"),
        (Join-Path $HOME ".deno/bin/deno"),
        "/opt/homebrew/bin/deno",
        "/usr/local/bin/deno"
    )
} else {
    $defaultInstallRoot = Join-Path $HOME "yt-dlp"
    $denoCandidates = @(
        (Join-Path $HOME ".local/bin/deno"),
        (Join-Path $HOME ".deno/bin/deno")
    )
}

$installRoot = if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    $defaultInstallRoot
} else {
    $env:YTDLP_INSTALL_ROOT
}
$scriptsRoot = Join-Path $installRoot "scripts"

$denoPath = $denoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $denoPath) {
    $denoCommand = Get-Command deno -ErrorAction SilentlyContinue
    if ($denoCommand) { $denoPath = $denoCommand.Source }
}
$jsRuntimeArgs = @(if ($denoPath) { @("--js-runtimes", "deno:$denoPath") } else { @() })

if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
    Fail "yt-dlp is not on PATH. Run setup.sh / setup.ps1, or add its install directory to PATH."
}

# =====================================================================
# PO TOKEN PREFLIGHT
# =====================================================================
# Same provider, same clients, same degraded-mode semantics as a real
# session -- because the whole point of probing is to see what the
# download will see.
#
# One difference, and it is deliberate: -SkipUpdate is ALWAYS passed. A
# probe is a question, and a question must not install or upgrade a
# provider as a side effect. If the provider is not there, the probe runs
# degraded, says so in the `pot` object, and the frontend can show that
# the format table may be thinner than a real run would get.
$potArgs   = @()
$potOk     = $false
$potReason = "not attempted"
$potModule = Join-Path $scriptsRoot "pot-provider.ps1"

if ($NoPot) {
    $potReason = "-NoPot was passed"
} elseif (-not (Test-Path $potModule)) {
    $potReason = "pot-provider.ps1 not found at $potModule"
} else {
    try {
        . $potModule
        $potResult = Initialize-PotProvider -ProviderPort $PotPort -SkipUpdate -Log {
            param($m) [Console]::Error.WriteLine("  [pot] $m")
        }
        # @() for the same reason run_ytdlp.ps1 wraps this: an empty array
        # read off a pscustomobject property comes back as $null, and a
        # one-element one as a bare scalar.
        $potArgs   = @($potResult.ExtractorArgs)
        $potOk     = [bool]$potResult.Healthy
        $potReason = $potResult.Reason
    } catch {
        $potReason = "pot-provider.ps1 threw: $($_.Exception.Message)"
    }
}

# =====================================================================
# PASSTHROUGH
# =====================================================================
# `ytdl --probe --ytdlp-arg --cookies-from-browser --ytdlp-arg firefox` is
# the reason this is here at all: a URL that needs cookies to be read needs
# them to be probed too, and a preview that fails where the download would
# succeed is worse than no preview. Decoded the same way run_ytdlp.ps1
# decodes it, from the same base64 transport, for the same reason (a
# repeated or comma-joined array parameter does not survive `pwsh -File`).
#
# The layout denylist that run_ytdlp.ps1 enforces is NOT repeated here,
# and that is not an oversight: nothing this script runs writes a file, so
# there is no output location to protect. `-o` passed to a `-J` call is
# inert.
$passthroughArgs = @()
if ($YtdlpArgsB64) {
    try {
        $decodedJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($YtdlpArgsB64))
        $passthroughArgs = @($decodedJson | ConvertFrom-Json)
    } catch {
        Fail "Could not decode -YtdlpArgsB64: $($_.Exception.Message)"
    }
}

# =====================================================================
# THE TWO yt-dlp CALLS
# =====================================================================
# A probe is two questions, and asking them as one call is the obvious
# thing that does not work: `yt-dlp -J` against a channel dumps the FULL
# extraction of every video in it, which on a 4,000-upload channel is tens
# of minutes and several hundred megabytes of JSON. `--flat-playlist`
# answers "what is this and what is in it" in one round trip and reports
# no formats at all.
#
# So: flat first, always, because it is cheap and it is the call that
# tells us which kind of thing we are looking at. Then one full extraction
# -- of the video itself, or of a playlist's first entry -- for the format
# table. Two calls, bounded, regardless of how large the playlist is.

# Cookies and proxy, BEFORE the passthrough so a --ytdlp-arg --proxy still
# wins as it always did. The cookie FILE is not here: yt-dlp writes its jar
# back to that path on exit, so each call below gets a private copy of its
# own instead -- see Invoke-YtDlpJson, and New-PrivateCookieCopy in
# run_ytdlp.ps1 for the full reasoning.
if ($CookiesFromBrowser -and $CookiesFile) {
    Fail "-CookiesFromBrowser and -CookiesFile are two sources for the same thing. Pick one."
}
if ($CookiesFile -and -not (Test-Path -LiteralPath $CookiesFile -PathType Leaf)) {
    Fail "-CookiesFile: no such file: $CookiesFile"
}
$networkArgs = @()
if ($CookiesFromBrowser) { $networkArgs += @("--cookies-from-browser", $CookiesFromBrowser) }
if ($Proxy)              { $networkArgs += @("--proxy", $Proxy) }

# Retries deliberately far below the conf's. A person is watching this.
$commonArgs = @(
    "--ignore-config",
    "--no-progress",
    "--socket-timeout", "15",
    "--retries", "2",
    "--extractor-retries", "2"
) + $jsRuntimeArgs + $potArgs + $networkArgs + $passthroughArgs

# --playlist-items caps enumeration on yt-dlp's side rather than ours, so
# a 4,000-entry channel is never materialised in memory here. The user's
# own --items wins when given; otherwise the ceiling becomes "1:N+1", one
# past the cap, so the extra entry is what tells us the list was truncated
# rather than exactly $MaxEntries long.
$itemSpec = if ($PlaylistItems) { $PlaylistItems } else { "1:$($MaxEntries + 1)" }

function Invoke-YtDlpJson {
    param(
        [Parameter(Mandatory = $true)][string] $TargetUrl,
        [string[]] $ExtraArgs = @(),
        [Parameter(Mandatory = $true)][string] $What
    )

    # `--` before the URL at every call site, same as run_ytdlp.ps1: about
    # one YouTube id in thirty starts with "-" or "_", and without the
    # end-of-options marker yt-dlp binds it as an option.
    $cookieCopy = $null
    if ($CookiesFile) {
        # A private, chmod-600 copy per call, deleted in the finally below.
        $cookieCopy = Join-Path ([System.IO.Path]::GetTempPath()) ("ytdl-cookies-" + [guid]::NewGuid().ToString("N") + ".txt")
        [System.IO.File]::WriteAllBytes($cookieCopy, [byte[]]@())
        if (-not $IsWindows) { & chmod 600 -- $cookieCopy }
        [System.IO.File]::WriteAllBytes($cookieCopy, [System.IO.File]::ReadAllBytes($CookiesFile))
    }
    $cookieArgs = if ($cookieCopy) { @("--cookies", $cookieCopy) } else { @() }
    $argv = @("-J") + $commonArgs + $cookieArgs + $ExtraArgs + @("--", $TargetUrl)

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # stderr to a file rather than 2>&1: merging them would put yt-dlp's
        # warnings into the string we are about to parse as JSON, and a
        # single "WARNING: ..." line makes the whole document unparseable.
        #
        # -join is not decoration either. A native command's output arrives
        # as an ARRAY of lines, and ConvertFrom-Json's handling of an array
        # differs between PowerShell versions -- 5.1 treats each element as
        # its own document. Joining first means one string, one document,
        # the same way on every host.
        $raw = (& yt-dlp @argv 2>$errFile) -join "`n"
        $code = $LASTEXITCODE
        $stderr = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        if ($cookieCopy) { Remove-Item -LiteralPath $cookieCopy -Force -ErrorAction SilentlyContinue }
    }

    if ($code -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        # yt-dlp's own last stderr line is nearly always the useful one
        # ("Video unavailable", "Sign in to confirm your age"), and the
        # lines above it are retry noise. Reporting the whole thing would
        # bury the sentence the user needs.
        $detail = if ($stderr) {
            ($stderr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        } else {
            "yt-dlp exited $code with no output"
        }
        Fail "could not read $What -- $detail"
    }

    try {
        # -Depth matters: the default of 2 on ConvertFrom-Json's
        # counterpart is a serialisation limit, but a format object nested
        # in an entry nested in a playlist is deeper than the default
        # AsHashtable traversal is comfortable with on older pwsh builds.
        return ($raw | ConvertFrom-Json -Depth 64)
    } catch {
        Fail "yt-dlp returned something that is not JSON for $What -- $($_.Exception.Message)"
    }
}

Write-Note "Probing $Url ..."
$flat = Invoke-YtDlpJson -TargetUrl $Url `
    -ExtraArgs @("--flat-playlist", "--playlist-items", $itemSpec) -What "the URL"

$isPlaylist = ($flat._type -eq "playlist" -or $flat._type -eq "multi_video")

# =====================================================================
# FORMAT DERIVATION
# =====================================================================
# The part that exists so three frontends do not each invent it.
#
# yt-dlp's vcodec/acodec strings are extractor-level spellings with
# profile suffixes -- "avc1.640028", "vp09.00.50.08", "av01.0.08M.08",
# "mp4a.40.2", "opus". This pipeline's OWN vocabulary is the four values
# ytdl.ps1's --codec accepts and the five --audio-codec accepts. Mapping
# between them is the thing every frontend would otherwise get subtly
# wrong, most obviously by matching "av1" (which yt-dlp never emits; it is
# "av01", with a zero) or by treating "vp09" and "vp9" as different codecs.

function Get-VideoCodecFamily {
    param([string] $VCodec)
    if ([string]::IsNullOrWhiteSpace($VCodec) -or $VCodec -eq "none") { return $null }
    $c = $VCodec.ToLowerInvariant()
    if ($c.StartsWith("avc1") -or $c.StartsWith("h264")) { return "avc1" }
    if ($c.StartsWith("vp09") -or $c.StartsWith("vp9"))  { return "vp9" }
    if ($c.StartsWith("av01"))                            { return "av01" }
    # Deliberately null rather than "any": an unrecognised codec is a
    # rendition this pipeline has no --codec spelling for, and offering
    # "any" as though it were a choice the user made would be a lie.
    return $null
}

function Get-AudioCodecFamily {
    param([string] $ACodec)
    if ([string]::IsNullOrWhiteSpace($ACodec) -or $ACodec -eq "none") { return $null }
    $c = $ACodec.ToLowerInvariant()
    if ($c.StartsWith("opus"))                          { return "opus" }
    if ($c.StartsWith("mp4a") -or $c.StartsWith("aac")) { return "aac" }
    if ($c.StartsWith("mp3"))                           { return "mp3" }
    if ($c.StartsWith("flac"))                          { return "flac" }
    return $null
}

function Get-FormatSummary {
    param($Info)

    $formats = @()
    $rawFormats = @($Info.formats)

    foreach ($f in $rawFormats) {
        if (-not $f) { continue }
        # Storyboards and the "images only" pseudo-formats carry
        # vcodec=none acodec=none and a .mhtml extension; they are not
        # renditions of anything and would show up as a phantom row.
        if ($f.ext -eq "mhtml") { continue }

        $vFam = Get-VideoCodecFamily -VCodec ([string]$f.vcodec)
        $aFam = Get-AudioCodecFamily -ACodec ([string]$f.acodec)
        $hasV = ($f.vcodec -and $f.vcodec -ne "none")
        $hasA = ($f.acodec -and $f.acodec -ne "none")
        if (-not $hasV -and -not $hasA) { continue }

        # filesize is exact and usually absent; filesize_approx is yt-dlp's
        # own tbr*duration estimate. Reported separately rather than
        # collapsed into one number, so a frontend can show "~421 MB"
        # differently from "421 MB" instead of presenting a guess as fact.
        $formats += [ordered]@{
            format_id       = [string]$f.format_id
            ext             = [string]$f.ext
            vcodec          = [string]$f.vcodec
            acodec          = [string]$f.acodec
            video_family    = $vFam
            audio_family    = $aFam
            height          = if ($f.height) { [int]$f.height } else { $null }
            width           = if ($f.width)  { [int]$f.width }  else { $null }
            fps             = if ($f.fps)    { [double]$f.fps } else { $null }
            tbr             = if ($f.tbr)    { [double]$f.tbr } else { $null }
            filesize        = if ($f.filesize) { [long]$f.filesize } else { $null }
            filesize_approx = if ($f.filesize_approx) { [long]$f.filesize_approx } else { $null }
            dynamic_range   = [string]$f.dynamic_range
            format_note     = [string]$f.format_note
        }
    }

    # Two different questions, and conflating them is a real bug rather
    # than a tidiness point. "Does this format carry a video stream" is
    # what the HEIGHT list is built from; "which of this pipeline's --codec
    # values does it correspond to" is what the CODEC list is built from,
    # and the second is a strict subset of the first. A VP8 rendition has a
    # height the user can legitimately ask for and no --codec spelling at
    # all, so deriving heights from the recognised families would drop a
    # resolution the video really offers.
    $videoStreams = @($formats | Where-Object { $_.vcodec -and $_.vcodec -ne "none" })
    $audioStreams = @($formats | Where-Object { $_.acodec -and $_.acodec -ne "none" })
    $videoFormats = @($formats | Where-Object { $_.video_family })

    # Heights descending, distinct. A frontend rebuilding its Quality list
    # from this gets exactly the heights that exist and nothing else --
    # which is the whole point of the exercise, and is why "best" is not in
    # this array: "best" is a pipeline concept, always available, and
    # belongs at the top of the frontend's list unconditionally.
    $heights = @($videoStreams |
        Where-Object { $_.height -and $_.height -gt 0 } |
        ForEach-Object { $_.height } |
        Sort-Object -Unique -Descending)

    # Canonical order, NOT offer order. yt-dlp's format list ordering
    # varies with client and with its own sorting changes, and a dropdown
    # whose entries reshuffle between two probes of the same video looks
    # broken. The canonical order is the one ytdl.ps1's usage text lists.
    $videoCodecs = @(@("avc1", "vp9", "av01") |
        Where-Object { $fam = $_; ($videoFormats | Where-Object { $_.video_family -eq $fam }) })
    $audioCodecs = @(@("opus", "aac", "mp3", "flac") |
        Where-Object { $fam = $_; ($formats | Where-Object { $_.audio_family -eq $fam }) })

    # Which --container values a merge could actually produce.
    #
    # mkv is unconditional: Matroska carries every codec pair YouTube
    # serves, which is exactly why it is this pipeline's default and its
    # archival choice.
    #
    # The other two are real constraints, and getting them wrong is the
    # specific failure this whole function exists to prevent -- yt-dlp
    # cannot mux Opus into mp4 or AAC into webm, and asking it to produces
    # either a re-encode or a failed merge depending on version.
    $containers = @("mkv")
    $hasMp4Video = ($videoCodecs -contains "avc1") -or ($videoCodecs -contains "av01")
    $hasMp4Audio = ($audioCodecs -contains "aac")
    if ($hasMp4Video -and $hasMp4Audio) { $containers += "mp4" }
    $hasWebmVideo = ($videoCodecs -contains "vp9") -or ($videoCodecs -contains "av01")
    $hasWebmAudio = ($audioCodecs -contains "opus")
    if ($hasWebmVideo -and $hasWebmAudio) { $containers += "webm" }

    return [ordered]@{
        formats       = @($formats)
        heights       = @($heights)
        video_codecs  = @($videoCodecs)
        audio_codecs  = @($audioCodecs)
        containers    = @($containers)
        has_video     = ($videoStreams.Count -gt 0)
        has_audio     = ($audioStreams.Count -gt 0)
    }
}

# =====================================================================
# ASSEMBLE
# =====================================================================

$result = [ordered]@{
    probe_version = $ProbeVersion
    probed_at     = (Get-Date).ToUniversalTime().ToString("o")
    url           = $Url
    kind          = if ($isPlaylist) { "playlist" } else { "video" }
}

if ($isPlaylist) {
    $rawEntries = @($flat.entries | Where-Object { $_ })
    $truncated  = (-not $PlaylistItems) -and ($rawEntries.Count -gt $MaxEntries)
    $entries    = @()
    $index      = 0

    foreach ($e in $rawEntries) {
        $index++
        if (-not $PlaylistItems -and $index -gt $MaxEntries) { break }
        $entries += [ordered]@{
            # The 1-based position in the PLAYLIST, which is what
            # --playlist-items counts and therefore the only number a
            # frontend's tick-boxes may write back. Emitted explicitly
            # rather than left to array position, because a frontend that
            # sorts or filters the list would otherwise silently renumber
            # it and select the wrong videos.
            index     = $index
            id        = [string]$e.id
            title     = [string]$e.title
            duration  = if ($e.duration) { [double]$e.duration } else { $null }
            uploader  = [string]($e.uploader ?? $e.channel)
            url       = [string]($e.url ?? $e.webpage_url)
            thumbnail = [string]($e.thumbnails | Select-Object -Last 1 | ForEach-Object { $_.url })
        }
    }

    $result.id              = [string]$flat.id
    $result.title           = [string]$flat.title
    $result.uploader        = [string]($flat.uploader ?? $flat.channel)
    $result.channel         = [string]$flat.channel
    $result.extractor       = [string]$flat.extractor_key
    $result.entry_count     = $entries.Count
    $result.playlist_count  = if ($flat.playlist_count) { [int]$flat.playlist_count } else { $null }
    $result.entries_truncated = $truncated
    $result.items_requested = $PlaylistItems
    $result.entries         = @($entries)

    # One full extraction, of the first entry, for the format table.
    #
    # This IS an approximation and the field name says so rather than
    # hiding it: a channel can serve 4K AV1 for a recent upload and 360p
    # AVC for one from 2011. Extracting all of them is the thing that makes
    # a preview cost more than the download, so the frontend gets the first
    # entry's formats plus the id they came from, and can say "formats
    # shown are for <title>".
    if ($entries.Count -gt 0) {
        $firstUrl = $entries[0].url
        if ($firstUrl) {
            Write-Note "Reading formats from the first entry ..."
            $full = Invoke-YtDlpJson -TargetUrl $firstUrl `
                -ExtraArgs @("--no-playlist") -What "the first entry's formats"
            $summary = Get-FormatSummary -Info $full
            foreach ($k in $summary.Keys) { $result[$k] = $summary[$k] }
            $result.formats_from_id    = [string]$full.id
            $result.formats_from_title = [string]$full.title
            $result.duration           = if ($full.duration) { [double]$full.duration } else { $null }
            $result.thumbnail          = [string]$full.thumbnail
        }
    }
} else {
    # A bare video URL still went through --flat-playlist above, which for
    # a single video returns the full info dict anyway on current yt-dlp --
    # but not reliably across versions, and never with formats. So the
    # second call is unconditional here rather than conditional on whether
    # the first happened to carry what we need.
    Write-Note "Reading formats ..."
    $full = Invoke-YtDlpJson -TargetUrl $Url -ExtraArgs @("--no-playlist") -What "the video"

    $result.id           = [string]$full.id
    $result.title        = [string]$full.title
    $result.uploader     = [string]($full.uploader ?? $full.channel)
    $result.channel      = [string]$full.channel
    $result.channel_url  = [string]$full.channel_url
    $result.extractor    = [string]$full.extractor_key
    $result.duration     = if ($full.duration) { [double]$full.duration } else { $null }
    $result.upload_date  = [string]$full.upload_date
    $result.view_count   = if ($full.view_count) { [long]$full.view_count } else { $null }
    $result.like_count   = if ($full.like_count) { [long]$full.like_count } else { $null }
    $result.comment_count = if ($full.comment_count) { [long]$full.comment_count } else { $null }
    $result.live_status  = [string]$full.live_status
    $result.availability = [string]$full.availability
    $result.age_limit    = if ($full.age_limit) { [int]$full.age_limit } else { 0 }
    $result.thumbnail    = [string]$full.thumbnail
    $result.description  = [string]$full.description
    $result.webpage_url  = [string]$full.webpage_url
    $result.entry_count  = 1
    $result.entries      = @()
    $result.entries_truncated = $false

    # Which subtitle languages exist, reported but not selectable: the
    # pipeline's conf hardcodes en.* and changing that is a pipeline
    # change, not a GUI one. A preview that shows the video has 30
    # subtitle tracks and the archive will take one of them is honest;
    # a picker here would imply a choice that does not exist yet.
    $result.subtitle_langs =
        @(if ($full.subtitles) { $full.subtitles.PSObject.Properties.Name } else { @() })
    $result.automatic_caption_langs =
        @(if ($full.automatic_captions) { $full.automatic_captions.PSObject.Properties.Name } else { @() })

    $summary = Get-FormatSummary -Info $full
    foreach ($k in $summary.Keys) { $result[$k] = $summary[$k] }
}

$result.pot = [ordered]@{
    healthy = $potOk
    reason  = $potReason
    # Said in words rather than left to the frontend to infer from
    # `healthy`, because this is the sentence a user needs when the format
    # table looks thinner than they expected.
    note    = if ($potOk) {
        "Formats were read with the same player clients a download will use."
    } else {
        "No PO token provider: a real download may see formats this list does not show."
    }
}

# -Depth 64 for the same reason the parse above uses it: formats nested in
# entries are deeper than ConvertTo-Json's default of 2, and exceeding it
# does not error -- it silently emits the string
# "System.Collections.Hashtable" where the data should be.
$result | ConvertTo-Json -Depth 64 -Compress
exit 0
