# Pixel comparison of the Godot renderer against Dynmap-GPU (Rust) on the same world snapshot.
# Each case renders a tile rectangle with both renderers and prints the pixel match.
#   tools\compare-ref.ps1 -Region C:\worlds\main\region -Cases "iso_S_90_lowres:0,0,2,2;iso_SE_30_hires:1,6,1,1"
param(
    [Parameter(Mandatory)] [string] $Region,
    [Parameter(Mandatory)] [string] $Cases,
    [string] $Mesher = "gpu",
    [string] $Godot = "godot",
    [string] $Dg = "dg-run.exe",   # Dynmap-GPU's command line renderer
    [string] $Work = (Join-Path $env:TEMP "toro-renderer-cmp"),
    [string] $DgGpu = ""             # DG_GPU adapter selector of Dynmap-GPU, empty = its default
)
$root = Split-Path -Parent $PSScriptRoot
& $Godot --headless --path $root --import 2>&1 | Out-Null   # shaders/scripts are imported resources
if ($DgGpu) { $env:DG_GPU = $DgGpu }
foreach ($case in $Cases.Split(";")) {
    $persp, $tiles = $case.Split(":")
    $t = $tiles.Split(",") | ForEach-Object { [int]$_ }
    $tag = ($case -replace "[^A-Za-z0-9]", "_")
    $ref = Join-Path $Work "rust_$tag"
    $out = Join-Path $Work "godot_$tag"
    Remove-Item $ref, $out -Recurse -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $ref | Out-Null
    & $Dg render $Region $persp $t[0] $t[1] $t[2] $t[3] $ref 2>&1 | Out-Null
    $a = @("--path", $root, "--rendering-driver", "vulkan", "--rendering-method", "mobile", "--resolution", "64x64", "--position", "0,0",
        "-s", "scripts/main.gd", "--", "render", "--region-dir", $Region, "--tiles", $tiles, "--persp", $persp, "--out", $out, "--ref", $ref, "--mesher", $Mesher)
    $p = Start-Process -FilePath $Godot -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput "$out.log" -RedirectStandardError "$out.err"
    $p.PriorityClass = "AboveNormal"
    $p.WaitForExit(900000) | Out-Null
    $line = Get-Content "$out.log" | Select-String "pixel match|render rect" | ForEach-Object { $_.Line }
    "{0,-40} {1}" -f $case, ($line -join " | ")
}
