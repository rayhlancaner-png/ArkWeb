# Starts an ArkWeb session (play.bat runs it).
#
# Installs ArkWeb first if the games don't have this version yet (install.ps1), starts whichever game isn't running
# (through Steam), then the streamer (gotham_stream.py), which waits for both games in the world with Spider-Man
# standing still. Started again while Spider-Man already stands on Gotham, the streamer resumes (--resume). Python
# 3.12 and the streamer's packages are checked first; missing packages are installed, a missing Python with winget
# when you say so.
param(
	[switch]$NoGames,  # don't start the games
	[switch]$Check     # only check Python, the packages and the streamer's imports (CI): no install, no games, no streamer
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$Tools = Join-Path $Root "tools"
$Turkish = (Get-UICulture).TwoLetterISOLanguageName -eq "tr"
$Packages = @("numpy", "scipy", "numba", "pefile", "capstone")

function T([string]$En, [string]$Tr) { if ($Turkish) { $Tr } else { $En } }

function Say([string]$Text, [string]$Color = "Gray") { Write-Host $Text -ForegroundColor $Color }

function Done([int]$Code) {
	if (-not $Check) { Read-Host (T "Press Enter to close" "Kapatmak için Enter'a bas") | Out-Null }
	exit $Code
}

# A Python of 3.10 .. 3.14 (the streamer's packages exist for those).
function PythonOk([object[]]$Cmd) {
	$exe = $Cmd[0]
	$rest = @($Cmd | Select-Object -Skip 1)
	try {
		& $exe @rest -c "import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] < (3, 15) else 1)" *> $null
	} catch {
		return $false
	}
	return $LASTEXITCODE -eq 0
}

# The py launcher's 3.12, a 3.12 where its installer puts it, else python on the PATH.
function FindPython {
	$cands = @()
	foreach ($py in @("py", (Join-Path $env:WINDIR "py.exe"), (Join-Path $env:LOCALAPPDATA "Programs\Python\Launcher\py.exe"))) {
		if (Get-Command $py -ErrorAction SilentlyContinue) { $cands += , @($py, "-3.12") }
	}
	foreach ($exe in @((Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"), (Join-Path $env:ProgramFiles "Python312\python.exe"))) {
		if (Test-Path -LiteralPath $exe) { $cands += , @($exe) }
	}
	foreach ($name in @("python", "python3")) {
		if (Get-Command $name -ErrorAction SilentlyContinue) { $cands += , @($name) }
	}
	foreach ($c in $cands) {
		if (PythonOk $c) { return , $c }
	}
	return $null
}

# ---- ArkWeb in both games ------------------------------------------------------------------------------------------
if (-not $Check) {
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools "install.ps1") -IfNeeded -NoPause
	if ($LASTEXITCODE -ne 0) { Done 1 }
}

# ---- Python and the streamer's packages ----------------------------------------------------------------------------
$py = FindPython
if (-not $py) {
	Say (T "The streamer needs Python 3.12." "Streamer için Python 3.12 gerekiyor.") Yellow
	if (-not $Check -and (Get-Command winget -ErrorAction SilentlyContinue)) {
		$answer = Read-Host (T "Install Python 3.12 now with winget? [Y/n]" "Python 3.12'yi şimdi winget ile kurayım mı? [E/h]")
		if ($answer -notmatch '^\s*[nNhH]') {
			winget install --id Python.Python.3.12 -e --scope user --accept-source-agreements --accept-package-agreements
			$py = FindPython
		}
	}
	if (-not $py) {
		Say (T "Install Python 3.12 (python.org), then start play.bat again." "Python 3.12'yi kur (python.org), sonra play.bat'ı yeniden başlat.") Red
		Done 1
	}
}
$pyExe = $py[0]
$pyArgs = @($py | Select-Object -Skip 1)
Say ("Python: " + ($py -join " "))
& $pyExe @pyArgs -c "import numpy, scipy, numba, pefile, capstone" *> $null
if ($LASTEXITCODE -ne 0) {
	Say (T "Installing the streamer's Python packages (once) ..." "Streamer'ın Python paketleri kuruluyor (bir kerelik) ...") Yellow
	& $pyExe @pyArgs -m pip install --disable-pip-version-check @Packages
	if ($LASTEXITCODE -ne 0) { & $pyExe @pyArgs -m pip install --disable-pip-version-check --user @Packages }
	& $pyExe @pyArgs -c "import numpy, scipy, numba, pefile, capstone" *> $null
	if ($LASTEXITCODE -ne 0) {
		Say (T "The packages didn't install. Python 3.12 is the one they are sure to work with." "Paketler kurulamadı. Kesin çalıştıkları sürüm Python 3.12.") Red
		Done 1
	}
}

Push-Location $Tools
try {
	if ($Check) {
		& $pyExe @pyArgs gotham_stream.py --help *> $null
		$ok = $LASTEXITCODE -eq 0
		Say ("streamer imports " + $(if ($ok) { "ok" } else { "FAILED" }))
		exit $(if ($ok) { 0 } else { 1 })
	}

	# ---- the games ---------------------------------------------------------------------------------------------------
	if (-not $NoGames) {
		try {
			if (-not (Get-Process -Name "Spider-Man" -ErrorAction SilentlyContinue)) {
				Say (T "Starting Marvel's Spider-Man Remastered ..." "Marvel's Spider-Man Remastered başlatılıyor ...")
				Start-Process "steam://rungameid/1817070"
			}
			if (-not (Get-Process -Name "BatmanAK" -ErrorAction SilentlyContinue)) {
				Say (T "Starting Batman: Arkham Knight ..." "Batman: Arkham Knight başlatılıyor ...")
				Start-Process "steam://rungameid/208650"
			}
		} catch {
			Say (T "Steam didn't start the games: start them yourself." "Steam oyunları başlatamadı: kendin başlat.") Yellow
		}
	}

	# ---- the streamer ------------------------------------------------------------------------------------------------
	$streamArgs = @()
	$state = & $pyExe @pyArgs arkweb_state.py 2> $null | Select-Object -Last 1
	if ("$state".Trim() -eq "1") {
		$streamArgs += "--resume"
		Say (T "Spider-Man already stands on Gotham: the streamer carries on (--resume)." "Spider-Man zaten Gotham'da: streamer kaldığı yerden devam ediyor (--resume).") Cyan
	} else {
		Say ""
		Say (T "Load into the open world in both games (Batman on a street), then:" "İki oyunda da açık dünyaya gir (Batman bir sokakta olsun), sonra:") Cyan
		Say (T "  - stand still with Spider-Man for a few seconds: the streamer builds Gotham around him and lifts him onto it" "  - Spider-Man'le birkaç saniye hareketsiz dur: streamer etrafına Gotham'ı kurup onu üstüne çıkarır") Cyan
		Say (T "  - keep Arkham Knight in front: you play in its window" "  - Arkham Knight'ı önde tut: onun penceresinde oynuyorsun") Cyan
		Say (T "  - keep this window open while you play (Ctrl+C stops the streamer)" "  - oynarken bu pencereyi açık bırak (Ctrl+C streamer'ı durdurur)") Cyan
		Say ""
	}
	& $pyExe @pyArgs gotham_stream.py @streamArgs
	Say (T "The streamer stopped." "Streamer durdu.") Yellow
} finally {
	Pop-Location
}
Done 0
