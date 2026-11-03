# Ships the working tree (and data/) to the server lab directory and rebuilds the image at low priority.
param(
    [string] $Server = "user@host",
    [int] $Port = 22,
    [string] $Lab = "gpu-renderer-lab",
    [switch] $NoData
)
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP "toro-gpu-deploy"
New-Item -ItemType Directory -Force $tmp | Out-Null
Push-Location $root
try {
    tar --exclude=.godot --exclude=data --exclude=out --exclude=.git -cf "$tmp\repo.tar" .
    scp -P $Port "$tmp\repo.tar" "${Server}:$Lab/"
    $data = ""
    if (-not $NoData) {
        tar -cf "$tmp\data.tar" data
        scp -P $Port "$tmp\data.tar" "${Server}:$Lab/"
        $data = "&& tar -xf data.tar -C repo && rm data.tar"
    }
    # keep repo/data between deploys when -NoData; only code directories are replaced
    $cmd = "cd ~/$Lab && mkdir -p repo && tar -xf repo.tar -C repo && rm repo.tar $data && " +
        "find repo -name '*.sh' | xargs sed -i 's/\r$//' && cd repo && " +
        "nice -n 19 ionice -c3 docker build --cpu-shares 64 -q -t toro-gpu-renderer:dev -f docker/Dockerfile ."
    ssh -p $Port $Server $cmd
} finally { Pop-Location }
