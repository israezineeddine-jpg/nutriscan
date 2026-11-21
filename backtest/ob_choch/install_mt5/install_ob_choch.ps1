# install_ob_choch.ps1
# Installe OB_CHoCH_M1.mq5 dans MetaTrader 5, le compile avec MetaEditor, lance le backtest
# (Strategy Tester, real ticks) et rassemble le rapport + la liste des trades dans un dossier sur le Bureau.
# Lancer avec INSTALL_OB_CHoCH.bat (double-clic). Compatible Windows PowerShell 5.1.

param(
    [switch]$NoTest,                 # installer et compiler seulement
    [string]$Symbol  = "XAUUSD",
    [string]$From    = "2023.01.01",
    [string]$To      = "",           # vide = aujourd'hui
    [int]$Deposit    = 100000
)

$ErrorActionPreference = "Stop"
$EA = "OB_CHoCH_M1"

function Say($msg, $color = "Gray") { Write-Host $msg -ForegroundColor $color }
function Fail($msg) {
    Say ""
    Say "ERREUR : $msg" "Red"
    Say "Envoie une capture de cette fenetre a Claude." "Yellow"
    exit 1
}
function Clean($text) { if ($null -eq $text) { return "" } return ($text -replace "`0", "").Trim() }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here "$EA.mq5"
if (-not (Test-Path $src)) { Fail "le fichier $EA.mq5 doit etre dans le meme dossier que ce script ($here)." }
if ($To -eq "") { $To = (Get-Date).ToString("yyyy.MM.dd") }

Say "=== OB + CHoCH M1 : installation dans MetaTrader 5 ===" "Cyan"

# ---------------------------------------------------------------
# 1) Trouver les terminaux MetaTrader 5 installes
# ---------------------------------------------------------------
$terms = @()
$root = Join-Path $env:APPDATA "MetaQuotes\Terminal"
if (Test-Path $root) {
    foreach ($d in Get-ChildItem $root -Directory) {
        $experts = Join-Path $d.FullName "MQL5\Experts"
        $origin  = Join-Path $d.FullName "origin.txt"
        if ((Test-Path $experts) -and (Test-Path $origin)) {
            $inst = Clean (Get-Content $origin -Raw)
            if ($inst -ne "" -and (Test-Path (Join-Path $inst "terminal64.exe"))) {
                $terms += [pscustomobject]@{ Data = $d.FullName; Install = $inst }
            }
        }
    }
}
# installations en mode portable (dossier MQL5 a cote de terminal64.exe), sur tous les disques (C:, D:, ...)
$places = @()
foreach ($drv in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    $r = $drv.Root
    if (-not $r -or -not (Test-Path $r)) { continue }
    $places += $r
    foreach ($sub in @("Program Files", "Program Files (x86)")) {
        $p = Join-Path $r $sub
        if (Test-Path $p) { $places += $p }
    }
}
foreach ($pf in $places) {
    $cands = @()
    $cands += Get-ChildItem $pf -Directory -ErrorAction SilentlyContinue
    foreach ($d1 in @($cands)) { $cands += Get-ChildItem $d1.FullName -Directory -ErrorAction SilentlyContinue }
    foreach ($d in $cands) {
        if ((Test-Path (Join-Path $d.FullName "terminal64.exe")) -and (Test-Path (Join-Path $d.FullName "MQL5\Experts"))) {
            if (-not ($terms | Where-Object { $_.Install -eq $d.FullName })) {
                $terms += [pscustomobject]@{ Data = $d.FullName; Install = $d.FullName }
            }
        }
    }
}
if ($terms.Count -eq 0) { Fail "aucun MetaTrader 5 trouve. Ouvre MT5 une fois, puis relance ce script." }

$t = $terms[0]
if ($terms.Count -gt 1) {
    Say ""
    Say "Plusieurs MetaTrader 5 trouves :" "Yellow"
    for ($i = 0; $i -lt $terms.Count; $i++) { Say ("  [{0}] {1}" -f ($i + 1), $terms[$i].Install) "White" }
    $k = Read-Host "Numero du MetaTrader a utiliser (ex: 1)"
    $n = 0
    if (-not [int]::TryParse($k, [ref]$n) -or $n -lt 1 -or $n -gt $terms.Count) { Fail "numero invalide." }
    $t = $terms[$n - 1]
}
$data = $t.Data
$inst = $t.Install
Say ""
Say "MetaTrader : $inst" "Green"
Say "Donnees    : $data" "Green"

# ---------------------------------------------------------------
# 2) Copier l'EA dans MQL5\Experts
# ---------------------------------------------------------------
$dest = Join-Path $data "MQL5\Experts\$EA.mq5"
Copy-Item $src $dest -Force
Say "EA copie dans MQL5\Experts" "Green"

# ---------------------------------------------------------------
# 3) Compiler avec MetaEditor
# ---------------------------------------------------------------
$me = Join-Path $inst "metaeditor64.exe"
if (-not (Test-Path $me)) { Fail "metaeditor64.exe introuvable dans $inst" }
$ex5 = Join-Path $data "MQL5\Experts\$EA.ex5"
$log = Join-Path $data "MQL5\Experts\$EA.log"
if (Test-Path $log) { Remove-Item $log -Force }
$before = [datetime]::MinValue
if (Test-Path $ex5) { $before = (Get-Item $ex5).LastWriteTime }
Say "Compilation..." "Gray"
Start-Process -FilePath $me -ArgumentList @("/compile:`"$dest`"", "/log") -Wait
$logText = ""
if (Test-Path $log) { $logText = Clean (Get-Content $log -Raw) }
$lines = $logText -split "`r?`n" | Where-Object { $_ -match "error|warning|Result" }
foreach ($l in $lines) { Say ("  " + $l.Trim()) "DarkGray" }
$compiled = (Test-Path $ex5) -and ((Get-Item $ex5).LastWriteTime -gt $before)
if (-not $compiled) { Fail "la compilation a echoue (voir les lignes ci-dessus et le fichier $log)." }
Say "Compilation OK : $EA.ex5" "Green"

if ($NoTest) {
    Say ""
    Say "Installation terminee. Dans MT5 : Navigator > Expert Advisors > $EA" "Cyan"
    exit 0
}

# ---------------------------------------------------------------
# 4) Backtest dans le Strategy Tester (MT5 doit etre ferme)
# ---------------------------------------------------------------
function Running {
    $p = Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst) }
    return ($null -ne $p)
}
while (Running) {
    Say ""
    Say "MetaTrader 5 est ouvert. Ferme-le (le compte doit rester enregistre), puis appuie sur Entree." "Yellow"
    [void](Read-Host)
}

$report = "OB_CHoCH_report"
$ini = Join-Path $data "ob_choch_tester.ini"
$iniText = @"
[Tester]
Expert=$EA.ex5
Symbol=$Symbol
Period=M1
Optimization=0
Model=4
FromDate=$From
ToDate=$To
ForwardMode=0
Deposit=$Deposit
Currency=USD
Leverage=1:100
ExecutionMode=0
Visual=0
Report=$report
ReplaceReport=1
ShutdownTerminal=1
"@
Set-Content -Path $ini -Value $iniText -Encoding Unicode
Say ""
Say "Backtest $Symbol M1, real ticks, du $From au $To, depot $Deposit USD." "Cyan"
Say "MT5 va s'ouvrir, tester puis se fermer tout seul (cela peut prendre 10 a 40 minutes)." "Cyan"
$start = Get-Date
Start-Process -FilePath (Join-Path $inst "terminal64.exe") -ArgumentList @("/config:`"$ini`"") -Wait

# ---------------------------------------------------------------
# 5) Rassembler les resultats sur le Bureau
# ---------------------------------------------------------------
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "OB_CHoCH_resultats"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$found = 0
foreach ($dir in @($data, $inst)) {
    foreach ($f in Get-ChildItem $dir -File -Filter "$report*" -ErrorAction SilentlyContinue) {
        if ($f.LastWriteTime -ge $start) { Copy-Item $f.FullName $out -Force; $found++ }
    }
}
$csv = $null
foreach ($testerRoot in @((Join-Path $env:APPDATA "MetaQuotes\Tester"), (Join-Path $inst "Tester"))) {
    if ($null -eq $csv -and (Test-Path $testerRoot)) {
        $csv = Get-ChildItem $testerRoot -Recurse -File -Filter "OB_CHoCH_trades.csv" -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -ge $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
}
if ($csv) { Copy-Item $csv.FullName $out -Force; $found++ }

Say ""
if ($found -eq 0) {
    Say "Aucun resultat trouve. Ouvre MT5 : le compte est-il connecte ? XAUUSD existe-t-il chez ce broker ?" "Red"
    Say "Tu peux aussi lancer le test a la main : Ctrl+R dans MT5, Expert = $EA." "Yellow"
} else {
    Say "Termine. Resultats dans : $out" "Green"
    Say "Envoie a Claude le rapport ($report.htm) et OB_CHoCH_trades.csv." "Green"
    Start-Process explorer.exe $out
}
