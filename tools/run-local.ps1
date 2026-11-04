# Local (Windows) dev run: imports the project, then renders tiles with a visible 64x64 window.
# Example: tools\run-local.ps1 -Region C:\worlds\flat\region -Tiles "-8,4,2,2" -Out out -Ref C:\ref
param(
    [Parameter(Mandatory)] [string] $Region,
    [string] $Tiles = "0,0,1,1",
    [string] $Out = "",
    [string] $Ref = "",
    [int] $Repeat = 1,
    [string] $Extra = "",
    [string] $Godot = "godot"
)
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    & $Godot --headless --path . --import 2>&1 | Out-Null
    $a = @("--path", ".", "--rendering-driver", "vulkan", "--rendering-method", "mobile", "--resolution", "64x64", "--position", "0,0", "-s", "scripts/main.gd", "--",
        "render", "--region-dir", $Region, "--tiles", $Tiles, "--repeat", $Repeat)
    if ($Out) { $a += @("--out", $Out) }
    if ($Ref) { $a += @("--ref", $Ref) }
    if ($Extra) { $a += $Extra.Split(" ") }
    & $Godot @a
} finally { Pop-Location }
