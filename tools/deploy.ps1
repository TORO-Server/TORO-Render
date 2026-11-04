# Ships the working tree (and data/) to a lab directory on the server and rebuilds the image there at low priority.
#   tools\deploy.ps1 -Server user@host -Port 22
param(
    [Parameter(Mandatory)] [string] $Server,
    [int] $Port = 22,
    [string] $Lab = "gpu-renderer-lab",
    [switch] $NoData
)
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP "toro-render-deploy"
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
    # keep repo/data between deploys when -NoData; the code directories are replaced as a whole (no stale scripts)
    $cmd = "cd ~/$Lab && mkdir -p repo && rm -rf repo/scripts repo/shaders repo/docker repo/tools && tar -xf repo.tar -C repo && rm repo.tar $data && " +
        "find repo -name '*.sh' | xargs sed -i 's/\r$//' && chmod +x repo/docker/*.sh && cd repo && " +
        "nice -n 19 ionice -c3 docker build --cpu-shares 64 -q -t toro-render:dev -f docker/Dockerfile ."
    ssh -p $Port $Server $cmd
} finally { Pop-Location }
