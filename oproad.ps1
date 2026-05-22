param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$OproadArgs
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Image = if ($env:OPROAD_IMAGE) { $env:OPROAD_IMAGE } else { "oproad:latest" }
$Platform = if ($env:OPROAD_DOCKER_PLATFORM) { $env:OPROAD_DOCKER_PLATFORM } else { "linux/amd64" }
$FinishMode = if ($env:OPROAD_FINISH_MODE) { $env:OPROAD_FINISH_MODE } else { "auto" }

function Show-Usage {
    @"
Usage:
  .\oproad.ps1 build-image
  .\oproad.ps1 new       <platform> <design> <freq_GHz> [parent_dir]
  .\oproad.ps1 sim       [project_dir]
  .\oproad.ps1 synth     [project_dir]
  .\oproad.ps1 implement [project_dir]
  .\oproad.ps1 report    [project_dir]
  .\oproad.ps1 clean     [project_dir]
  .\oproad.ps1 delete    [project_dir]
  .\oproad.ps1 shell     [work_dir]

Only 'new' takes a platform/process argument. Other commands read .asic_project.
"@
}

function Require-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is required but was not found on PATH."
    }
}

function Resolve-OrCreateDir([string]$Path) {
    if (-not $Path) { $Path = "." }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return (Resolve-Path $Path).Path
}

function Resolve-ExistingDir([string]$Path) {
    if (-not $Path) { $Path = "." }
    return (Resolve-Path $Path).Path
}

function Invoke-OproadContainer([string]$HostPath, [string]$ContainerPath, [string[]]$Command) {
    Require-Docker
    $volume = "${HostPath}:${ContainerPath}"
    $dockerArgs = @(
        "run", "--rm", "-it",
        "--platform", $Platform,
        "-e", "OPROAD_RUNNER=local",
        "-e", "OPROAD_DOCKER_TTY=0",
        "-e", "OPROAD_FINISH_MODE=$FinishMode",
        "-v", $volume,
        $Image
    ) + $Command
    & docker @dockerArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not $OproadArgs -or $OproadArgs[0] -in @("-h", "--help", "help")) {
    Show-Usage
    exit 0
}

$cmd = $OproadArgs[0]
switch ($cmd) {
    "build-image" {
        Require-Docker
        & docker build --platform $Platform -t $Image $RepoRoot
        exit $LASTEXITCODE
    }
    "new" {
        if ($OproadArgs.Count -lt 4) {
            Show-Usage
            exit 1
        }
        $parent = if ($OproadArgs.Count -ge 5) { Resolve-OrCreateDir $OproadArgs[4] } else { Resolve-OrCreateDir "." }
        Invoke-OproadContainer $parent "/workspace" @("oproad-runner", "new", $OproadArgs[1], $OproadArgs[2], $OproadArgs[3], "/workspace")
    }
    { $_ -in @("sim", "synth", "implement", "run", "report", "clean") } {
        $project = if ($OproadArgs.Count -ge 2) { Resolve-ExistingDir $OproadArgs[1] } else { Resolve-ExistingDir "." }
        Invoke-OproadContainer $project "/project" @("oproad-runner", $cmd, "/project")
    }
    "delete" {
        $project = if ($OproadArgs.Count -ge 2) { Resolve-ExistingDir $OproadArgs[1] } else { Resolve-ExistingDir "." }
        $parent = Split-Path -Parent $project
        $name = Split-Path -Leaf $project
        Invoke-OproadContainer $parent "/workspace" @("oproad-runner", "delete", "/workspace/$name")
    }
    "shell" {
        $workDir = if ($OproadArgs.Count -ge 2) { Resolve-OrCreateDir $OproadArgs[1] } else { Resolve-OrCreateDir "." }
        Invoke-OproadContainer $workDir "/workspace" @("bash")
    }
    default {
        Write-Error "Unknown command: $cmd"
        Show-Usage
        exit 1
    }
}
