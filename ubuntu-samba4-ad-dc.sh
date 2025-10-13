#!/bin/bash
# A szkript futtatása: chmod +x ubuntu-samba4-ad-dc.sh && sudo ./ubuntu-samba4-ad-dc.sh

# ==============================================================================
# Samba 4 Active Directory Tartományvezérlő Telepítő Szkript 
# Verzió: V7.2 (Frissítés menüpont hozzáadva)
# Rendszer: Ubuntu 22.04 / 24.04+
#
# Változások V7.2:
# - FELHASZNÁLÓI ÉLMÉNY: Új 10. menüpont hozzáadva: Rendszer Frissítés (apt update/upgrade).
# - VÁLTOZÁSOK V7.1: A "Teszt felhasználó" átnevezve "Első felhasználóra".
# - HIBAKERESÉS V7.1: /etc/resolv.conf ellenőrzés a teszt funkcióban.
# ==============================================================================

# ------------------------------------------------------------------------------
# Színkódok és Stílusok
# ------------------------------------------------------------------------------
NARANCS='\033[0;38;5;208m'
SARGA='\033[0;33m'
LILA='\033[0;35m'
ZOLD='\033[0;32m'
PIROS='\033[0;31m'
VASTAG='\033[1m'
NORMAL='\033[0m'
LOG_FILE="/var/log/samba_installation_$(date +%Y%m%d_%H%M%S).log"

# Globális változók
HOSTNAME_FQDN=""
REALM=""
DOMAIN_NETBIOS=""
DNS_FORWARDER=""
ADMIN_PASSWORD=""
FIRST_USER=""
FIRST_USER_PASSWORD=""
REALM_LOWER=""

# Állapotváltozók
TIME_SYNC_STATUS="N/A"
SAMBA_AD_DC_STATUS="N/A"
DNS_STATUS="N/A"
KERBEROS_STATUS="N/A"

# ------------------------------------------------------------------------------
# Segéd Funkciók
# ------------------------------------------------------------------------------

szin_kiir() {
    local COLOR_NAME="$1"
    local TEXT="$2"
    local COLOR_CODE
    case "$COLOR_NAME" in
        NARANCS) COLOR_CODE="$NARANCS" ;; SARGA) COLOR_CODE="$SARGA" ;; LILA) COLOR_CODE="$LILA" ;;
        ZOLD) COLOR_CODE="$ZOLD" ;; PIROS) COLOR_CODE="$PIROS" ;; VASTAG) COLOR_CODE="$VASTAG" ;;
        *) COLOR_CODE="" ;;
    esac
    echo -e "${COLOR_CODE}${VASTAG}${TEXT}${NORMAL}"
}

setup_logging() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    szin_kiir ZOLD "Minden művelet logolva: $LOG_FILE"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
}

get_password() {
    local prompt="$1"
    local var_name="$2"
    local min_length="${3:-8}"
    local TEMP_PASSWORD TEMP_PASSWORD_CONFIRM
    while true; do
        read -r -s -p "$(szin_kiir ZOLD "$prompt (min. $min_length karakter): ")" TEMP_PASSWORD; echo
        read -r -s -p "$(szin_kiir ZOLD "Ismételd meg a jelszót: ")" TEMP_PASSWORD_CONFIRM; echo
        if [[ "$TEMP_PASSWORD" == "$TEMP_PASSWORD_CONFIRM" ]]; then
            if [[ ${#TEMP_PASSWORD} -ge $min_length ]]; then
                printf -v "$var_name" '%s' "$TEMP_PASSWORD"
                return 0
            else szin_kiir PIROS "A jelszó túl rövid. Kérlek, legalább $min_length karaktert használj."; fi
        else szin_kiir PIROS "A jelszavak nem egyeznek. Kérlek, próbáld újra."; fi
    done
}

provision_domain() {
    local attempts=3
    while [ $attempts -gt 0 ]; do
        szin_kiir NARANCS "Tartomány provisioning indítása. Próbálkozás $attempts..."
        if samba-tool domain provision --use-rfc2307 --realm="$REALM" --domain="$DOMAIN_NETBIOS" --server-role="dc" --dns-backend="SAMBA_INTERNAL" --adminpass="$ADMIN_PASSWORD"; then
            szin_kiir ZOLD "Tartomány provisioning sikeres!"; return 0
        fi
        ((attempts--)); szin_kiir SARGA "Provision sikertelen, újrapróbálás ($attempts maradt)..."; sleep 5
    done
    szin_kiir PIROS "HIBA: A samba-tool domain provision sikertelen volt 3 próbálkozás után."; return 1
}

# ------------------------------------------------------------------------------
# Rendszerkezelő Funkciók (Új V7.2)
# ------------------------------------------------------------------------------

run_update_upgrade() {
    szin_kiir LILA "--- Rendszer Frissítés Indítása (apt update & upgrade) ---"
    if apt update; then
        szin_kiir ZOLD "✓ Csomaglista frissítése sikeres."
        read -r -p "$(szin_kiir NARANCS 'Kezdjem a csomagok frissítését (apt upgrade -y)? (i/n): ')" VALASZTAS
        if [[ "$VALASZTAS" =~ ^[Ii]$ ]]; then
            if apt upgrade -y; then
                szin_kiir ZOLD "✓ Rendszerfrissítés sikeresen befejeződött!"
            else
                szin_kiir PIROS "HIBA: Rendszerfrissítés sikertelen!"
            fi
        else
            szin_kiir SARGA "Csomagfrissítés kihagyva."
        fi
    else
        szin_kiir PIROS "HIBA: A csomaglista frissítése (apt update) sikertelen! Ellenőrizze az internetkapcsolatot/forrásokat."
    fi
    szin_kiir LILA "--- Rendszer Frissítés Befejezve ---"
    echo
}

# ------------------------------------------------------------------------------
# Előfeltétel és Rendszer Ellenőrzések
# ------------------------------------------------------------------------------

check_basic_environment() {
    szin_kiir LILA "--- Alapvető Kompatibilitás Ellenőrzése ---"
    if [ "$EUID" -ne 0 ]; then szin_kiir PIROS "HIBA: ROOT jogosultsággal (sudo) kell futtatni!"; exit 1; else szin_kiir ZOLD "✓ Root jogosultság rendben."; fi
    if ! command -v apt &> /dev/null; then szin_kiir PIROS "HIBA: Debian/Ubuntu alapú rendszert igényel."; exit 1; else szin_kiir ZOLD "✓ APT csomagkezelő rendben."; fi
    szin_kiir LILA "--- Alapvető Ellenőrzések Befejezve ---"
}

check_prerequisites() { 
    szin_kiir LILA "--- Rendszer Előfeltételek Ellenőrzése ---"
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}')
    if [[ -z "$ip_addr" ]] || [[ "$ip_addr" =~ ^127\. ]] || [[ "$ip_addr" =~ ^169\.254\. ]]; then
        szin_kiir PIROS "HIBA: Statikus IP hiányzik vagy nem megfelelő ($ip_addr). A DC-nek statikus IP-vel kell rendelkeznie!"
    else szin_kiir ZOLD "✓ Statikus IP ($ip_addr) ellenőrzés sikeres."; fi
    local current_hostname; current_hostname=$(hostname -f)
    if [[ "$current_hostname" != "$HOSTNAME_FQDN" ]]; then
        szin_kiir PIROS "HIBA: A rendszer hostname-je ($current_hostname) NEM egyezik a kívánt FQDN-nel ($HOSTNAME_FQDN)."; return 1
    else szin_kiir ZOLD "✓ Hostname ($current_hostname) rendben."; fi
    szin_kiir LILA "--- Előfeltételek Ellenőrzése Befejezve ---"; return 0
}

# ------------------------------------------------------------------------------
# Fő Konfigurációs Menü Rendszer
# ------------------------------------------------------------------------------

display_config() {
    HOSTNAME_DISPLAY=${HOSTNAME_FQDN:-"NINCS BEÁLLÍTVA"}
    REALM_DISPLAY=${REALM:-"NINCS BEÁLLÍTVA"}
    NETBIOS_DISPLAY=${DOMAIN_NETBIOS:-"NINCS BEÁLLÍTVA"}
    DNS_DISPLAY=${DNS_FORWARDER:-"NINCS"}
    PASSWORD_DISPLAY=${ADMIN_PASSWORD:+BEÁLLÍTVA}
    FIRST_USER_DISPLAY=${FIRST_USER:-"NINCS BEÁLLÍTVA"}
    USER_PASSWORD_DISPLAY=${FIRST_USER_PASSWORD:+BEÁLLÍTVA}

    szin_kiir LILA "======================================================"
    szin_kiir LILA " ⚙️ Samba 4 AD DC Konfigurációs Menü"
    szin_kiir LILA "======================================================"
    echo -e "  $(szin_kiir VASTAG "1. Szerver Hostname (FQDN):") ${HOSTNAME_DISPLAY}"
    echo -e "  $(szin_kiir VASTAG "2. Tartomány (REALM) név:")     ${REALM_DISPLAY}"
    echo -e "  $(szin_kiir VASTAG "3. NetBIOS név:")               ${NETBIOS_DISPLAY}"
    echo -e "  $(szin_kiir VASTAG "4. DNS Továbbító IP:")          ${DNS_DISPLAY} (Opcionális)"
    echo -e "  $(szin_kiir VASTAG "5. Adminisztrátor Jelszó:")     ${PASSWORD_DISPLAY}"
    szin_kiir LILA "------------------------------------------------------"
    echo -e "  $(szin_kiir VASTAG "6. Első Felhasználó Név:")      ${FIRST_USER_DISPLAY}"
    echo -e "  $(szin_kiir VASTAG "7. Első Felhasználó Jelszó:")   ${USER_PASSWORD_DISPLAY}"
    szin_kiir LILA "------------------------------------------------------"
    echo -e "  $(szin_kiir VASTAG "8. Telepítés és Konfigurálás Indítása")"
    echo -e "  $(szin_kiir VASTAG "9. Futó Rendszer Tesztelése") (Telepítés után)"
    echo -e "  $(szin_kiir VASTAG "10. Rendszer Frissítés (apt update/upgrade)")" # ÚJ PONT
    echo -e "  $(szin_kiir VASTAG "0. Kilépés a szkriptből")"
    echo
}

configure_menu() {
    while true; do
        if [[ -n "$REALM" ]]; then REALM_LOWER=$(echo "$REALM" | tr '[:upper:]' '[:lower:]'); fi
        display_config
        read -r -p "$(szin_kiir NARANCS 'Válassz egy opciót (1-10, 0 a kilépéshez): ')" CHOICE # Frissített prompt
        case "$CHOICE" in
            1) szin_kiir NARANCS "Add meg a DC teljes gépnevét (FQDN, pl. dc01.cegnev.local)."; szin_kiir SARGA "FIGYELEM: KISBETŰSRE lesz konvertálva."
                read -r -p "$(szin_kiir ZOLD "Hostname FQDN: ")" HOSTNAME_TEMP
                if [[ -n "$HOSTNAME_TEMP" ]]; then HOSTNAME_FQDN=$(echo "$HOSTNAME_TEMP"|tr '[:upper:]' '[:lower:]'); else szin_kiir PIROS "Hostname megadása kötelező."; fi ;;
            2) szin_kiir NARANCS "Add meg a teljes tartománynevet (REALM, pl. CEGNEV.LOCAL)."; szin_kiir SARGA "FIGYELEM: NAGYBETŰSRE lesz konvertálva."
                read -r -p "$(szin_kiir ZOLD "REALM: ")" REALM_TEMP
                if [[ -n "$REALM_TEMP" ]]; then REALM=$(echo "$REALM_TEMP"|tr '[:lower:]' '[:upper:]'); else szin_kiir PIROS "Tartomány név megadása kötelező."; fi ;;
            3) szin_kiir NARANCS "Add meg a rövid, NetBIOS nevet (pl. CEGNEV)."; szin_kiir SARGA "FIGYELEM: NAGYBETŰSRE lesz konvertálva."
                read -r -p "$(szin_kiir ZOLD "NetBIOS Név: ")" NETBIOS_TEMP
                if [[ -n "$NETBIOS_TEMP" ]]; then DOMAIN_NETBIOS=$(echo "$NETBIOS_TEMP"|tr '[:lower:]' '[:upper:]'); else szin_kiir PIROS "NetBIOS név megadása kötelező."; fi ;;
            4) szin_kiir NARANCS "Add meg a DNS továbbító IP-címét (pl. 8.8.8.8). Hagyd üresen, ha nincs."
                read -r -p "$(szin_kiir ZOLD "DNS Továbbító IP: ")" DNS_FORWARDER ;;
            5) szin_kiir NARANCS "Adminisztrátor jelszó beállítása."; get_password "Adminisztrátor Jelszava" "ADMIN_PASSWORD" 8 ;;
            6) 
                szin_kiir NARANCS "Add meg az első tartományi felhasználó nevét (pl. gipsz.jakab). KISBETŰS javasolt."
                read -r -p "$(szin_kiir ZOLD "Felhasználó Név: ")" FIRST_USER
                if [[ -z "$FIRST_USER" ]]; then szin_kiir PIROS "Felhasználó név megadása kötelező."; fi ;;
            7) 
                szin_kiir NARANCS "Első felhasználó jelszavának beállítása."
                if [[ -z "$FIRST_USER" ]]; then szin_kiir PIROS "Előbb add meg a 6. pontban a felhasználó nevét!"; else get_password "${FIRST_USER} JELSZAVA" "FIRST_USER_PASSWORD" 8; fi ;;
            8) if [[ -z "$HOSTNAME_FQDN" || -z "$REALM" || -z "$DOMAIN_NETBIOS" || -z "$ADMIN_PASSWORD" || -z "$FIRST_USER" || -z "$FIRST_USER_PASSWORD" ]]; then
                    szin_kiir PIROS "HIBA: Minden mező (1,2,3,5,6,7) kitöltése kötelező!"; sleep 2
                else
                    szin_kiir ZOLD "Konfiguráció kész. Telepítés indul..."
                    szin_kiir NARANCS "Rendszer hostname beállítása..."
                    hostnamectl set-hostname "$HOSTNAME_FQDN"
                    echo -e "127.0.0.1\tlocalhost" > /etc/hosts
                    echo -e "$(hostname -I | awk '{print $1}')\t$HOSTNAME_FQDN\t$(hostname -s)" >> /etc/hosts
                    if check_prerequisites; then run_installation; post_installation_tests; print_final_summary; else szin_kiir PIROS "Telepítés megszakítva az előfeltételek miatt."; fi
                    return 0
                fi ;;
            9) szin_kiir LILA "--- Rendszer Tesztelése (Menüpont) ---"
                if [[ -z "$REALM_LOWER" ]]; then szin_kiir PIROS "Előbb állítsd be a tartománynevet (2. pont)!"; sleep 2; continue; fi
                if [[ -z "$ADMIN_PASSWORD" ]]; then szin_kiir NARANCS "A teszthez add meg az Adminisztrátor jelszavát."; get_password "Adminisztrátor Jelszava" "ADMIN_PASSWORD" 8; fi
                post_installation_tests; print_test_summary ;;
            10) run_update_upgrade ;; # ÚJ PONT KEZELÉSE

            0) szin_kiir PIROS "Kilépés."; exit 0 ;;
            *) szin_kiir PIROS "Érvénytelen választás."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# FŐ TELEPÍTÉSI FOLYAMAT
# ------------------------------------------------------------------------------

run_installation() {
    szin_kiir ZOLD "*** TELEPÍTÉSI FOLYAMAT INDUL ***"; echo
    backup_system
    szin_kiir LILA "--- 0. Rendszer Előkészítése, Függőségek Telepítése ---"
    apt update && apt upgrade -y
    export DEBIAN_FRONTEND=noninteractive
    echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
    apt -y install acl attr samba-ad-dc smbclient krb5-user dnsutils chrony net-tools
    systemctl enable --now chrony; szin_kiir ZOLD "✓ chrony szolgáltatás fut."
    szin_kiir LILA "--- 1. Samba Konfigurálása és DNS Beállítások ---"
    if [ -f /etc/samba/smb.conf ]; then mv /etc/samba/smb.conf /etc/samba/smb.conf.org; fi
    if ! provision_domain; then exit 1; fi
    if [[ -n "$DNS_FORWARDER" ]]; then
        szin_kiir NARANCS "DNS továbbító beállítása: $DNS_FORWARDER"
        sed -i "/\[global\]/a \        dns forwarder = $DNS_FORWARDER" /etc/samba/smb.conf
    fi
    szin_kiir NARANCS "KRITIKUS: /etc/resolv.conf beállítása 127.0.0.1-re."
    echo -e "# Generated by samba4-ad-dc.sh (v7.2)\ndomain $REALM_LOWER\nsearch $REALM_LOWER\nnameserver 127.0.0.1" > /etc/resolv.conf
    if command -v chattr &> /dev/null; then chattr +i /etc/resolv.conf; szin_kiir ZOLD "✓ /etc/resolv.conf sikeresen zárolva."; else szin_kiir SARGA "FIGYELEM: chattr parancs hiányzik, /etc/resolv.conf nincs zárolva."; fi
    systemctl stop systemd-resolved 2>/dev/null; systemctl disable systemd-resolved 2>/dev/null
    systemctl stop smbd nmbd winbind 2>/dev/null; systemctl disable smbd nmbd winbind 2>/dev/null; systemctl mask smbd nmbd winbind 2>/dev/null
    systemctl unmask samba-ad-dc 2>/dev/null; systemctl enable --now samba-ad-dc
    if ! systemctl is-active --quiet samba-ad-dc; then szin_kiir PIROS "HIBA: samba-ad-dc szolgáltatás indítása sikertelen."; exit 1; fi
    cp /var/lib/samba/private/krb5.conf /etc/
    szin_kiir LILA "--- 2. Első Felhasználó Létrehozása ---"
    if samba-tool user create "$FIRST_USER" --given-name="${FIRST_USER%%.*}" --surname="${FIRST_USER#*.}" --random-password; then
        if samba-tool user setpassword "$FIRST_USER" --newpassword="$FIRST_USER_PASSWORD"; then
            szin_kiir ZOLD "✓ Felhasználó '${VASTAG}$FIRST_USER${NORMAL}' sikeresen létrehozva és jelszó beállítva!"
        else szin_kiir PIROS "HIBA: A felhasználó jelszavának beállítása sikertelen! (A jelszó nem felel meg a komplexitási követelményeknek?)"; fi
    else szin_kiir PIROS "HIBA: A felhasználó létrehozása sikertelen! (Lehet, hogy már létezik?)"; fi
    configure_firewall
}

# ------------------------------------------------------------------------------
# TESZTELÉSI ÉS ÖSSZEFOGLALÓ FUNKCIÓK
# ------------------------------------------------------------------------------

check_time_sync() { 
    if chronyc sources | grep -q "^\^\*"; then TIME_SYNC_STATUS="${ZOLD}SZINKRONIZÁLT${NORMAL}"; else TIME_SYNC_STATUS="${PIROS}NINCS SZINKRON${NORMAL}"; fi
}

post_installation_tests() { 
    szin_kiir LILA "--- 9. RENDSZER TESZTELÉS INDÍTÁSA ---"
    check_time_sync; echo "Idő szinkronizáció: $TIME_SYNC_STATUS"
    if systemctl is-active --quiet samba-ad-dc; then SAMBA_AD_DC_STATUS="${ZOLD}AKTÍV${NORMAL}"; else SAMBA_AD_DC_STATUS="${PIROS}INAKTÍV${NORMAL}"; fi
    echo "Samba AD DC szolgáltatás: $SAMBA_AD_DC_STATUS"
    
    # V7.1: Új, dedikált DNS resolver ellenőrzés
    szin_kiir NARANCS "Alapvető DNS beállítás ellenőrzése (/etc/resolv.conf)..."
    if ! grep -q "^\s*nameserver\s*127.0.0.1" /etc/resolv.conf; then
        szin_kiir PIROS "KRITIKUS HIBA: A /etc/resolv.conf NINCS megfelelően beállítva!"
        szin_kiir SARGA "A 'nameserver 127.0.0.1' sornak szerepelnie kell benne, különben a tesztek sikertelenek lesznek."
        DNS_STATUS="${PIROS}HIBA (resolv.conf)${NORMAL}"
    else
        szin_kiir ZOLD "✓ /etc/resolv.conf rendben, a szerver önmagát használja DNS-re."
        szin_kiir NARANCS "DNS Teszt: SRV rekord feloldás..."
        if host -t SRV "_ldap._tcp.$REALM_LOWER" | grep -q "$HOSTNAME_FQDN"; then 
            DNS_STATUS="${ZOLD}MŰKÖDIK${NORMAL}"; echo "✓ DNS Feloldás: $DNS_STATUS"
        else DNS_STATUS="${PIROS}HIBA${NORMAL}"; echo "❌ DNS Feloldás: $DNS_STATUS"; fi
    fi

    szin_kiir NARANCS "Kerberos Teszt: Jegy kérés (administrator@$REALM)..."
    if echo "$ADMIN_PASSWORD" | kinit "administrator@$REALM" > /dev/null 2>&1; then 
        KERBEROS_STATUS="${ZOLD}MŰKÖDIK${NORMAL}"; echo "✓ Kerberos: $KERBEROS_STATUS"; klist; kdestroy > /dev/null 2>&1
    else KERBEROS_STATUS="${PIROS}HIBA${NORMAL}"; echo "❌ Kerberos: $KERBEROS_STATUS (KDC nem található vagy rossz jelszó)"; fi
    szin_kiir LILA "--- Tesztek Befejezve ---"
}

print_test_summary() {
    szin_kiir ZOLD "VÉGSŐ ÁLLAPOT ELLENŐRZÉS:"
    szin_kiir LILA "------------------------------------------------------"
    echo -e "  - Samba AD DC:          $SAMBA_AD_DC_STATUS"
    echo -e "  - DNS (SRV feloldás):   $DNS_STATUS"
    echo -e "  - Kerberos (jegy):      $KERBEROS_STATUS"
    echo -e "  - Időszinkronizáció:    $TIME_SYNC_STATUS"
    szin_kiir LILA "------------------------------------------------------"
}

print_final_summary() {
    szin_kiir LILA "======================================================"
    szin_kiir LILA " Telepítés Befejezve! 🎉"
    szin_kiir LILA "======================================================"
    print_test_summary
    szin_kiir SARGA "KRITIKUS ADATOK ÖSSZEFOGLALÓJA:"
    szin_kiir NARANCS "  Hostname (FQDN):            $HOSTNAME_FQDN"
    szin_kiir NARANCS "  Tartomány (DNS):            $REALM_LOWER"
    szin_kiir NARANCS "  Kerberos Realm:             $REALM"
    szin_kiir NARANCS "  NetBIOS Név:                $DOMAIN_NETBIOS"
    szin_kiir NARANCS "  Adminisztrátor:             administrator"
    szin_kiir NARANCS "  Létrehozott felhasználó:    $FIRST_USER"
    echo
    szin_kiir ZOLD "Sikeres tartományi működést kívánok!"
    szin_kiir ZOLD "Javaslat: Indítsd újra a szervert a 'sudo reboot' paranccsal."
}

# ------------------------------------------------------------------------------
# FŐ PROGRAM INDÍTÁS (main és segéd-funkciók)
# ------------------------------------------------------------------------------

backup_system() { 
    read -r -p "$(szin_kiir SARGA 'Készítsen biztonsági mentést a konfigurációról? (i/n): ')" VALASZTAS
    if [[ "$VALASZTAS" =~ ^[Ii]$ ]]; then
        local backup_dir="/root/samba_preinstall_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp -r /etc/samba "$backup_dir/samba_etc" 2>/dev/null
        cp /etc/resolv.conf "$backup_dir/resolv.conf" 2>/dev/null
        szin_kiir ZOLD "Biztonsági mentés kész: $backup_dir"
    else szin_kiir NARANCS "Biztonsági mentés kihagyva."; fi
}

configure_firewall() { 
    read -r -p "$(szin_kiir SARGA 'Telepítsem és konfiguráljam az UFW tűzfalat a szükséges portokkal? (i/n): ')" VALASZTAS
    if [[ "$VALASZTAS" =~ ^[Ii]$ ]]; then
        apt install -y ufw
        # Standard AD portok
        for port in 53/tcp 53/udp 88/tcp 88/udp 135/tcp 139/tcp 389/tcp 389/udp 445/tcp 464/tcp 464/udp 636/tcp 3268/tcp 3269/tcp; do ufw allow $port; done
        # Dinamikus RPC port tartomány
        ufw allow 49152:65535/tcp
        ufw enable <<<'y'
        szin_kiir ZOLD "✓ Tűzfal (UFW) beállítva és engedélyezve."
    else szin_kiir NARANCS "Tűzfal beállítás kihagyva."; fi
}

main() {
    check_basic_environment
    szin_kiir LILA "======================================================"
    szin_kiir LILA " 🚀 Samba 4 AD DC Telepítő Varázsló (HU) V7.2" # Frissített verziószám
    szin_kiir LILA "======================================================"
    setup_logging
    configure_menu 
}

# Fő program elindítása
main
