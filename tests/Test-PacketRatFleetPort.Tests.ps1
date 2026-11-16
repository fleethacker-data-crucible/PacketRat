#requires -Version 5.1
# Pester proof that FLEETPORT_MODULE cannot load an arbitrary file into the process that holds the Fairlead key.
# Executing this file runs the tests. When the Pester module is already loaded, Describe/It/Should are Pester's;
# otherwise the same words run the proof, so CI does not install a module.
$ErrorActionPreference = 'Stop'
if (-not (Get-Module Pester)) {
    function Describe { param($Name, [scriptblock]$Fixture) & $Fixture }
    function It { param($Name, [scriptblock]$Test) & $Test }
    function Should {
        begin { $got = @() }
        process { $got += ,$_ }
        end {
            $actual = $got[-1]
            $op = [string]$args[0]
            $expected = $args[1]
            $ok = $false
            switch -Regex ($op) {
                '^-?Be$' { $ok = ($actual -eq $expected) }
                '^-?Match$' { $ok = ([string]$actual -match [string]$expected) }
                default { throw "Should does not implement $op" }
            }
            if (-not $ok) { throw ("Expected {0} [{1}] but was [{2}]" -f $op, $expected, $actual) }
        }
    }
}

$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'Private\PacketRatRouter.ps1')

function Write-FleetPortFile {
    param([string]$Path, [string]$Token)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text = @"
`$global:PacketRatFleetPortToken = '$Token'
function Start-FleetService { param([Parameter(Mandatory)][string]`$Name,[string]`$Folder,[int]`$WaitSeconds=0) return @{ State = 'running'; Token = '$Token'; Name = `$Name; Folder = `$Folder } }
Export-ModuleMember -Function Start-FleetService
"@
    Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
}

function Write-EvilFleetPort {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @'
$global:PacketRatFleetPortEvil = $true
function Start-FleetService { param([Parameter(Mandatory)][string]$Name,[string]$Folder,[int]$WaitSeconds=0) return @{ State = 'running'; Token = 'evil' } }
Export-ModuleMember -Function Start-FleetService
'@ | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('packetrat-fleetport-' + [guid]::NewGuid().ToString('N'))
$pack = Join-Path $tmp 'PacketRat'
$profileHome = Join-Path $tmp 'profile-home'
$evil = Join-Path $tmp 'evil.psm1'
$sibling = Join-Path $tmp 'edge-ops\tools\fleet-port\FleetPort.psm1'
$projects = Join-Path $profileHome 'Projects\edge-ops\tools\fleet-port\FleetPort.psm1'
$savedModule = [Environment]::GetEnvironmentVariable('FLEETPORT_MODULE')
$savedProfile = $env:USERPROFILE
$global:PacketRatFleetPortEvil = $false
$global:PacketRatFleetPortToken = ''
try {
    New-Item -ItemType Directory -Path $pack -Force | Out-Null
    New-Item -ItemType Directory -Path $profileHome -Force | Out-Null
    $env:USERPROFILE = $profileHome
    [Environment]::SetEnvironmentVariable('FLEETPORT_MODULE', $null)
    $script:PacketRatFleetPortRoot = $pack
    Write-EvilFleetPort $evil

    Describe 'FleetPort is loaded only from the fixed edge-ops path' {
        It 'does not import a file that FLEETPORT_MODULE names outside those roots' {
            $global:PacketRatFleetPortEvil = $false
            $env:FLEETPORT_MODULE = $evil
            $found = Get-PacketRatFleetPortModule -Root $pack
            ($null -eq $found) | Should -Be $true
            $called = & $script:PacketRatFleetServiceStart -Name 'fairlead' -Folder $pack -WaitSeconds 0
            ($called.State) | Should -Be 'unavailable'
            ($global:PacketRatFleetPortEvil) | Should -Be $false
        }

        It 'does not import a path that climbs out of edge-ops with ..' {
            $global:PacketRatFleetPortEvil = $false
            $escape = Join-Path $tmp 'edge-ops\tools\fleet-port\..\..\..\evil.psm1'
            $env:FLEETPORT_MODULE = $escape
            $resolved = [IO.Path]::GetFullPath($escape)
            ([string]::Equals($resolved, [IO.Path]::GetFullPath($evil), [StringComparison]::OrdinalIgnoreCase)) | Should -Be $true
            $found = Get-PacketRatFleetPortModule -Root $pack
            ($null -eq $found) | Should -Be $true
            $called = & $script:PacketRatFleetServiceStart -Name 'fairlead' -Folder $pack -WaitSeconds 0
            ($called.State) | Should -Be 'unavailable'
            ($global:PacketRatFleetPortEvil) | Should -Be $false
        }

        It 'imports the sibling FleetPort.psm1 and ignores a bad override' {
            $global:PacketRatFleetPortEvil = $false
            $global:PacketRatFleetPortToken = ''
            Write-FleetPortFile -Path $sibling -Token 'sibling'
            $env:FLEETPORT_MODULE = $evil
            Remove-Module FleetPort -Force -ErrorAction SilentlyContinue
            $found = Get-PacketRatFleetPortModule -Root $pack
            ([string]::Equals($found, [IO.Path]::GetFullPath($sibling), [StringComparison]::OrdinalIgnoreCase)) | Should -Be $true
            $called = & $script:PacketRatFleetServiceStart -Name 'fairlead' -Folder $pack -WaitSeconds 0
            ($called.State) | Should -Be 'running'
            ($called.Token) | Should -Be 'sibling'
            ($called.Name) | Should -Be 'fairlead'
            ($global:PacketRatFleetPortEvil) | Should -Be $false
            ($global:PacketRatFleetPortToken) | Should -Be 'sibling'
        }

        It 'accepts FLEETPORT_MODULE only when it is the Projects copy' {
            $global:PacketRatFleetPortToken = ''
            Write-FleetPortFile -Path $projects -Token 'projects'
            Remove-Item -LiteralPath $sibling -Force
            $env:FLEETPORT_MODULE = [IO.Path]::GetFullPath($projects)
            Remove-Module FleetPort -Force -ErrorAction SilentlyContinue
            $found = Get-PacketRatFleetPortModule -Root $pack
            ([string]::Equals($found, [IO.Path]::GetFullPath($projects), [StringComparison]::OrdinalIgnoreCase)) | Should -Be $true
            $called = & $script:PacketRatFleetServiceStart -Name 'fairlead' -Folder $pack -WaitSeconds 0
            ($called.Token) | Should -Be 'projects'
            ($global:PacketRatFleetPortToken) | Should -Be 'projects'
        }

        It 'reloads that same file with Import-Module -Force' {
            $src = [IO.File]::ReadAllText((Join-Path $Root 'Private\PacketRatRouter.ps1'))
            ($src -match 'Import-Module -Name \$mod -Force') | Should -Be $true
            Write-FleetPortFile -Path $sibling -Token 'first'
            $env:FLEETPORT_MODULE = $null
            Remove-Module FleetPort -Force -ErrorAction SilentlyContinue
            $first = & $script:PacketRatFleetServiceStart -Name 'fairlead' -Folder $pack -WaitSeconds 0
            ($first.Token) | Should -Be 'first'
            Write-FleetPortFile -Path $sibling -Token 'second'
            $second = & $script:PacketRatFleetServiceStart -Name 'fairlead' -Folder $pack -WaitSeconds 0
            ($second.Token) | Should -Be 'second'
            ($global:PacketRatFleetPortToken) | Should -Be 'second'
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable('FLEETPORT_MODULE', $savedModule)
    $env:USERPROFILE = $savedProfile
    $script:PacketRatFleetPortRoot = $null
    Remove-Module FleetPort -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

'PacketRat FleetPort tests passed.'
