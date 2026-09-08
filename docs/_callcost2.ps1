# Sanity-check the 95 us/call figure: an emitted $null still travels the output pipeline, so
# measure a genuinely empty body, a captured return, and a .NET baseline for scale.
$N = 60000
$s = 'some representative log line text of about eighty characters, give or take a few.'

function Empty { param([string]$A) }
function EmitNull { param([string]$A) $null }
function Returns { param([string]$A) return $A.Length }
function NoParamBlock { }

function Time($name, $block) {
    [void][System.GC]::Collect()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $block
    $sw.Stop()
    '{0,-34} {1,8:N0} ms   {2,7:N1} us/call' -f $name, $sw.Elapsed.TotalMilliseconds, ($sw.Elapsed.TotalMilliseconds * 1000 / $N)
}

Write-Host ("PS {0}  N={1:N0}  host={2}" -f $PSVersionTable.PSVersion, $N, $Host.Name)
Time 'loop only'                    { for ($i = 0; $i -lt $N; $i++) { } }
Time 'NoParamBlock (no args)'       { for ($i = 0; $i -lt $N; $i++) { NoParamBlock } }
Time 'Empty body, 1 arg'            { for ($i = 0; $i -lt $N; $i++) { Empty -A $s } }
Time 'EmitNull, 1 arg'              { for ($i = 0; $i -lt $N; $i++) { EmitNull -A $s } }
Time 'Returns, captured'            { for ($i = 0; $i -lt $N; $i++) { $x = Returns -A $s } }
Time '.NET Substring'               { for ($i = 0; $i -lt $N; $i++) { $x = $s.Substring(0, 5) } }
Time 'hashtable set+get'            { $h = @{}; for ($i = 0; $i -lt $N; $i++) { $h['k'] = $i; $x = $h['k'] } }
Time 'compiled regex IsMatch'       { $re = [regex]'foo'; for ($i = 0; $i -lt $N; $i++) { $x = $re.IsMatch($s) } }
