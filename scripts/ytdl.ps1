<#
.SYNOPSIS
    The launcher for the yt-dlp archival pipeline. One file, all platforms.

.DESCRIPTION
    This is the ONLY place the `ytdl` command line is parsed. It used to be
    the Windows half of a matched pair, with an equivalent bash parser in
    the POSIX `ytdl` script; both accepted the same seven options and both
    had to be edited, in two languages, to add or change any one of them.
    That pair is gone. `ytdl` (bash) and `ytdl.cmd` are now both thin
    shims that locate this file, hand it the command line untouched, and
    propagate its exit code -- so a command that works on one platform
    works verbatim on all three because there is literally one parser, not
    because two parsers were kept in agreement by hand.

    Everything platform-specific that remains is the install-root default
    below, and it is three lines.

.PARAMETER Url
    The YouTube URL, given as the first argument. Works identically whether
    it is a single video, a playlist, or a whole channel -- yt-dlp's own
    extractor tells them apart, not this script, so nothing here (or in
    run_ytdlp.ps1) branches on URL type.

    QUOTE IT. Every shell rewrites an unquoted URL before ytdl is started:
    zsh (macOS's default) fails outright on the "?" in watch?v=...; bash
    silently truncates at "&list=..." because "&" backgrounds the command;
    PowerShell rejects "&" as a syntax error. No amount of care inside this
    script can recover a command line the shell already changed, so the
    quotes are the fix, on every platform:

        ytdl "https://www.youtube.com/watch?v=-QMgcOSyf-o&list=PLabc"

    A leading hyphen in the URL or video id, on the other hand, IS handled
    here: YouTube ids are base64url and about one in thirty starts with "-"
    or "_", the first argument is taken as the URL even when it starts with
    a hyphen, and every yt-dlp invocation in the pipeline passes "--" ahead
    of the URL so yt-dlp cannot mistake it for an option either.

.NOTES
    Options (any order, after the URL and optional path):

      --sync            Stop as soon as an already-archived video is hit.
                        For periodic re-runs against a channel or playlist
                        you have mostly already archived.
      --items RANGE     yt-dlp's own --playlist-items syntax, e.g.
                        --items 1-20  or  --items 5,8,10-15
      --after YYYYMMDD  yt-dlp's own --dateafter, e.g. --after 20250101
      --lazy            Start downloading as videos are discovered instead
                        of enumerating the whole listing first. Mainly
                        useful on very large channels. No effect combined
                        with --workers > 1.
      --workers N       Download N videos AT THE SAME TIME instead of one
                        after another. Default 1 (unchanged behavior). See
                        run_ytdlp.ps1's own comments on -Workers for what
                        this actually does and why it is NOT the same as
                        running ytdl several times yourself in different
                        terminals -- short version: it enumerates every
                        video up front so no two workers can be assigned
                        the same one, and postprocess.ps1 has matching
                        file-locking so concurrent workers cannot corrupt
                        shared manifests. Start low (2-4) and watch
                        download.log for rate-limit warnings.
      --path PATH       Same as the legacy positional path below, as an
                        explicit flag -- use this if you also need one of
                        the options above in the same command.

    The options above only ever matter once a session covers more than one
    video; they are harmless no-ops against a single video URL.

    WHAT gets downloaded (all of these DO matter on a single video):

      --mode MODE       One of: full (default), video-only, audio-only,
                        metadata-only, comments-only, subs-only.
                        full        video+audio merged, everything else.
                        video-only  no audio stream at all.
                        audio-only  no video stream; the media file is
                                    named "Final Audio.<ext>" instead of
                                    "Final Video.<ext>" (archive layout 2).
                        metadata-only / comments-only / subs-only
                                    download no media at all. The per-video
                                    folder is still created in full, with a
                                    manifest and checksums -- just with no
                                    media file in it, so the media can be
                                    filled in by a later run.
      --quality N       Cap the video height, e.g. --quality 1080. Also
                        accepts "best" (the default, no cap).
      --codec NAME      Preferred video codec: any (default), avc1, vp9,
                        av01. A PREFERENCE, not a filter -- if the codec
                        isn't offered, the best available is still taken.
                        avc1 is the compatibility choice (plays anywhere);
                        av01 is the smallest for the same quality.
      --audio-codec N   Preferred audio codec for --mode audio-only: any
                        (default, keeps the original stream untouched),
                        opus, aac, mp3, flac. Anything but "any" re-encodes
                        via yt-dlp's audio extraction.
      --container EXT   Merge container for video: mkv (default), mp4,
                        webm. mkv is the archival choice; mp4 is the
                        compatible one. Ignored when no merge happens.
      --fps N           Frame-rate ceiling, e.g. --fps 30. The same shape
                        as --quality: a cap with a fallback, not a filter
                        that can fail. Be aware of what YouTube actually
                        publishes -- a 60 fps upload is usually offered at
                        60 fps from 720p up and 30 fps only below that, so
                        --fps 30 on such a video can mean 480p. That is
                        what "no more than 30 fps" means; it is not a bug.
      --sub-langs LIST  Which subtitle languages to fetch, replacing the
                        conf's "en.*". yt-dlp's own syntax: comma-separated
                        language codes or regexes, "all", and a leading "-"
                        to exclude, e.g. --sub-langs "en.*,de,-live_chat".
                        Works with --mode subs-only and with --refresh, so
                        a video archived with English subtitles can have
                        German added later without touching its media.
      --no-chapters     Do not embed chapter markers into the media file.
                        The chapters are still in the info.json.
      --sponsorblock-mark CATS
                        Add SponsorBlock segments as CHAPTERS -- nothing is
                        cut. CATS is a comma-separated list from: sponsor,
                        intro, outro, selfpromo, preview, filler,
                        interaction, music_offtopic, hook, poi_highlight,
                        chapter, all, default; a leading "-" excludes one,
                        e.g. --sponsorblock-mark all,-filler.
      --sponsorblock-remove CATS
                        CUT those segments out of the merged file. The same
                        category list, less poi_highlight and chapter (they
                        are points, not spans). Read this before using it
                        on an archive: the file in "Final files" is then no
                        longer the file YouTube served. --keep-video means
                        the uncut streams survive in "Pre-merge streams",
                        and the manifest's run_settings records the cut,
                        so it is never silent -- but it is a deliberate
                        departure from "keep the original bytes".

      --fps, --no-chapters and the two --sponsorblock options describe the
      media file, so each is refused with a mode that downloads none.
      --sub-langs is accepted with every mode (subtitles are written in all
      of them unless --no-subs says otherwise) and refused with --no-subs.

    Leaving a COMPONENT out (each is independent of --mode):

      --no-comments     Skip the (slow) comments pass entirely.
      --no-subs         Download no subtitles.
      --no-thumbnail    Download and embed no thumbnail.
      --no-metadata     Write no description/info.json sidecars. The
                        manifest then falls back to folder-name-derived
                        metadata, which the pipeline already handles.
      --no-audio        Alias for --mode video-only.
      --no-video        Alias for --mode audio-only.

    Filling in a video that is ALREADY archived:

      --refresh         Only with --mode metadata-only, comments-only or
                        subs-only. Says: this video is already in the
                        archive; fetch the named component AGAIN and merge
                        it into the folder that is already there.

                        Without this flag those three modes cannot touch an
                        archived video at all, and the reason is not
                        obvious. --download-archive is on by default, so
                        yt-dlp skips any id already in archive.txt -- which
                        is every video you would want to re-fetch comments
                        for. --refresh runs that one session WITHOUT
                        --download-archive, so nothing is skipped and,
                        equally important, nothing is re-recorded: the ids
                        in archive.txt are already there and stay exactly
                        as they were.

                        The second half is in postprocess.ps1. A no-media
                        mode ordinarily writes download_mode with its own
                        mode and media_file = null, which is correct for a
                        folder that mode CREATED and a lie about a folder
                        that already holds a video. Under --refresh the
                        previous manifest's download_mode and media_file
                        are carried over verbatim and the refresh is
                        recorded in a new refresh_history array instead --
                        so a full video refreshed for comments stays a full
                        video that has been refreshed, which is what it is.

                        Because the media file survives, the comment-
                        complete info.json is re-embedded into it, which a
                        plain --mode comments-only run cannot do (it has no
                        media to embed into). That is the part that makes
                        this worth more than deleting the folder and
                        downloading the video again.

                        Refused with --sync, which stops at the first
                        already-archived video and would therefore stop at
                        every video --refresh exists to reach.

    HOW the pipeline reaches YouTube (none of these change what is kept):

      --cookies-from-browser SPEC
                        Read cookies from a browser profile, in yt-dlp's
                        own syntax: BROWSER[+KEYRING][:PROFILE][::CONTAINER].
                        BROWSER is one of brave, chrome, chromium, edge,
                        firefox, opera, safari, vivaldi, whale; KEYRING one
                        of basictext, gnomekeyring, kwallet, kwallet5,
                        kwallet6. For members-only, age-restricted and
                        private videos, and for the Premium bitrate tier.
      --cookies FILE    Read cookies from a Netscape-format cookies.txt.
                        The file is never written to: yt-dlp saves its
                        cookie jar back to that path on exit, so every
                        yt-dlp process this pipeline starts is handed its
                        own private copy instead -- otherwise --workers N
                        would be N processes rewriting one file at once.
                        Cannot be combined with --cookies-from-browser
                        (yt-dlp would dump the browser's whole jar into
                        the file).
      --proxy URL       http://, https://, socks4://, socks4a://, socks5://
                        or socks5h:// (the h resolves DNS at the proxy).
                        user:password@ is accepted and is masked in every
                        log line this pipeline writes. It is NOT hidden
                        from the process list; see SECURITY.md.
      --limit-rate RATE Download speed ceiling in bytes per second, with
                        an optional K, M or G suffix: --limit-rate 2M.
                        PER yt-dlp PROCESS -- with --workers 3 the total is
                        up to three times this.
      --downloader NAME native (the default) or aria2c. aria2c must be on
                        PATH. Note that yt-dlp prints no "[download] NN%"
                        lines through an external downloader, so anything
                        that reads progress from them -- including every
                        app built on this command -- shows none.

      These reach every yt-dlp process a session starts: the download
      itself, the --workers enumeration pass, and postprocess.ps1's
      comments and Channel Info passes (--limit-rate and --downloader only
      the download). --probe accepts the cookie options and --proxy, since
      both change what yt-dlp can see; it refuses the other two. The
      manifest records WHETHER cookies were used (run_settings.cookies:
      "browser", "file" or null) and nothing else from this section --
      a cookie path or a proxy password has no business in an archive
      that may be copied somewhere else.

    Asking instead of downloading:

      --probe           Do not download anything. Print ONE JSON document
                        on stdout describing what the URL actually is:
                        title, uploader, duration, thumbnail, the real
                        format table (with this script's own --codec /
                        --audio-codec / --container vocabulary already
                        derived from it), and, for a playlist or channel,
                        the list of entries with their 1-based positions.

                        The point is that every question a frontend has to
                        answer before it can offer a sensible Quality menu
                        -- does this video have 1440p, does it have AV1,
                        can it be merged into mp4 -- is answered ONCE, by
                        the pipeline, rather than four times by four
                        consumers each running `yt-dlp -J` and each
                        mapping its codec spellings onto these flags
                        slightly differently.

                        Nothing is written: no archive, no session log, no
                        Archive History snapshot. --items narrows which
                        playlist entries are enumerated, and --no-pot /
                        --pot-port still apply because the PO token
                        provider changes which formats yt-dlp can see. The
                        options that describe a download (--path, --sync,
                        --after, --lazy, --workers, --mode, --quality,
                        --codec, --audio-codec, --container, the --no-*
                        skips) are refused rather than ignored -- a probe
                        that silently dropped --quality would read as
                        though it had honoured it.

    The escape hatch:

      --ytdlp-arg ARG   Pass ARG straight to yt-dlp, after the config file
                        so it wins. Repeatable:
                            --ytdlp-arg --match-filter --ytdlp-arg "!is_live"
                        Options that would break the archive layout (-o,
                        --paths, --exec, --config-location, --ignore-config,
                        --download-archive) are refused here rather than
                        silently producing an archive nothing can read --
                        see run_ytdlp.ps1's $BlockedPassthroughArgs.

    The second positional argument (a bare path, not starting with "--")
    is still accepted for backward compatibility: `ytdl <url> /some/path`.
    If given, it REPLACES the default data root (Archive Logs/, Youtube
    Videos/) for this run only -- the pipeline install itself (scripts/,
    configs/) always stays at the install root regardless, since the shims
    need a fixed, known location to find this file in the first place. A
    relative path is resolved to an absolute one by run_ytdlp.ps1.

.EXAMPLE
    ytdl "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

.EXAMPLE
    ytdl "https://www.youtube.com/@SomeChannel/videos" --sync --workers 3

.EXAMPLE
    ytdl "https://www.youtube.com/@SomeChannel/videos" --path "D:\Archive" --items 1-20

.EXAMPLE
    # A video id starting with a hyphen -- an ordinary base64url id, not a
    # special case you have to work around.
    ytdl "https://youtu.be/-QMgcOSyf-o"
#>

# Deliberately NOT declared with a param() block of named parameters.
# The whole point of this launcher is to accept double-dashed option
# spellings (--sync, --items, --workers), and PowerShell's own parameter
# binder would try to interpret those as its own parameters, or reject
# them outright. Taking the raw argument list and parsing it by hand is
# what lets the shims pass a command line straight through.
$ErrorActionPreference = "Stop"

# Usage and validation messages go to stderr through [Console]::Error
# rather than Write-Error. Write-Error emits a PowerShell ERROR RECORD,
# which the host renders as a multi-line block with the script name, line
# number, a caret diagram and the offending source line -- appropriate for
# an unexpected fault, absurd for "you forgot the URL". The bash launcher
# this replaces printed one clean line to stderr, and dropping to that
# noise level would have been a visible regression on every platform for
# the most common mistake a user can make. Exit codes are unchanged.
function Write-Usage {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

# Install root. Must agree with the platform block at the top of
# run_ytdlp.ps1, which reads the same environment variable and falls back
# to the same defaults, and with the two shims, which need it to find this
# file. $IsWindows and friends are pwsh 7 automatic variables and are safe
# here: this script only ever runs under pwsh 7, because that is the only
# thing either shim will start it with.
#
# Windows keeps C:\yt-dlp rather than living under the user profile
# because of MAX_PATH -- the per-video paths this pipeline builds are long
# enough that ten characters of prefix genuinely matter. See run_ytdlp.ps1.
if (-not [string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    $installRoot = $env:YTDLP_INSTALL_ROOT
} elseif ($IsWindows) {
    $installRoot = "C:/yt-dlp"
} else {
    $installRoot = Join-Path $HOME "yt-dlp"
}

$usage = @"
Usage: ytdl <youtube-url> [download-root-path] [options]

  Session:   [--sync] [--items RANGE] [--after YYYYMMDD] [--lazy]
             [--workers N] [--path PATH]
  PO token:  [--no-pot] [--skip-pot-update] [--pot-port N]
  Content:   [--mode full|video-only|audio-only|metadata-only|comments-only|subs-only]
             [--quality N|best] [--codec any|avc1|vp9|av01]
             [--audio-codec any|opus|aac|mp3|flac] [--container mkv|mp4|webm]
             [--fps N] [--sub-langs LIST] [--no-chapters]
             [--sponsorblock-mark CATS] [--sponsorblock-remove CATS]
  Skips:     [--no-comments] [--no-subs] [--no-thumbnail] [--no-metadata]
             [--no-audio] [--no-video]
  Network:   [--cookies-from-browser SPEC | --cookies FILE] [--proxy URL]
             [--limit-rate RATE] [--downloader native|aria2c]
  Re-fetch:  [--refresh]         (with --mode metadata-only|comments-only|subs-only)
  Escape:    [--ytdlp-arg ARG]   (repeatable)
  Ask only:  [--probe]           (prints JSON, downloads nothing)
"@

$argList = @($args)
if ($argList.Count -eq 0 -or [string]::IsNullOrWhiteSpace($argList[0])) {
    Write-Usage $usage
    exit 1
}

# Every option spelling the switch below accepts. The switch still needs
# its own per-option cases (each one does something different), so this is
# a mirror of that list rather than its source -- but it is a mirror with
# a test behind it: 020-launcher asserts the two agree, so adding an
# option to the switch without adding it here fails the suite rather than
# quietly leaving the guard below out of date.
$knownOptions = @("--sync", "--items", "--after", "--lazy", "--workers", "--path", "--no-pot", "--skip-pot-update", "--pot-port",
                  "--mode", "--quality", "--codec", "--audio-codec", "--container",
                  "--no-comments", "--no-subs", "--no-thumbnail", "--no-metadata", "--no-audio", "--no-video",
                  "--refresh", "--ytdlp-arg", "--probe",
                  "--fps", "--sub-langs", "--no-chapters", "--sponsorblock-mark", "--sponsorblock-remove",
                  "--cookies-from-browser", "--cookies", "--proxy", "--limit-rate", "--downloader")

# The accepted values for the four enumerated content options. Validated
# HERE, at the point the user typed them, rather than left to
# run_ytdlp.ps1's [ValidateSet] several layers down -- same reasoning as
# --workers and --pot-port below: "invalid value 'audio only' for --mode"
# beats a PowerShell parameter-binding error record naming a script the
# user did not invoke. 030-config asserts these agree with the
# [ValidateSet]s in run_ytdlp.ps1, so the two lists cannot drift.
$validModes        = @("full", "video-only", "audio-only", "metadata-only", "comments-only", "subs-only")
$validCodecs       = @("any", "avc1", "vp9", "av01")
$validAudioCodecs  = @("any", "opus", "aac", "mp3", "flac")
$validContainers   = @("mkv", "mp4", "webm")

# The external-downloader choice. Only two, on purpose: yt-dlp also knows
# curl, wget, axel and httpie, and none of them does anything for a
# YouTube DASH download that the native downloader does not already do
# better (fragment retries, the --concurrent-fragments setting in the
# conf). aria2c is on the list because it is the one people ask for by
# name. 020-launcher asserts this agrees with run_ytdlp.ps1's [ValidateSet].
$validDownloaders  = @("native", "aria2c")

# The next three lists are yt-dlp's, copied from its --help as of the
# 2026.08 releases, and they are the only lists in this file that belong
# to someone else. They are checked here anyway, for the same reason
# --codec is: yt-dlp's own error for "--cookies-from-browser firefx" is a
# Python traceback ending in "unsupported browser", arriving after the PO
# token provider has been brought up and the session log opened, and a
# GUI shows that as a failed download rather than a typo. If yt-dlp adds a
# browser, this list is the one line to change -- and until it is,
# --ytdlp-arg --cookies-from-browser still reaches yt-dlp unchecked.
$validBrowsers     = @("brave", "chrome", "chromium", "edge", "firefox", "opera", "safari", "vivaldi", "whale")
$validKeyrings     = @("basictext", "gnomekeyring", "kwallet", "kwallet5", "kwallet6")
$validSponsorCats  = @("sponsor", "intro", "outro", "selfpromo", "preview", "filler",
                       "interaction", "music_offtopic", "hook", "poi_highlight", "chapter",
                       "all", "default")
# Points in time rather than spans, so there is nothing to cut. yt-dlp
# rejects them in --sponsorblock-remove; refusing them here says why.
$sponsorPointCats  = @("poi_highlight", "chapter")

$validProxySchemes = @("http", "https", "socks4", "socks4a", "socks5", "socks5h")

# user:password@ in a proxy URL is replaced with ***@ wherever this script
# echoes the URL back -- which is only ever in an error message, but an
# error message is exactly what somebody pastes into an issue. The same
# function exists in run_ytdlp.ps1 for the session log; 020-launcher and
# 040-run-ytdlp each assert their copy.
function Hide-ProxyCredentials {
    param([string]$ProxyUrl)
    return ($ProxyUrl -replace '(?<=://)[^/@]*@', '***@')
}

# A SponsorBlock category list: comma-separated, each optionally prefixed
# with "-" to exclude it. Returns the offending token, or $null when the
# whole list is acceptable. Empty tokens ("sponsor,,intro") are refused
# rather than skipped, since they almost always mean a paste went wrong.
function Find-BadSponsorCategory {
    param([string]$List, [string[]]$Allowed)
    foreach ($token in ($List -split ',')) {
        $bare = $token.Trim()
        if ($bare.StartsWith("-")) { $bare = $bare.Substring(1) }
        if (-not $bare -or $Allowed -notcontains $bare) { return $token }
    }
    return $null
}

# The modes that download no media at all. Kept as a named list rather
# than an inline three-way -or because run_ytdlp.ps1 and postprocess.ps1
# both need the same predicate, and a fourth such mode should only have to
# be added in one place per script.
$noMediaModes = @("metadata-only", "comments-only", "subs-only")

# The first argument is the URL, INCLUDING when it starts with a hyphen.
#
# YouTube video ids are base64url, so roughly one in thirty starts with
# "-" or "_": "-QMgcOSyf-o" is an ordinary id, not a malformed one. A
# full URL built from such an id is harmless here (it starts with "h"),
# but a bare id typed on its own -- `ytdl -QMgcOSyf-o` -- is not, and
# neither is anything downstream that hands the value to yt-dlp as a bare
# positional argument. That downstream half is fixed by the `--`
# end-of-options marker now present at every yt-dlp call site (see the
# long note in run_ytdlp.ps1); this half is the rule that a leading hyphen
# does NOT by itself mean "option".
#
# Which leaves one case that must not be swallowed silently: an actual
# option in the URL's position, i.e. the user wrote the options first and
# forgot the URL. Before, `ytdl --sync https://...` took "--sync" as the
# URL and the real URL as the legacy positional download path, then
# started a doomed download into a directory named after a YouTube link --
# a wrong run rather than an error message. It is now a clean failure.
if ($knownOptions -contains $argList[0]) {
    Write-Usage "Error: the first argument must be the URL -- '$($argList[0])' is an option.`n$usage"
    exit 1
}

$url = $argList[0]

# A URL is only "funky" from a shell's point of view, and by the time this
# script runs the shell has already had its way with the command line.
# Three mangles this script CANNOT undo, because they happen before pwsh
# is even started:
#
#   zsh (the default shell on macOS) treats "?" as a glob character, so an
#   unquoted https://www.youtube.com/watch?v=... fails outright with
#   "zsh: no matches found" and ytdl never runs at all.
#
#   bash passes "?" through, but "&" -- as in "&list=PL..." or "&t=42" --
#   is a control operator: it backgrounds the command and silently
#   truncates the URL at that point, so the archive quietly gets the video
#   without the playlist.
#
#   PowerShell rejects an unquoted "&" as a syntax error.
#
# The cure for all three is the same and belongs to the user: quote the
# URL. What this script can do is notice when the argument it was handed
# does not look like a URL at all -- the usual sign that a glob expanded
# to filenames, or that a paste arrived in pieces -- and name quoting as
# the fix, instead of letting yt-dlp fail several layers down with an
# extractor error that reads like a YouTube problem.
#
# Deliberately a WARNING, not a rejection, and deliberately narrow: it
# stays quiet for anything containing "://" or a YouTube host or shaped
# like a bare 11-character video id, which covers every form that reaches
# yt-dlp intact today. Being wrong in the noisy direction costs a line of
# stderr; being wrong in the rejecting direction would break a command
# that used to work.
if ($url -notmatch '://' -and
    $url -notmatch '(?i)youtube\.com|youtu\.be' -and
    $url -notmatch '^[\w-]{11}$') {
    Write-Usage "Warning: '$url' does not look like a YouTube URL. If you pasted one, quote it -- an unquoted URL containing ? or & is rewritten by the shell before ytdl sees it. Continuing anyway."
}

# The OUTER @() here is load-bearing, not decorative. PowerShell unrolls
# the result of an if-expression through the pipeline, so a branch that
# returns a ONE-element array yields that element as a bare scalar rather
# than an array -- which makes $rest a [string], $rest[0] its first
# CHARACTER, and $rest[0].StartsWith(...) a runtime error, since
# [System.Char] has no such method. That is exactly the single-extra-
# argument case: `ytdl <url> D:\Archive`, the legacy positional path form
# this block exists to support. (An empty branch unrolls to $null for the
# same reason.) Wrapping the whole if-expression in @() forces an array in
# every branch. Caught by an actual test run, not by reading the code.
$rest = @(if ($argList.Count -gt 1) { $argList[1..($argList.Count - 1)] } else { @() })

$customPath      = ""
$breakOnExisting = $false
$playlistItems   = ""
$dateAfter       = ""
$lazyPlaylist    = $false
$workers         = ""
$noPot           = $false
$skipPotUpdate   = $false
$potPort         = ""

$mode            = ""
$quality         = ""
$codec           = ""
$audioCodec      = ""
$container       = ""
$noComments      = $false
$noSubs          = $false
$noThumbnail     = $false
$noMetadata      = $false
# --no-audio/--no-video are recorded separately from $mode rather than
# writing straight into it, so "--no-audio --mode audio-only" is caught as
# the contradiction it is instead of being resolved by whichever happened
# to be typed last.
$noAudio         = $false
$noVideo         = $false
$refresh         = $false
$ytdlpArgs       = @()
$probe           = $false

$fps                = ""
$subLangs           = ""
$noChapters         = $false
$sponsorMark        = ""
$sponsorRemove      = ""
$cookiesFromBrowser = ""
$cookiesFile        = ""
$proxy              = ""
$limitRate          = ""
$downloader         = ""

# Backward compatibility with the old positional form: if the first
# remaining argument does not start with "--", treat it as the legacy
# positional custom download-root path rather than requiring everyone to
# switch to --path immediately.
$i = 0
if ($rest.Count -gt 0 -and -not $rest[0].StartsWith("--")) {
    $customPath = $rest[0]
    $i = 1
}

while ($i -lt $rest.Count) {
    switch ($rest[$i]) {
        "--sync" {
            $breakOnExisting = $true
            $i++
        }
        "--items" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --items requires a value (e.g. --items 1-20)"; exit 1 }
            $playlistItems = $rest[$i + 1]
            $i += 2
        }
        "--after" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --after requires a value (e.g. --after 20250101)"; exit 1 }
            $dateAfter = $rest[$i + 1]
            $i += 2
        }
        "--lazy" {
            $lazyPlaylist = $true
            $i++
        }
        "--workers" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --workers requires a positive integer"; exit 1 }
            $workers = $rest[$i + 1]
            # Validated here rather than left to run_ytdlp.ps1's own
            # [ValidateRange(1,64)], so a typo produces a clear, immediate
            # message instead of a PowerShell parameter-binding error
            # several layers down.
            if ($workers -notmatch '^\d+$' -or [int]$workers -lt 1) {
                Write-Usage "Error: --workers requires a positive integer (got: '$workers')"
                exit 1
            }
            $i += 2
        }
        "--path" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --path requires a value"; exit 1 }
            $customPath = $rest[$i + 1]
            $i += 2
        }
        "--no-pot" {
            $noPot = $true
            $i++
        }
        "--skip-pot-update" {
            $skipPotUpdate = $true
            $i++
        }
        "--pot-port" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --pot-port requires a port number"; exit 1 }
            $potPort = $rest[$i + 1]
            # Same reasoning as --workers above: validated here so a typo
            # produces a clear message rather than a parameter-binding
            # error from run_ytdlp.ps1's [ValidateRange(1024,65535)].
            if ($potPort -notmatch '^\d+$' -or [int]$potPort -lt 1024 -or [int]$potPort -gt 65535) {
                Write-Usage "Error: --pot-port requires a port between 1024 and 65535 (got: '$potPort')"
                exit 1
            }
            $i += 2
        }
        # --- What gets downloaded ---
        # Each of the four enumerated options below follows the same shape:
        # require a value, check it against the list declared near
        # $knownOptions, and name the valid values in the error rather than
        # just rejecting. A typo in "--codec av1" (the real codec name in
        # yt-dlp's format fields is "av01", with a zero) is the single most
        # likely mistake here, and an error listing the four accepted
        # spellings fixes it immediately.
        "--mode" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --mode requires a value ($($validModes -join ', '))"; exit 1 }
            $mode = $rest[$i + 1]
            if ($validModes -notcontains $mode) {
                Write-Usage "Error: --mode must be one of: $($validModes -join ', ') (got: '$mode')"
                exit 1
            }
            $i += 2
        }
        "--quality" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --quality requires a height in pixels, or 'best' (e.g. --quality 1080)"; exit 1 }
            $quality = $rest[$i + 1]
            # "best" is spelled out rather than left as "omit the flag" so a
            # GUI or a saved preset always has a value to send for this
            # field, including when the user has chosen no cap.
            if ($quality -ne "best" -and ($quality -notmatch '^\d+$' -or [int]$quality -lt 1)) {
                Write-Usage "Error: --quality requires a positive height in pixels, or 'best' (got: '$quality')"
                exit 1
            }
            $i += 2
        }
        "--codec" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --codec requires a value ($($validCodecs -join ', '))"; exit 1 }
            $codec = $rest[$i + 1]
            if ($validCodecs -notcontains $codec) {
                Write-Usage "Error: --codec must be one of: $($validCodecs -join ', ') (got: '$codec'). Note av01 is spelled with a zero."
                exit 1
            }
            $i += 2
        }
        "--audio-codec" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --audio-codec requires a value ($($validAudioCodecs -join ', '))"; exit 1 }
            $audioCodec = $rest[$i + 1]
            if ($validAudioCodecs -notcontains $audioCodec) {
                Write-Usage "Error: --audio-codec must be one of: $($validAudioCodecs -join ', ') (got: '$audioCodec')"
                exit 1
            }
            $i += 2
        }
        "--container" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --container requires a value ($($validContainers -join ', '))"; exit 1 }
            $container = $rest[$i + 1]
            if ($validContainers -notcontains $container) {
                Write-Usage "Error: --container must be one of: $($validContainers -join ', ') (got: '$container')"
                exit 1
            }
            $i += 2
        }
        "--fps" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --fps requires a frame rate (e.g. --fps 30)"; exit 1 }
            $fps = $rest[$i + 1]
            # Whole numbers only. yt-dlp's fps field is a float (29.97 is
            # stored as 30 by YouTube's own metadata, but other extractors
            # report 29.97), and "<=30" already admits 29.97 -- so there is
            # nothing a fractional ceiling can express that the next whole
            # number up does not.
            if ($fps -notmatch '^\d+$' -or [int]$fps -lt 1 -or [int]$fps -gt 1000) {
                Write-Usage "Error: --fps requires a whole number of frames per second between 1 and 1000 (got: '$fps')"
                exit 1
            }
            $i += 2
        }
        "--sub-langs" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --sub-langs requires a value (e.g. --sub-langs `"en.*,de`")"; exit 1 }
            $subLangs = $rest[$i + 1]
            # yt-dlp treats each entry as a regex, so the check is only for
            # shapes that cannot be what anybody meant: an empty entry, or
            # whitespace inside one (a list typed as "en, de" would ask for
            # a language literally named " de"). Anything else -- "en.*",
            # "pt-BR", "-live_chat", "all" -- is yt-dlp's to interpret.
            $badLang = @($subLangs -split ',' | Where-Object { -not $_ -or $_ -match '\s' })
            if (-not $subLangs -or $badLang.Count -gt 0) {
                Write-Usage "Error: --sub-langs takes a comma-separated list with no spaces and no empty entries, e.g. --sub-langs `"en.*,de,-live_chat`" (got: '$subLangs')"
                exit 1
            }
            $i += 2
        }
        "--no-chapters" { $noChapters = $true; $i++ }
        "--sponsorblock-mark" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --sponsorblock-mark requires a category list (e.g. --sponsorblock-mark all)"; exit 1 }
            $sponsorMark = $rest[$i + 1]
            $bad = Find-BadSponsorCategory -List $sponsorMark -Allowed $validSponsorCats
            if ($null -ne $bad) {
                Write-Usage "Error: --sponsorblock-mark: '$bad' is not a SponsorBlock category. Use a comma-separated list from: $($validSponsorCats -join ', ') -- prefix one with '-' to exclude it."
                exit 1
            }
            $i += 2
        }
        "--sponsorblock-remove" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --sponsorblock-remove requires a category list (e.g. --sponsorblock-remove sponsor)"; exit 1 }
            $sponsorRemove = $rest[$i + 1]
            $cuttable = @($validSponsorCats | Where-Object { $sponsorPointCats -notcontains $_ })
            $bad = Find-BadSponsorCategory -List $sponsorRemove -Allowed $cuttable
            if ($null -ne $bad) {
                $why = if ($sponsorPointCats -contains $bad.Trim().TrimStart('-')) {
                    "'$bad' marks a point in the video, not a span, so there is nothing to cut -- use it with --sponsorblock-mark instead."
                } else {
                    "'$bad' is not a SponsorBlock category. Use a comma-separated list from: $($cuttable -join ', ')."
                }
                Write-Usage "Error: --sponsorblock-remove: $why"
                exit 1
            }
            $i += 2
        }

        # --- How YouTube is reached ---
        "--cookies-from-browser" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --cookies-from-browser requires a browser (e.g. --cookies-from-browser firefox)"; exit 1 }
            $cookiesFromBrowser = $rest[$i + 1]
            # BROWSER[+KEYRING][:PROFILE][::CONTAINER]. Only the two parts
            # with a closed vocabulary are checked. PROFILE is a name or a
            # path and CONTAINER is a Firefox container name; both are
            # free-form, and yt-dlp's own "could not find profile" names
            # the thing it could not find.
            if ($cookiesFromBrowser -notmatch '^(?<browser>[^+:]+)(\+(?<keyring>[^:]+))?(:.*)?$') {
                Write-Usage "Error: --cookies-from-browser takes BROWSER[+KEYRING][:PROFILE][::CONTAINER] (got: '$cookiesFromBrowser')"
                exit 1
            }
            $browserName = $Matches['browser'].ToLowerInvariant()
            $keyringName = $Matches['keyring']
            if ($validBrowsers -notcontains $browserName) {
                Write-Usage "Error: --cookies-from-browser: '$($Matches['browser'])' is not a browser yt-dlp can read. Use one of: $($validBrowsers -join ', ')"
                exit 1
            }
            if ($keyringName -and $validKeyrings -notcontains $keyringName.ToLowerInvariant()) {
                Write-Usage "Error: --cookies-from-browser: '$keyringName' is not a keyring yt-dlp knows. Use one of: $($validKeyrings -join ', ')"
                exit 1
            }
            $i += 2
        }
        "--cookies" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --cookies requires the path to a cookies.txt file"; exit 1 }
            $cookiesFile = $rest[$i + 1]
            # Checked now and resolved to an absolute path now, because the
            # file is next opened by a different process (run_ytdlp.ps1,
            # then postprocess.ps1 from inside yt-dlp's --exec) whose
            # working directory is nobody's business but its own.
            if (-not (Test-Path -LiteralPath $cookiesFile -PathType Leaf)) {
                Write-Usage "Error: --cookies: no such file: '$cookiesFile'"
                exit 1
            }
            $cookiesFile = (Resolve-Path -LiteralPath $cookiesFile).ProviderPath
            $i += 2
        }
        "--proxy" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --proxy requires a URL (e.g. --proxy socks5://127.0.0.1:1080)"; exit 1 }
            $proxy = $rest[$i + 1]
            # Scheme and a non-empty host[:port] -- nothing else. A proxy
            # URL with a path is always a paste of something else, and a
            # bare "host:port" with no scheme is the commonest mistake:
            # yt-dlp would read it as scheme "host", fail on the first
            # request, and report it as a network error.
            $schemes = ($validProxySchemes | ForEach-Object { [regex]::Escape($_) }) -join '|'
            # The host is a name, an IPv4 address or a bracketed IPv6
            # literal ([::1]) -- the brackets are the only way a colon can
            # appear in it.
            if ($proxy -notmatch "^($schemes)://([^/@\s]*@)?(\[[0-9A-Fa-f:.]+\]|[^/@\s:\[\]]+)(:\d{1,5})?/?$") {
                Write-Usage "Error: --proxy takes SCHEME://[user:password@]host[:port] with a scheme of $($validProxySchemes -join ', ') (got: '$(Hide-ProxyCredentials $proxy)')"
                exit 1
            }
            $i += 2
        }
        "--limit-rate" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --limit-rate requires a rate (e.g. --limit-rate 2M)"; exit 1 }
            $limitRate = $rest[$i + 1]
            # Bytes per second, K/M/G suffix, decimal allowed: 500K, 2M,
            # 1.5M. Upper or lower case, as yt-dlp accepts both. Zero is
            # refused -- yt-dlp would take it as "no limit", which is the
            # opposite of what someone typing a limit wanted.
            if ($limitRate -notmatch '^(?i)\d+(\.\d+)?[kmg]?$' -or [double]($limitRate -replace '(?i)[kmg]$', '') -le 0) {
                Write-Usage "Error: --limit-rate takes bytes per second with an optional K, M or G suffix, e.g. 500K or 2M (got: '$limitRate')"
                exit 1
            }
            $i += 2
        }
        "--downloader" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --downloader requires a value ($($validDownloaders -join ', '))"; exit 1 }
            $downloader = $rest[$i + 1]
            if ($validDownloaders -notcontains $downloader) {
                Write-Usage "Error: --downloader must be one of: $($validDownloaders -join ', ') (got: '$downloader')"
                exit 1
            }
            $i += 2
        }

        # --- Component skips ---
        "--no-comments"  { $noComments  = $true; $i++ }
        "--no-subs"      { $noSubs      = $true; $i++ }
        "--no-thumbnail" { $noThumbnail = $true; $i++ }
        "--no-metadata"  { $noMetadata  = $true; $i++ }
        "--no-audio"     { $noAudio     = $true; $i++ }
        "--no-video"     { $noVideo     = $true; $i++ }

        # --- Re-fetch into an existing folder ---
        "--refresh"      { $refresh     = $true; $i++ }

        # --- Passthrough ---
        # Accumulated in order and handed to run_ytdlp.ps1 as a single
        # array parameter. NOT validated for meaning here: the whole point
        # is that yt-dlp options this pipeline has never heard of still
        # work. What IS checked -- in run_ytdlp.ps1, where the list of
        # layout-critical options already lives next to the code that
        # passes them -- is that the argument is not one of the handful
        # that would redirect the output somewhere no reader can find it.
        "--ytdlp-arg" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --ytdlp-arg requires a value (e.g. --ytdlp-arg --match-filter --ytdlp-arg `"!is_live`")"; exit 1 }
            $ytdlpArgs += $rest[$i + 1]
            $i += 2
        }

        # --- Ask instead of download ---
        "--probe" {
            $probe = $true
            $i++
        }

        default {
            Write-Usage "Unknown option: $($rest[$i])`n$usage"
            exit 1
        }
    }
}

# --- Resolve the aliases, and reject the contradictions ---
# Done after the whole command line is parsed rather than inside the
# switch, so the error does not depend on the order the options were
# typed in. Every one of these is a case where continuing would produce a
# download that is quietly not what was asked for, which is the failure
# mode this pipeline works hardest to avoid.
if ($noAudio -and $noVideo) {
    Write-Usage "Error: --no-audio and --no-video together leave no media to download. Use --mode metadata-only (or comments-only / subs-only) if that is what you meant."
    exit 1
}
if ($noAudio) {
    if ($mode -and $mode -ne "video-only") {
        Write-Usage "Error: --no-audio is an alias for --mode video-only and cannot be combined with --mode $mode."
        exit 1
    }
    $mode = "video-only"
}
if ($noVideo) {
    if ($mode -and $mode -ne "audio-only") {
        Write-Usage "Error: --no-video is an alias for --mode audio-only and cannot be combined with --mode $mode."
        exit 1
    }
    $mode = "audio-only"
}

# A no-media mode plus an option that only describes media is a
# contradiction worth naming, not silently ignoring: someone who typed
# "--mode comments-only --quality 1080" has misunderstood what the mode
# does, and finding out now costs them a re-typed command instead of a
# finished run with no video in it.
if ($noMediaModes -contains $mode) {
    $mediaOnlyOpts = @()
    if ($quality -and $quality -ne "best") { $mediaOnlyOpts += "--quality" }
    if ($codec -and $codec -ne "any")      { $mediaOnlyOpts += "--codec" }
    if ($audioCodec -and $audioCodec -ne "any") { $mediaOnlyOpts += "--audio-codec" }
    if ($container)                        { $mediaOnlyOpts += "--container" }
    if ($fps)                              { $mediaOnlyOpts += "--fps" }
    if ($noChapters)                       { $mediaOnlyOpts += "--no-chapters" }
    if ($sponsorMark)                      { $mediaOnlyOpts += "--sponsorblock-mark" }
    if ($sponsorRemove)                    { $mediaOnlyOpts += "--sponsorblock-remove" }
    # --limit-rate and --downloader are deliberately NOT here. They are
    # about the connection rather than the media, and a no-media mode still
    # downloads subtitles and thumbnails through the same downloader; a
    # frontend that stores a speed limit as a setting applies it to every
    # run it starts, re-fetches included, and must not be refused for it.
    if ($mediaOnlyOpts.Count -gt 0) {
        Write-Usage "Error: --mode $mode downloads no media, so $($mediaOnlyOpts -join ' and ') cannot apply. Drop the option, or pick a mode that downloads media."
        exit 1
    }
}

# --mode comments-only with the comments pass switched off is the one
# combination that would run to completion and produce exactly nothing.
if ($mode -eq "comments-only" -and $noComments) {
    Write-Usage "Error: --mode comments-only with --no-comments would fetch nothing at all."
    exit 1
}
if ($mode -eq "subs-only" -and $noSubs) {
    Write-Usage "Error: --mode subs-only with --no-subs would fetch nothing at all."
    exit 1
}

# --- --refresh's own contract ---
# Checked here, after alias resolution, so the message names the mode the
# user ends up with rather than the one they typed. The two refusals are
# different in kind and worth separating:
#
# The mode check is about what --refresh MEANS. Merging a component into a
# folder that already exists only makes sense for the three modes that
# download no media; "--refresh --mode full" would be asking to re-download
# the video, which is what deleting the folder and running it again does,
# and pretending otherwise would leave someone with a half-replaced folder.
#
# The --sync check is about the two flags cancelling each other out.
# --sync is --break-on-existing: stop at the first video already in
# archive.txt. Every video --refresh can be pointed at is in archive.txt by
# definition, so the pair reliably produces a session that stops before
# doing anything, with a log that reads like a successful no-op.
if ($refresh) {
    if ($noMediaModes -notcontains $mode) {
        $what = if ($mode) { "--mode $mode" } else { "no --mode" }
        Write-Usage "Error: --refresh needs one of --mode $($noMediaModes -join ', ') -- it merges a re-fetched component into a folder that already exists, and $what would download media into it instead. To replace a video, remove its folder and its archive.txt line and download it again."
        exit 1
    }
    if ($breakOnExisting) {
        Write-Usage "Error: --refresh and --sync contradict each other. --sync stops at the first video already in archive.txt, and every video --refresh can reach is already in archive.txt."
        exit 1
    }
}

# --- The contradictions among the newer options ---
# Same rule as above: each is a combination that would run to the end and
# produce something other than what was asked for.
if ($subLangs -and $noSubs) {
    Write-Usage "Error: --sub-langs chooses which subtitles to fetch, and --no-subs fetches none. Drop one."
    exit 1
}
# SponsorBlock marking works by writing chapters into the file. With
# chapter embedding switched off the segments are fetched, turned into
# chapters, and then not embedded: a run that talks to one more server
# and changes nothing.
if ($sponsorMark -and $noChapters) {
    Write-Usage "Error: --sponsorblock-mark adds its segments as chapters, and --no-chapters embeds none. Drop one."
    exit 1
}
# yt-dlp would load the browser's cookies into its jar and then save that
# whole jar to the --cookies path on exit -- every cookie in the browser
# profile, for every site, written to a plain-text file. This pipeline
# hands yt-dlp a copy rather than the real path (see --cookies above),
# but the combination has no legitimate use to weigh against that.
if ($cookiesFromBrowser -and $cookiesFile) {
    Write-Usage "Error: --cookies-from-browser and --cookies are two sources for the same thing. Pick one."
    exit 1
}
# Refused now rather than left to yt-dlp, whose answer to a missing
# external downloader arrives per video, after extraction, as an error the
# session summary counts once per video in the playlist.
if ($downloader -eq "aria2c" -and -not (Get-Command aria2c -ErrorAction SilentlyContinue)) {
    Write-Usage "Error: --downloader aria2c: aria2c is not on PATH. Install it (apt install aria2 / brew install aria2 / winget install aria2.aria2) or drop the option."
    exit 1
}
if ($limitRate -and $workers -and [int]$workers -gt 1) {
    Write-Usage "Note: --limit-rate applies to each of the $workers workers separately, so the session as a whole can use up to $workers times $limitRate."
}

# --audio-codec only reaches yt-dlp in audio-only mode (it drives the
# audio-extraction postprocessor, which only runs there). Warned about
# rather than rejected: it is a no-op, not a wrong result.
if ($audioCodec -and $audioCodec -ne "any" -and $mode -ne "audio-only") {
    Write-Usage "Warning: --audio-codec only applies to --mode audio-only; ignoring it for this run."
    $audioCodec = ""
}

# --- --probe goes somewhere else entirely ---
#
# A probe is a different program with a different contract: it reads, it
# prints JSON to stdout, and it writes nothing. Dispatching to a separate
# script rather than adding a -Probe switch to run_ytdlp.ps1 is deliberate
# -- run_ytdlp.ps1 self-heals the folder tree, opens a session log and
# snapshots Archive History long before it reaches anything that could
# short-circuit, and a query that leaves those side effects behind is not
# the read-only thing the frontends were promised.
#
# The refusals below are the other half of that contract. Every option in
# the list describes what a DOWNLOAD should do, and a probe cannot honour
# any of them; accepting and ignoring one would produce a preview that
# looks like it reflects the user's settings and does not.
if ($probe) {
    $downloadOnlyOpts = @()
    if ($customPath)      { $downloadOnlyOpts += "--path" }
    if ($breakOnExisting) { $downloadOnlyOpts += "--sync" }
    if ($dateAfter)       { $downloadOnlyOpts += "--after" }
    if ($lazyPlaylist)    { $downloadOnlyOpts += "--lazy" }
    if ($workers)         { $downloadOnlyOpts += "--workers" }
    # Named as the user typed them. By this point the alias resolution
    # above has already folded --no-audio/--no-video into $mode, so
    # reporting "--mode" for a command line that never contained it would
    # send someone looking for an option they did not type.
    if ($noAudio)         { $downloadOnlyOpts += "--no-audio" }
    elseif ($noVideo)     { $downloadOnlyOpts += "--no-video" }
    elseif ($mode)        { $downloadOnlyOpts += "--mode" }
    if ($quality)         { $downloadOnlyOpts += "--quality" }
    if ($codec)           { $downloadOnlyOpts += "--codec" }
    if ($audioCodec)      { $downloadOnlyOpts += "--audio-codec" }
    if ($container)       { $downloadOnlyOpts += "--container" }
    if ($noComments)      { $downloadOnlyOpts += "--no-comments" }
    if ($noSubs)          { $downloadOnlyOpts += "--no-subs" }
    if ($noThumbnail)     { $downloadOnlyOpts += "--no-thumbnail" }
    if ($noMetadata)      { $downloadOnlyOpts += "--no-metadata" }
    # Listed here even though the --mode check above has already refused
    # every --refresh command line that could also carry --probe: the
    # refusal list is the contract, and an option missing from it is the
    # kind of gap that survives a later change to the checks above.
    if ($refresh)         { $downloadOnlyOpts += "--refresh" }
    if ($fps)             { $downloadOnlyOpts += "--fps" }
    if ($subLangs)        { $downloadOnlyOpts += "--sub-langs" }
    if ($noChapters)      { $downloadOnlyOpts += "--no-chapters" }
    if ($sponsorMark)     { $downloadOnlyOpts += "--sponsorblock-mark" }
    if ($sponsorRemove)   { $downloadOnlyOpts += "--sponsorblock-remove" }
    # The two transfer options describe how bytes are FETCHED, and a probe
    # fetches none. The cookie options and --proxy are not in this list:
    # they change what yt-dlp can SEE -- a members-only video, a
    # geo-blocked one, the Premium bitrate formats -- and a preview taken
    # without them would describe a different video from the one the
    # download gets.
    if ($limitRate)       { $downloadOnlyOpts += "--limit-rate" }
    if ($downloader)      { $downloadOnlyOpts += "--downloader" }
    if ($downloadOnlyOpts.Count -gt 0) {
        Write-Usage "Error: --probe downloads nothing, so $($downloadOnlyOpts -join ', ') cannot apply. Probe the URL first, then run it with the options you want."
        exit 1
    }

    # --skip-pot-update is not in the refusal list because the probe always
    # behaves as though it were given: a question must not install a
    # provider as a side effect. Accepting it as a harmless no-op is
    # friendlier than refusing a flag that asks for what already happens.
    $probeArgs = @("-NoProfile", "-File", (Join-Path $installRoot "scripts/probe.ps1"), "-Url", $url)
    if ($playlistItems) { $probeArgs += @("-PlaylistItems", $playlistItems) }
    if ($noPot)         { $probeArgs += "-NoPot" }
    if ($potPort)       { $probeArgs += @("-PotPort", $potPort) }
    if ($cookiesFromBrowser) { $probeArgs += @("-CookiesFromBrowser", $cookiesFromBrowser) }
    if ($cookiesFile)        { $probeArgs += @("-CookiesFile", $cookiesFile) }
    if ($proxy)              { $probeArgs += @("-Proxy", $proxy) }
    if ($ytdlpArgs.Count -gt 0) {
        $probeJson = ConvertTo-Json -Compress -InputObject @($ytdlpArgs)
        $probeArgs += @("-YtdlpArgsB64",
                        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($probeJson)))
    }
    & pwsh @probeArgs
    exit $LASTEXITCODE
}

# Assembled as an argument ARRAY rather than a command string, so a path or
# URL containing spaces never needs quoting logic here at all -- pwsh
# passes each element through as a single argument regardless of content.
$pwshArgs = @("-NoProfile", "-File", (Join-Path $installRoot "scripts/run_ytdlp.ps1"), "-Url", $url)
if ($customPath)     { $pwshArgs += @("-DataRoot", $customPath) }
if ($breakOnExisting){ $pwshArgs += "-BreakOnExisting" }
if ($playlistItems)  { $pwshArgs += @("-PlaylistItems", $playlistItems) }
if ($dateAfter)      { $pwshArgs += @("-DateAfter", $dateAfter) }
if ($lazyPlaylist)   { $pwshArgs += "-LazyPlaylist" }
if ($workers)        { $pwshArgs += @("-Workers", $workers) }
if ($noPot)          { $pwshArgs += "-NoPot" }
if ($skipPotUpdate)  { $pwshArgs += "-SkipPotUpdate" }
if ($potPort)        { $pwshArgs += @("-PotPort", $potPort) }

if ($mode)           { $pwshArgs += @("-Mode", $mode) }
if ($quality)        { $pwshArgs += @("-Quality", $quality) }
if ($codec)          { $pwshArgs += @("-Codec", $codec) }
if ($audioCodec)     { $pwshArgs += @("-AudioCodec", $audioCodec) }
if ($container)      { $pwshArgs += @("-Container", $container) }
if ($noComments)     { $pwshArgs += "-NoComments" }
if ($noSubs)         { $pwshArgs += "-NoSubs" }
if ($noThumbnail)    { $pwshArgs += "-NoThumbnail" }
if ($noMetadata)     { $pwshArgs += "-NoMetadata" }
if ($refresh)        { $pwshArgs += "-Refresh" }

if ($fps)            { $pwshArgs += @("-Fps", $fps) }
if ($subLangs)       { $pwshArgs += @("-SubLangs", $subLangs) }
if ($noChapters)     { $pwshArgs += "-NoChapters" }
if ($sponsorMark)    { $pwshArgs += @("-SponsorblockMark", $sponsorMark) }
if ($sponsorRemove)  { $pwshArgs += @("-SponsorblockRemove", $sponsorRemove) }

if ($cookiesFromBrowser) { $pwshArgs += @("-CookiesFromBrowser", $cookiesFromBrowser) }
if ($cookiesFile)        { $pwshArgs += @("-CookiesFile", $cookiesFile) }
if ($proxy)              { $pwshArgs += @("-Proxy", $proxy) }
if ($limitRate)          { $pwshArgs += @("-LimitRate", $limitRate) }
if ($downloader)         { $pwshArgs += @("-Downloader", $downloader) }

# --- Passing an ARRAY across `pwsh -File`, which cannot be done directly ---
# This is the same boundary problem setup-common.ps1 documents for
# -InheritedWarnings, and BOTH of the obvious spellings were tried here
# and observed to fail, rather than reasoned about:
#
#   -YtdlpArg a -YtdlpArg b   -> "Cannot bind parameter because parameter
#                                'YtdlpArg' is specified more than once."
#                                Repeating the name does not accumulate.
#   -YtdlpArg a,b             -> binds ONE element, the literal string
#                                "a,b". `-File` hands every argv entry to
#                                the parameter binder as a raw string, so
#                                PowerShell's array syntax is never
#                                evaluated -- the comma stays data.
#
# A delimiter-joined string is not the fix either, because there is no
# delimiter a yt-dlp argument cannot legitimately contain: --match-filter
# expressions carry commas, spaces, "&" and comparison operators as a
# matter of course.
#
# So the array crosses as base64-encoded JSON in a single scalar
# parameter: no quoting rules to survive, no temp file to create and clean
# up (setup-common.ps1's answer, appropriate there because those are
# free-text warnings, overkill for a handful of short arguments), and it
# round-trips a --match-filter string containing all four of the above
# intact. run_ytdlp.ps1 decodes it back into an array; 020-launcher
# asserts the round trip.
if ($ytdlpArgs.Count -gt 0) {
    $ytdlpArgsJson = ConvertTo-Json -Compress -InputObject @($ytdlpArgs)
    $ytdlpArgsB64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ytdlpArgsJson))
    $pwshArgs += @("-YtdlpArgsB64", $ytdlpArgsB64)
}

# Started as a CHILD pwsh process rather than dot-sourced or invoked with
# & in this one, even though this script is already running under pwsh and
# a child process is strictly more expensive. Two reasons, both about not
# changing behavior that already works: run_ytdlp.ps1's own `exit N` calls
# terminate the process they run in, so invoking it in-process would make
# this launcher's exit path depend on subtleties of how `exit` behaves
# inside `&`; and a separate process keeps run_ytdlp.ps1's $PSScriptRoot,
# preference variables and error state entirely its own. The cost is one
# process launch against a job that then spends minutes downloading video.
& pwsh @pwshArgs
exit $LASTEXITCODE