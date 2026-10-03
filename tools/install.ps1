# ArkWeb's installer (install.bat, uninstall.bat and play.bat run it).
#
# Finds both games in the Steam libraries and puts the DLLs next to them: bin\ when they were built here (build.bat)
# and are newer, else prebuilt\. Next to each goes an arkweb.ini whose LogDir is this folder's logs\, where the
# streamer (tools\gotham_stream.py) reads and writes too. A dinput8.dll or winmm.dll of another mod is kept as
# <name>.arkweb-backup, and -Uninstall puts it back. Games in a protected folder (Program Files) get the copy done
# with administrator rights.
param(
	[string]$ArkhamDir = "",     # the folder with BatmanAK.exe (Binaries\Win64); looked up in the Steam libraries if not given
	[string]$SpiderManDir = "",  # the folder with Spider-Man.exe; likewise
	[switch]$Uninstall,
	[switch]$IfNeeded,           # nothing to do when both games already have these DLLs (play.ps1)
	[switch]$NoPause,            # no "press Enter" at the end
	[switch]$NoAsk               # no questions and no administrator rights (CI)
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $Root "logs"
$Turkish = (Get-UICulture).TwoLetterISOLanguageName -eq "tr"
$AkExe = "BatmanAK.exe"
$SmExe = "Spider-Man.exe"
$AkRel = "steamapps\common\Batman Arkham Knight\Binaries\Win64\$AkExe"
$SmRel = "steamapps\common\Marvel's Spider-Man Remastered\$SmExe"

function T([string]$En, [string]$Tr) { if ($Turkish) { $Tr } else { $En } }

function Say([string]$Text, [string]$Color = "Gray") { Write-Host $Text -ForegroundColor $Color }

function Done([int]$Code) {
	if (-not $NoPause) { Read-Host (T "Press Enter to close" "Kapatmak için Enter'a bas") | Out-Null }
	exit $Code
}

# Steam's libraries: where Steam is, and every "path" in its steamapps\libraryfolders.vdf.
function SteamLibraries {
	$dirs = New-Object System.Collections.Generic.List[string]
	foreach ($key in "HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam") {
		$p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
		if ($p) {
			foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { $dirs.Add(($v -replace "/", "\")) } }
		}
	}
	foreach ($steam in @($dirs)) {
		$vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
		if (Test-Path -LiteralPath $vdf) {
			foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $dirs.Add(($m.Groups[1].Value -replace "\\\\", "\")) }
		}
	}
	@($dirs | Where-Object { $_ } | ForEach-Object { $_.TrimEnd("\") } | Select-Object -Unique)
}

# The folder of a game's exe: in a Steam library, else one of $Also (full paths of the exe).
function FindGame([string]$Rel, [string[]]$Also) {
	$exes = @(SteamLibraries | ForEach-Object { Join-Path $_ $Rel }) + $Also
	foreach ($exe in $exes) {
		if ($exe -and (Test-Path -LiteralPath $exe)) { return (Split-Path -Parent $exe) }
	}
	return ""
}

function AskFolder([string]$Game, [string]$Exe) {
	if ($NoAsk) { return "" }
	while ($true) {
		$d = Read-Host (T "$Game wasn't found. Paste the folder that holds $Exe (empty: cancel)" "$Game bulunamadı. $Exe dosyasının olduğu klasörün yolunu yapıştır (boş bırakırsan iptal)")
		$d = $d.Trim().Trim('"').TrimEnd("\")
		if (-not $d) { return "" }
		if (Test-Path -LiteralPath (Join-Path $d $Exe)) { return $d }
		Say (T "There's no $Exe in $d" "$d içinde $Exe yok") Yellow
	}
}

function GameDir([string]$Given, [string]$Game, [string]$Exe, [string]$Rel, [string]$Old) {
	$d = $Given.Trim().Trim('"').TrimEnd("\")
	if ($d -and -not (Test-Path -LiteralPath (Join-Path $d $Exe))) {
		Say (T "There's no $Exe in $d" "$d içinde $Exe yok") Yellow
		$d = ""
	}
	if (-not $d) { $d = FindGame $Rel @($Old) }
	if (-not $d) { $d = AskFolder $Game $Exe }
	if (-not $d) {
		Say (T "$Game wasn't found - nothing was changed." "$Game bulunamadı - hiçbir şey değiştirilmedi.") Red
		Done 1
	}
	return $d
}

# ArkWeb's own DLL (it carries its name), not another mod's.
function IsArkWeb([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path)) { return $false }
	return [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Path)).Contains("ArkWeb")
}

function Writable([string]$Dir) {
	$probe = Join-Path $Dir ("arkweb_" + [guid]::NewGuid().ToString("N") + ".tmp")
	try {
		[IO.File]::WriteAllText($probe, "")
		Remove-Item -LiteralPath $probe -Force
		return $true
	} catch {
		return $false
	}
}

# arkweb.ini next to a DLL: [ArkWeb] LogDir = this folder's logs\ (other keys stay). UTF-16, which Windows reads any path from.
function SetLogDir([string]$Ini) {
	$out = New-Object System.Collections.Generic.List[string]
	$set = $false
	if (Test-Path -LiteralPath $Ini) {
		foreach ($l in @(Get-Content -LiteralPath $Ini)) {
			if ($l -match '^\s*LogDir\s*=') { continue }
			$out.Add($l)
			if (-not $set -and $l -match '^\s*\[ArkWeb\]\s*$') {
				$out.Add("LogDir=$LogDir")
				$set = $true
			}
		}
	}
	if (-not $set) {
		$out.Insert(0, "LogDir=$LogDir")
		$out.Insert(0, "[ArkWeb]")
	}
	Set-Content -LiteralPath $Ini -Value $out -Encoding Unicode
}

# This DLL is in place, with its arkweb.ini pointing at this folder's logs\.
function Installed([string]$Src, [string]$Dir, [string]$Name) {
	$dst = Join-Path $Dir $Name
	$ini = Join-Path $Dir "arkweb.ini"
	if (-not (Test-Path -LiteralPath $dst) -or -not (Test-Path -LiteralPath $ini)) { return $false }
	if ((Get-FileHash -LiteralPath $dst).Hash -ne (Get-FileHash -LiteralPath $Src).Hash) { return $false }
	return @(Get-Content -LiteralPath $ini | Where-Object { $_.Trim() -eq "LogDir=$LogDir" }).Count -gt 0
}

function Put([string]$Src, [string]$Dir, [string]$Name) {
	$dst = Join-Path $Dir $Name
	if ((Test-Path -LiteralPath $dst) -and -not (IsArkWeb $dst) -and -not (Test-Path -LiteralPath "$dst.arkweb-backup")) {
		Move-Item -LiteralPath $dst -Destination "$dst.arkweb-backup"
		Say (T "  another mod's $Name is kept as $Name.arkweb-backup (uninstall.bat puts it back)" "  başka bir modun $Name dosyası $Name.arkweb-backup olarak saklandı (uninstall.bat geri koyar)") Yellow
	}
	Copy-Item -LiteralPath $Src -Destination $dst -Force
	Unblock-File -LiteralPath $dst -ErrorAction SilentlyContinue
	SetLogDir (Join-Path $Dir "arkweb.ini")
	Say ("  $dst") Green
}

function Take([string]$Dir, [string]$Name) {
	$dst = Join-Path $Dir $Name
	if ((Test-Path -LiteralPath $dst) -and (IsArkWeb $dst)) {
		Remove-Item -LiteralPath $dst -Force
		Say (T "  $dst removed" "  $dst silindi") Green
	}
	if ((Test-Path -LiteralPath "$dst.arkweb-backup") -and -not (Test-Path -LiteralPath $dst)) {
		Move-Item -LiteralPath "$dst.arkweb-backup" -Destination $dst
		Say (T "  the other mod's $Name is back" "  diğer modun $Name dosyası geri kondu") Green
	}
	$ini = Join-Path $Dir "arkweb.ini"
	if (Test-Path -LiteralPath $ini) { Remove-Item -LiteralPath $ini -Force }
}

# Both game folders writable, else this script again with administrator rights (Windows asks).
function NeedWrite {
	if ((Writable $ArkhamDir) -and (Writable $SpiderManDir)) { return }
	$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	if ($admin -or $NoAsk) {
		Say (T "Can't write into the game folders." "Oyun klasörlerine yazılamıyor.") Red
		Done 1
	}
	Say (T "The game folders need administrator rights: Windows will ask ..." "Oyun klasörleri yönetici izni istiyor: Windows soracak ...") Yellow
	$a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-ArkhamDir", "`"$ArkhamDir`"", "-SpiderManDir", "`"$SpiderManDir`"")
	if ($Uninstall) { $a += "-Uninstall" }
	try {
		$p = Start-Process -FilePath "powershell.exe" -ArgumentList $a -Verb RunAs -Wait -PassThru
	} catch {
		Say (T "Administrator rights weren't given - nothing was changed." "Yönetici izni verilmedi - hiçbir şey değiştirilmedi.") Red
		Done 1
	}
	exit $p.ExitCode
}

function NotRunning {
	if (@(Get-Process -Name "BatmanAK", "Spider-Man" -ErrorAction SilentlyContinue).Count) {
		Say (T "Close Batman: Arkham Knight and Spider-Man first: their DLLs can't be changed while they run." "Önce Batman: Arkham Knight'ı ve Spider-Man'i kapat: açıkken DLL'leri değiştirilemez.") Red
		Done 1
	}
}

try {
	$ArkhamDir = GameDir $ArkhamDir "Batman: Arkham Knight" $AkExe $AkRel "F:\SteamLibrary\$AkRel"
	$SpiderManDir = GameDir $SpiderManDir "Marvel's Spider-Man Remastered" $SmExe $SmRel "H:\SteamLibrary\$SmRel"
	Say ("Batman: Arkham Knight: $ArkhamDir")
	Say ("Marvel's Spider-Man Remastered: $SpiderManDir")

	if ($Uninstall) {
		NotRunning
		NeedWrite
		Take $ArkhamDir "dinput8.dll"
		Take $SpiderManDir "winmm.dll"
		Say (T "ArkWeb is out of both games." "ArkWeb iki oyundan da kaldırıldı.") Green
		Done 0
	}

	$built = @((Join-Path $Root "bin\ak\dinput8.dll"), (Join-Path $Root "bin\sm\winmm.dll"))
	$pre = @((Join-Path $Root "prebuilt\dinput8.dll"), (Join-Path $Root "prebuilt\winmm.dll"))
	$haveBuilt = (Test-Path -LiteralPath $built[0]) -and (Test-Path -LiteralPath $built[1])
	$havePre = (Test-Path -LiteralPath $pre[0]) -and (Test-Path -LiteralPath $pre[1])
	if (-not $haveBuilt -and -not $havePre) {
		Say (T "No ArkWeb DLLs here: neither bin\ (build.bat makes them, with Visual Studio) nor prebuilt\." "Burada ArkWeb DLL'i yok: ne bin\ (build.bat yapar, Visual Studio ile) ne de prebuilt\.") Red
		Done 1
	}
	$src = $pre
	if ($haveBuilt -and (-not $havePre -or (Get-Item -LiteralPath $built[0]).LastWriteTime -ge (Get-Item -LiteralPath $pre[0]).LastWriteTime)) { $src = $built }
	if ($IfNeeded -and (Installed $src[0] $ArkhamDir "dinput8.dll") -and (Installed $src[1] $SpiderManDir "winmm.dll")) {
		Say (T "ArkWeb is installed and up to date." "ArkWeb kurulu ve güncel.") Green
		exit 0
	}
	Say ((T "DLLs from " "DLL'ler: ") + (Split-Path -Parent $src[0]))
	NotRunning
	NeedWrite
	New-Item -ItemType Directory -Force -Path (Join-Path $LogDir "stream") | Out-Null
	Put $src[0] $ArkhamDir "dinput8.dll"
	Put $src[1] $SpiderManDir "winmm.dll"
	Say ""
	Say (T "ArkWeb is installed. Logs and the streamer's files: $LogDir" "ArkWeb kuruldu. Loglar ve streamer dosyaları: $LogDir") Green
	Say (T "To play: play.bat (starts both games and the streamer)." "Oynamak için: play.bat (iki oyunu ve streamer'ı başlatır).") Green
	Done 0
} catch {
	Say (T "Something went wrong:" "Bir şey ters gitti:") Red
	Say ($_ | Out-String) Red
	Done 1
}
