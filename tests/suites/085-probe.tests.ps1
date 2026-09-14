<#
    scripts/probe.ps1 -- `ytdl --probe`, the read-only half.

    Two things are being defended here and they are different in kind.

    The first is the OUTPUT CONTRACT: one JSON document on stdout and
    nothing else, ever. Four consumers decide whether a probe worked by
    whether they can parse what came back, so a single stray Write-Host --
    a progress note, a PO-token line, a warning -- turns a working probe
    into a failed one in every frontend simultaneously, and does it without
    changing a single behaviour a human running the command would notice.
    That is the failure mode these tests exist for, and it is why several
    of them assert on stdout being parseable rather than on its contents.

    The second is the DERIVATION. probe.ps1 maps yt-dlp's codec spellings
    onto this pipeline's --codec / --audio-codec vocabulary and works out
    which --container values a merge could actually produce. It does that
    so the three native frontends do not each invent it; the price of
    centralising it is that getting it wrong is now wrong everywhere at
    once, so the mapping is asserted against a fixture format list with
    every shape that has ever been confusing in it -- "vp09" against "vp9",
    "av01" against the "av1" that yt-dlp never emits, "mp4a" as aac, an
    mhtml storyboard that is not a rendition of anything, and a VP8 stream
    with a real height and no --codec spelling at all.

    No network. yt-dlp is stubbed, as everywhere else in this suite.
#>

Describe 'ytdl --probe' {

    $root = New-TestRoot -Label 'probe'
    Install-PipelineInto -TestRoot $root -RepoRoot $script:RepoRoot
    Enable-Stubs -TestRoot $root

    # ------------------------------------------------------------------
    # The fixture format list
    # ------------------------------------------------------------------
    # Every entry is here because it distinguishes a correct derivation
    # from a plausible wrong one:
    #
    #   sb0    mhtml storyboard -- no streams at all. Must not appear as a
    #          format, and must not contribute a height.
    #   137    avc1 video-only, 1080p. The "h264 spelled avc1" case.
    #   248    vp09 video-only, 1080p. The spelling that is NOT "vp9", and
    #          the reason a startswith("vp9") test alone would miss it.
    #   271    vp09 video-only, 1440p -- a height only one codec offers,
    #          which is what makes cross-filtering in a frontend matter.
    #   401    av01 video-only, 2160p. Spelled with a ZERO.
    #   330    vp08 video-only, 480p. A real height with NO --codec
    #          spelling: its height must be offered, its codec must not.
    #   140    mp4a audio-only -- "aac" under a name that does not say so.
    #   251    opus audio-only.
    #   18     progressive avc1+mp4a, 360p. Carries both streams at once.
    $formatsJson = @'
[
  {"format_id":"sb0","ext":"mhtml","vcodec":"none","acodec":"none","height":180},
  {"format_id":"137","ext":"mp4","vcodec":"avc1.640028","acodec":"none","height":1080,"width":1920,"fps":30,"tbr":4412.5,"filesize":112233445},
  {"format_id":"248","ext":"webm","vcodec":"vp09.00.40.08","acodec":"none","height":1080,"width":1920,"fps":30,"tbr":2812.1},
  {"format_id":"271","ext":"webm","vcodec":"vp09.00.50.08","acodec":"none","height":1440,"width":2560,"fps":30,"tbr":6221.0,"filesize_approx":220000000},
  {"format_id":"401","ext":"mp4","vcodec":"av01.0.12M.08","acodec":"none","height":2160,"width":3840,"fps":30,"tbr":12000.0,"dynamic_range":"SDR"},
  {"format_id":"330","ext":"webm","vcodec":"vp08.00.10.08","acodec":"none","height":480,"width":854,"fps":30,"tbr":800.0},
  {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","tbr":129.5},
  {"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus","tbr":141.0},
  {"format_id":"18","ext":"mp4","vcodec":"avc1.42001E","acodec":"mp4a.40.2","height":360,"width":640,"fps":30,"tbr":611.0}
]
'@

    # The stub. Steered entirely by environment variables, because
    # New-StubBinary serialises the scriptblock to a file and it can
    # therefore close over nothing.
    #
    #   YTDLP_TEST_PROBE_KIND      video (default) | playlist
    #   YTDLP_TEST_PROBE_ENTRIES   how many playlist entries to emit
    #   YTDLP_TEST_PROBE_FAIL      1 = exit non-zero with a message on stderr
    #   YTDLP_TEST_PROBE_FORMATS   the formats array, as JSON
    $env:YTDLP_TEST_PROBE_FORMATS = $formatsJson
    New-StubBinary -TestRoot $root -Name 'yt-dlp' -Behavior {
        if ($StubArgs -contains '--version') { Write-Output '2026.08.20'; return }

        if ($env:YTDLP_TEST_PROBE_FAIL -eq '1') {
            # Two lines, because probe.ps1 reports only the LAST one: the
            # useful sentence is under the retry noise, not above it.
            [Console]::Error.WriteLine('WARNING: [youtube] Retrying (1/2)...')
            [Console]::Error.WriteLine('ERROR: [youtube] dQw4w9WgXcQ: Video unavailable')
            exit 1
        }

        $formats = $env:YTDLP_TEST_PROBE_FORMATS

        if ($StubArgs -contains '--flat-playlist') {
            if ($env:YTDLP_TEST_PROBE_KIND -eq 'playlist') {
                $n = 3
                if ($env:YTDLP_TEST_PROBE_ENTRIES) { $n = [int]$env:YTDLP_TEST_PROBE_ENTRIES }
                $entries = @()
                for ($i = 1; $i -le $n; $i++) {
                    $entries += "{""id"":""vid$i"",""title"":""Entry $i"",""duration"":$($i * 60),""uploader"":""Test Channel"",""url"":""https://youtu.be/vid$i""}"
                }
                Write-Output ('{"_type":"playlist","id":"PL123","title":"Test Playlist","channel":"Test Channel","uploader":"Test Channel","extractor_key":"YoutubeTab","playlist_count":' + $n + ',"entries":[' + ($entries -join ',') + ']}')
            } else {
                Write-Output '{"id":"dQw4w9WgXcQ","title":"Test Video","_type":"video"}'
            }
            return
        }

        # The full extraction.
        Write-Output ('{"id":"dQw4w9WgXcQ","title":"Test Video","uploader":"Test Channel","channel":"Test Channel","channel_url":"https://youtube.com/@test","extractor_key":"Youtube","duration":212.0,"upload_date":"20250114","view_count":1234567,"like_count":8910,"comment_count":4321,"live_status":"not_live","availability":"public","age_limit":0,"thumbnail":"https://i.ytimg.com/vi/dQw4w9WgXcQ/maxres.jpg","description":"A description.","webpage_url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","subtitles":{"en":[],"de":[]},"automatic_captions":{"en":[],"fr":[],"es":[]},"formats":' + $formats + '}')
    }

    # ------------------------------------------------------------------
    # Running the probe
    # ------------------------------------------------------------------
    # Deliberately through ytdl.ps1 rather than by calling probe.ps1
    # directly, for most cases: the dispatch and the refusals are half of
    # what this feature is, and a test that skipped the launcher would pass
    # with --probe wired to nothing at all.
    function Invoke-Probe {
        param([string[]]$Arguments)
        $r = Invoke-YtdlLauncher -TestRoot $root -Arguments $Arguments
        # Invoke-YtdlLauncher merges streams. The JSON is the one line that
        # parses as an object, which is exactly the test a frontend applies.
        $json = $null
        foreach ($line in $r.Output) {
            $t = "$line".Trim()
            if ($t.StartsWith('{') -and $t.EndsWith('}')) {
                try { $json = $t | ConvertFrom-Json -Depth 64 } catch { }
            }
        }
        return [pscustomobject]@{ Raw = $r; Json = $json }
    }

    $url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'

    It 'returns parseable JSON for a single video' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        Assert-Equal 0 $p.Raw.ExitCode "probe exited non-zero: $($p.Raw.Output -join ' ')"
        Assert-True ($null -ne $p.Json) "nothing on stdout parsed as JSON: $($p.Raw.Output -join ' ')"
        Assert-Equal 'video' $p.Json.kind 'kind'
        Assert-Equal 'dQw4w9WgXcQ' $p.Json.id 'id'
        Assert-Equal 'Test Video' $p.Json.title 'title'
        Assert-Equal 'Test Channel' $p.Json.uploader 'uploader'
        Assert-Equal 212 ([int]$p.Json.duration) 'duration'
        Assert-Equal 1 ([int]$p.Json.entry_count) 'entry_count for a single video'
    }

    It 'declares a probe_version so a reader can refuse a shape it does not know' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        Assert-Equal 1 ([int]$p.Json.probe_version) 'probe_version'
    }

    It 'drops the mhtml storyboard and keeps every real rendition' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        $ids = @($p.Json.formats | ForEach-Object { $_.format_id })
        Assert-False ($ids -contains 'sb0') 'the storyboard must not be reported as a format'
        Assert-Equal 8 $ids.Count "expected 8 real renditions, got $($ids -join ',')"
    }

    It 'reports heights descending and distinct, including codecs it has no name for' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        $heights = @($p.Json.heights | ForEach-Object { [int]$_ })
        # 1080 appears twice in the fixture (avc1 and vp09) and must appear
        # once here; 480 is the VP8 rendition, whose height is real even
        # though this pipeline has no --codec spelling for its codec; 180
        # is the storyboard's and must be gone.
        Assert-Equal '2160,1440,1080,480,360' ($heights -join ',') 'heights'
    }

    It 'maps yt-dlp codec spellings onto the --codec vocabulary' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        # Canonical order, not offer order: a dropdown that reshuffles
        # between two probes of the same video looks broken.
        Assert-Equal 'avc1,vp9,av01' (@($p.Json.video_codecs) -join ',') 'video_codecs'
        Assert-Equal 'opus,aac' (@($p.Json.audio_codecs) -join ',') 'audio_codecs'
        # vp08 has no --codec spelling and must not have become "vp9".
        $vp8 = @($p.Json.formats | Where-Object { $_.format_id -eq '330' })
        Assert-Equal 1 $vp8.Count 'the vp8 rendition should still be listed'
        Assert-True ([string]::IsNullOrEmpty($vp8[0].video_family)) 'vp08 must map to no family at all'
    }

    It 'offers only the containers a merge could actually produce' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        Assert-Equal 'mkv,mp4,webm' (@($p.Json.containers) -join ',') 'containers'
    }

    It 'drops mp4 when there is no AAC track to put in it' {
        # Opus-only audio: mkv and webm are muxable, mp4 is not. This is
        # the assertion that earns the derivation its place in the
        # pipeline -- a frontend offering mp4 here produces either a
        # re-encode or a failed merge, depending on yt-dlp version.
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $saved = $env:YTDLP_TEST_PROBE_FORMATS
        $env:YTDLP_TEST_PROBE_FORMATS = @'
[
  {"format_id":"248","ext":"webm","vcodec":"vp09.00.40.08","acodec":"none","height":1080},
  {"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus"}
]
'@
        try {
            $p = Invoke-Probe -Arguments @($url, '--probe')
            Assert-Equal 'mkv,webm' (@($p.Json.containers) -join ',') 'containers with no AAC'
        } finally {
            $env:YTDLP_TEST_PROBE_FORMATS = $saved
        }
    }

    It 'keeps exact and approximate sizes apart' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        $f137 = @($p.Json.formats | Where-Object { $_.format_id -eq '137' })[0]
        $f271 = @($p.Json.formats | Where-Object { $_.format_id -eq '271' })[0]
        Assert-Equal 112233445 ([long]$f137.filesize) 'an exact filesize stays exact'
        Assert-True ($null -eq $f137.filesize_approx) '137 has no approximate size'
        Assert-Equal 220000000 ([long]$f271.filesize_approx) 'an estimate stays an estimate'
        Assert-True ($null -eq $f271.filesize) '271 has no exact size'
    }

    It 'reports subtitle languages without implying they are selectable' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe')
        Assert-Equal 'en,de' (@($p.Json.subtitle_langs) -join ',') 'subtitle_langs'
        Assert-Equal 3 (@($p.Json.automatic_caption_langs)).Count 'automatic_caption_langs'
    }

    # ------------------------------------------------------------------
    # Playlists
    # ------------------------------------------------------------------

    It 'enumerates playlist entries with their 1-based playlist positions' {
        $env:YTDLP_TEST_PROBE_KIND = 'playlist'
        $env:YTDLP_TEST_PROBE_ENTRIES = '3'
        $p = Invoke-Probe -Arguments @('https://www.youtube.com/playlist?list=PL123', '--probe')
        Assert-Equal 'playlist' $p.Json.kind 'kind'
        Assert-Equal 3 ([int]$p.Json.entry_count) 'entry_count'
        $indices = @($p.Json.entries | ForEach-Object { [int]$_.index })
        # The index is what --playlist-items counts. Emitted explicitly
        # rather than left to array position, so a frontend that sorts the
        # list cannot silently renumber it and select the wrong videos.
        Assert-Equal '1,2,3' ($indices -join ',') 'entry indices'
        Assert-Equal 'Entry 2' $p.Json.entries[1].title 'entry title'
        Assert-Equal 'vid2' $p.Json.entries[1].id 'entry id'
    }

    It 'reads the format table from the first entry and says which one' {
        $env:YTDLP_TEST_PROBE_KIND = 'playlist'
        $env:YTDLP_TEST_PROBE_ENTRIES = '3'
        $p = Invoke-Probe -Arguments @('https://www.youtube.com/playlist?list=PL123', '--probe')
        Assert-Equal 'dQw4w9WgXcQ' $p.Json.formats_from_id 'formats_from_id'
        Assert-True (@($p.Json.heights).Count -gt 0) 'a playlist probe still reports a format table'
    }

    It 'truncates a long playlist and says so rather than hanging' {
        $env:YTDLP_TEST_PROBE_KIND = 'playlist'
        $env:YTDLP_TEST_PROBE_ENTRIES = '40'
        try {
            # MaxEntries is probe.ps1's own default of 500 unless the
            # launcher is told otherwise, so this exercises the ceiling by
            # calling probe.ps1 directly -- the one case where going
            # through ytdl.ps1 cannot reach the parameter.
            $script = Join-Path $root.InstallRoot 'scripts/probe.ps1'
            $previous = $env:YTDLP_INSTALL_ROOT
            $env:YTDLP_INSTALL_ROOT = $root.InstallRoot
            try {
                $out = & (Get-PwshPath) -NoProfile -File $script `
                    -Url 'https://www.youtube.com/playlist?list=PL123' -MaxEntries 10 2>$null
            } finally {
                $env:YTDLP_INSTALL_ROOT = $previous
            }
            $json = ($out -join "`n") | ConvertFrom-Json -Depth 64
            Assert-Equal 10 ([int]$json.entry_count) 'entry_count is capped'
            Assert-True ([bool]$json.entries_truncated) 'entries_truncated must be set'
        } finally {
            $env:YTDLP_TEST_PROBE_ENTRIES = '3'
        }
    }

    # ------------------------------------------------------------------
    # The output contract
    # ------------------------------------------------------------------

    It 'writes nothing but the JSON document to stdout' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $script = Join-Path $root.InstallRoot 'scripts/probe.ps1'
        $previous = $env:YTDLP_INSTALL_ROOT
        $env:YTDLP_INSTALL_ROOT = $root.InstallRoot
        try {
            # stderr discarded, NOT merged: the whole assertion is that
            # what remains on stdout is one document and nothing else. The
            # "Probing ..." note and every [pot] line must be on the other
            # stream.
            $out = & (Get-PwshPath) -NoProfile -File $script -Url $url 2>$null
        } finally {
            $env:YTDLP_INSTALL_ROOT = $previous
        }
        $text = ($out -join "`n").Trim()
        Assert-True ($text.StartsWith('{')) "stdout did not begin with the document: $(Format-Excerpt $text)"
        $null = $text | ConvertFrom-Json -Depth 64
    }

    It 'says what happened to PO tokens, because it changes the format table' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $p = Invoke-Probe -Arguments @($url, '--probe', '--no-pot')
        Assert-NotEqual $null $p.Json.pot 'the pot object must always be present'
        Assert-False ([bool]$p.Json.pot.healthy) '--no-pot means degraded'
        Assert-Match 'NoPot' "$($p.Json.pot.reason)" 'pot.reason should name the cause'
        Assert-Match 'may see formats' "$($p.Json.pot.note)" 'pot.note should warn the list can be thin'
    }

    It 'fails with the useful stderr line and nothing on stdout' {
        $env:YTDLP_TEST_PROBE_FAIL = '1'
        try {
            $p = Invoke-Probe -Arguments @($url, '--probe')
            Assert-NotEqual 0 $p.Raw.ExitCode 'a failed probe must exit non-zero'
            Assert-True ($null -eq $p.Json) 'a failed probe must put no JSON on stdout'
            # The LAST stderr line, not the retry noise above it.
            Assert-Match 'Video unavailable' ($p.Raw.Output -join ' ') 'the reported reason'
        } finally {
            $env:YTDLP_TEST_PROBE_FAIL = '0'
        }
    }

    # ------------------------------------------------------------------
    # Dispatch and refusals in ytdl.ps1
    # ------------------------------------------------------------------

    It 'never starts run_ytdlp.ps1' {
        # The sharpest test in the file. A probe that reached the session
        # orchestrator would self-heal the folder tree, open a session log
        # and snapshot Archive History before it got anywhere near a
        # short-circuit -- so "downloads nothing" is not enough; it must
        # not run that file at all.
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $marker = Join-Path $root.Root 'run-ytdlp-was-started'
        $standIn = Join-Path $root.InstallRoot 'scripts/run_ytdlp.ps1'
        $saved = Get-Content -Raw -LiteralPath $standIn
        Set-Content -LiteralPath $standIn -Encoding utf8 -Value @"
param([Parameter(ValueFromRemainingArguments = `$true)]`$Rest)
Set-Content -LiteralPath '$marker' -Value 'started'
"@
        try {
            $p = Invoke-Probe -Arguments @($url, '--probe')
            Assert-PathMissing $marker
            Assert-True ($null -ne $p.Json) 'the probe should still have produced its document'
        } finally {
            Set-Content -LiteralPath $standIn -Value $saved -NoNewline -Encoding utf8
        }
    }

    It 'refuses the options that describe a download' {
        # Refused, not ignored. A probe that accepted --quality 1080 and
        # did nothing with it would read as though the preview reflected
        # the user's settings.
        foreach ($pair in @(
            @('--quality', '1080'), @('--mode', 'audio-only'), @('--codec', 'av01'),
            @('--container', 'mp4'), @('--workers', '4'), @('--path', '/tmp/x'),
            @('--after', '20250101')
        )) {
            $r = Invoke-YtdlLauncher -TestRoot $root -Arguments (@($url, '--probe') + $pair)
            Assert-NotEqual 0 $r.ExitCode "--probe $($pair[0]) should be refused"
            Assert-Match 'downloads nothing' ($r.Output -join ' ') "the error for $($pair[0])"
        }
        foreach ($flag in @('--sync', '--lazy', '--no-comments', '--no-subs', '--no-thumbnail', '--no-metadata')) {
            $r = Invoke-YtdlLauncher -TestRoot $root -Arguments @($url, '--probe', $flag)
            Assert-NotEqual 0 $r.ExitCode "--probe $flag should be refused"
        }
    }

    It 'accepts the options that still mean something to a probe' {
        $env:YTDLP_TEST_PROBE_KIND = 'playlist'
        $env:YTDLP_TEST_PROBE_ENTRIES = '3'
        # --items narrows enumeration, --no-pot and --pot-port change which
        # formats yt-dlp can see, and --ytdlp-arg is how a URL that needs
        # cookies gets probed at all.
        $p = Invoke-Probe -Arguments @(
            'https://www.youtube.com/playlist?list=PL123', '--probe',
            '--items', '2-3', '--no-pot', '--pot-port', '5000',
            '--ytdlp-arg', '--cookies-from-browser', '--ytdlp-arg', 'firefox')
        Assert-Equal 0 $p.Raw.ExitCode "probe rejected an option it should accept: $($p.Raw.Output -join ' ')"
        Assert-True ($null -ne $p.Json) 'no document came back'
        Assert-Equal '2-3' $p.Json.items_requested 'items_requested should echo --items'

        $calls = Get-StubCalls -TestRoot $root -Name 'yt-dlp'
        $flat = @($calls | Where-Object { $_.args -contains '--flat-playlist' })[-1]
        Assert-True ($flat.args -contains '--cookies-from-browser') '--ytdlp-arg must reach yt-dlp'
        Assert-True ($flat.args -contains 'firefox') 'its value too'
        # yt-dlp's own --playlist-items, carrying the user's range rather
        # than the default ceiling.
        $pi = [Array]::IndexOf([string[]]$flat.args, '--playlist-items')
        Assert-True ($pi -ge 0) '--playlist-items should be passed'
        Assert-Equal '2-3' $flat.args[$pi + 1] 'the range the user gave'
    }

    It 'reads yt-dlp without the download config' {
        # --ignore-config rather than --config-location, and the reason is
        # not tidiness: config/yt-dlp.conf opens with --update, so a
        # frontend probing as the user types would trigger a yt-dlp
        # self-update per settled URL.
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        Clear-StubCalls -TestRoot $root
        $null = Invoke-Probe -Arguments @($url, '--probe')
        foreach ($c in (Get-StubCalls -TestRoot $root -Name 'yt-dlp')) {
            Assert-True ($c.args -contains '--ignore-config') 'every probe call must pass --ignore-config'
            Assert-False ($c.args -contains '--config-location') 'a probe must not read yt-dlp.conf'
            Assert-False ($c.args -contains '-U') 'a probe must never self-update yt-dlp'
            # The end-of-options marker, same as every call site in
            # run_ytdlp.ps1: about one YouTube id in thirty starts with a
            # hyphen.
            Assert-True ($c.args -contains '--') 'the -- marker must precede the URL'
        }
    }

    It 'writes nothing into the archive' {
        $env:YTDLP_TEST_PROBE_KIND = 'video'
        $logs = Join-Path $root.InstallRoot 'Archive Logs'
        $videos = Join-Path $root.InstallRoot 'Youtube Videos'
        Remove-Item -LiteralPath $logs, $videos -Recurse -Force -ErrorAction SilentlyContinue
        $null = Invoke-Probe -Arguments @($url, '--probe')
        Assert-PathMissing $logs
        Assert-PathMissing $videos
    }

    It 'is listed in the launcher usage text' {
        $r = Invoke-YtdlLauncher -TestRoot $root -Arguments @()
        Assert-Match '--probe' ($r.Output -join ' ') 'usage should mention --probe'
    }

    # ------------------------------------------------------------------
    # The duplicated platform block
    # ------------------------------------------------------------------

    It 'agrees with run_ytdlp.ps1 about deno locations and install roots' {
        # probe.ps1 re-derives the install root and the deno candidate list
        # rather than asking run_ytdlp.ps1 for them, for the same reason
        # ytdl.ps1 does: a file that has to FIND the pipeline cannot ask
        # the pipeline where it is. That duplication is only safe while
        # something checks it, which is this.
        $probeText = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'scripts/probe.ps1')
        $runText   = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'scripts/run_ytdlp.ps1')

        foreach ($candidate in @(
            '".deno/bin/deno.exe"', '".local/bin/deno.exe"',
            '".local/bin/deno"', '".deno/bin/deno"',
            '"/opt/homebrew/bin/deno"', '"/usr/local/bin/deno"'
        )) {
            Assert-True ($probeText -like "*$candidate*") "probe.ps1 is missing the deno candidate $candidate"
            Assert-True ($runText   -like "*$candidate*") "run_ytdlp.ps1 is missing the deno candidate $candidate"
        }
        foreach ($rootLiteral in @('"C:/yt-dlp"', 'Join-Path $HOME "yt-dlp"')) {
            Assert-True ($probeText -like "*$rootLiteral*") "probe.ps1 is missing the install root $rootLiteral"
        }
        # And the override every component honours.
        Assert-True ($probeText -like '*YTDLP_INSTALL_ROOT*') 'probe.ps1 must honour YTDLP_INSTALL_ROOT'
    }

    Remove-TestRoot -TestRoot $root
}
