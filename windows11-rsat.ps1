# =================================================================
# RSAT Eszközök telepítő szkriptje Windows 11 alá
# Cél: Active Directory és DNS kezelő eszközök telepítése (RSAT)
# Készítette: DevOFALL
# =================================================================

# Színkódok a konzolhoz (ha a környezet támogatja)
$CLR_GREEN = "`e[32m"
$CLR_RED = "`e[31m"
$CLR_YELLOW = "`e[33m"
$CLR_RESET = "`e[0m"

Function Write-Info {
    param([string]$Message)
    Write-Host "$CLR_GREEN✅ Sikeres:$CLR_RESET $Message"
}

Function Write-Warning {
    param([string]$Message)
    Write-Host "$CLR_YELLOW⚠️  Figyelem:$CLR_RESET $Message"
}

Function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "$CLR_RED❌ HIBA:$CLR_RESET $Message"
}

# --- 1. Ellenőrzés és előkészület ---
Write-Host "================================================================"
Write-Host "RSAT Eszközök telepítése Windows 11 / 10 alatt"
Write-Host "================================================================"

# Ellenőrizzük, hogy rendszergazdaként fut-e
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-ErrorMsg "A szkript futtatásához Rendszergazdai (Administrator) jogok szükségesek."
    Write-ErrorMsg "Indítsa újra a PowerShell-t 'Futtatás rendszergazdaként' opcióval."
    exit 1
}

# Az RSAT (Active Directory Domain Services és DNS) csomagok nevei
$RSAT_PACKAGES = @(
    "Rsat.ActiveDirectory.DS.LDS.Tools",  # Active Directory felhasználók és számítógépek, stb.
    "Rsat.Dns.Tools"                      # DNS-kezelő
)

Write-Host "▶️ Telepítendő RSAT funkciók:"
$RSAT_PACKAGES | ForEach-Object { Write-Host "   - $_" }
Write-Host ""


# --- 2. Telepítés ---
Write-Host "================================================================"
Write-Host "RSAT Csomagok telepítése (Add-WindowsCapability)"
Write-Host "================================================================"

$ErrorsFound = $false

foreach ($Package in $RSAT_PACKAGES) {
    Write-Host "$CLR_YELLOWℹ️  Telepítés megkezdése: $Package...$CLR_RESET"
    
    # A Get-WindowsCapability ellenőrzi, hogy már telepítve van-e,
    # majd az Add-WindowsCapability telepíti.
    try {
        $Status = Get-WindowsCapability -Online -Name $Package | Select-Object -ExpandProperty State

        if ($Status -eq "Installed") {
            Write-Warning "$Package már telepítve van. Kihagyás."
            continue
        }

        Add-WindowsCapability -Online -Name $Package -ErrorAction Stop
        Write-Info "$Package sikeresen telepítve."
    }
    catch {
        Write-ErrorMsg "Hiba történt a(z) $Package telepítése közben."
        Write-ErrorMsg "Hibaüzenet: $($_.Exception.Message)"
        $ErrorsFound = $true
    }
    Write-Host ""
}


# --- 3. Összefoglalás és Teszt ---
Write-Host "================================================================"
Write-Host "Telepítési összefoglaló"
Write-Host "================================================================"

if ($ErrorsFound) {
    Write-ErrorMsg "A telepítés RÉSZBEN sikertelen! Ellenőrizze a fenti hibaüzeneteket."
    Write-ErrorMsg "Lehetséges okok: internetkapcsolat hiánya vagy frissítési beállítások korlátozása."
}
else {
    Write-Info "Minden kiválasztott RSAT eszköz sikeresen telepítve."
}

Write-Host ""
Write-Host "▶️ Következő lépés: A csatlakozás ellenőrzése a Samba AD DC-hez."
Write-Host "    1. Keresse meg a 'Felügyeleti eszközök' mappát a Start menüben."
Write-Host "    2. Indítsa el az 'Active Directory - felhasználók és számítógépek' (dsa.msc) eszközt."
Write-Host "    3. Indítsa el a 'DNS' (dnsmgmt.msc) eszközt."

# =================================================================
