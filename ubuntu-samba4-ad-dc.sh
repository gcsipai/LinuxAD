#!/bin/bash
# ==============================================================================
# Samba 4 Active Directory Tartományvezérlő Telepítő Szkript
# Verzió: V7.9.5 Beta2 (Tiszta Indítás + smb.conf ütközés megoldva)
# Rendszer: Ubuntu 22.04 / 24.04+
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
LOG_FILE=""
LOG_FILE_BASE="/var/log/samba_installation"

# Globális változók (ÜRESEN INDULNAK!)
HOSTNAME_FQDN=""
REALM=""
DOMAIN_NETBIOS=""
DNS_FORWARDER=""
ADMIN_PASSWORD=""
FIRST_USER="rgaz" # Ez az egyetlen alapértelmezett érték (opcionális felhasználó neve)
FIRST_USER_PASSWORD=""
REALM_LOWER=""

# ------------------------------------------------------------------------------
# SEGÉD FUNKCIÓK
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
    LOG_FILE="${LOG_FILE_BASE}_$(date +%Y%m%d_%H%M%S).log"
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
        read -r -s -p "$(szin_kiir NARANCS "$prompt (min. $min_length karakter): ")" TEMP_PASSWORD; echo
        read -r -s -p "$(szin_kiir SARGA "Ismételd meg a jelszót: ")" TEMP_PASSWORD_CONFIRM; echo
        if [[ "$TEMP_PASSWORD" == "$TEMP_PASSWORD_CONFIRM" ]]; then
            if [[ ${#TEMP_PASSWORD} -ge $min_length ]]; then
                # Globális változó frissítése a valós jelszóval
                if [ "$var_name" = "ADMIN_PASSWORD" ]; then ADMIN_PASSWORD="$TEMP_PASSWORD"; fi
                if [ "$var_name" = "FIRST_USER_PASSWORD" ]; then FIRST_USER_PASSWORD="$TEMP_PASSWORD"; fi
                return 0
            else szin_kiir PIROS "A jelszó túl rövid. Kérlek, legalább $min_length karaktert használj."; fi
        else szin_kiir PIROS "A jelszavak nem egyeznek. Kérlek, próbáld újra."; fi
    done
}

print_command_status() {
    local exit_code=$?
    local command_desc="$1"
    if [ $exit_code -eq 0 ]; then
        szin_kiir ZOLD "✓ $command_desc sikeresen befejeződött."
    else
        szin_kiir PIROS "✗ $command_desc HIBA! Kilépési kód: $exit_code"
    fi
    return $exit_code
}

load_config_from_files() {
    # Itt csak a REALM_LOWER-t állítjuk be, ha van REALM
    if [[ -n "$REALM" ]]; then REALM_LOWER=$(echo "$REALM" | tr '[:upper:]' '[:lower:]'); fi
}

backup_config() {
    local backup_dir="/root/samba_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    szin_kiir NARANCS "Konfigurációs fájlok biztonsági mentése..."
    cp -a /etc/samba/smb.conf "$backup_dir/" 2>/dev/null
    cp -a /etc/hosts "$backup_dir/" 2>/dev/null
    cp -a /etc/resolv.conf "$backup_dir/" 2>/dev/null
    cp -a /etc/krb5.conf "$backup_dir/" 2>/dev/null
    
    if [ $(find "$backup_dir" -type f | wc -l) -gt 0 ]; then
        szin_kiir ZOLD "✓ Biztonsági mentés sikeresen befejeződött: $backup_dir"
        return 0
    else
        szin_kiir SARGA "✓ Biztonsági mentés (nincs kritikus fájl mentve, ami rendben van egy friss telepítésnél)."
        return 0
    fi
}

check_prerequisites() {
    szin_kiir LILA "--- Rendszer Előfeltételek és Ütközések Ellenőrzése ---"
    local errors=0
    local ip_addr=$(hostname -I | awk '{print $1}')
    
    # 1. Statikus IP ellenőrzés
    if [[ -z "$ip_addr" ]] || [[ "$ip_addr" =~ ^127\. ]] || [[ "$ip_addr" =~ ^169\.254\. ]]; then
        szin_kiir PIROS "HIBA: Statikus IP hiányzik vagy nem megfelelő ($ip_addr). A DC-nek statikus IP-vel kell rendelkeznie!"; errors=$((errors + 1))
    else szin_kiir ZOLD "✓ Statikus IP ($ip_addr) ellenőrzés sikeres."; fi
    
    # 2. Hostname FQDN egyezés ellenőrzés
    local current_hostname=$(hostname -f)
    if [[ "$current_hostname" != "$HOSTNAME_FQDN" ]]; then
        szin_kiir PIROS "HIBA: A rendszer hostname-je ($current_hostname) NEM egyezik a kívánt FQDN-nel ($HOSTNAME_FQDN)."; errors=$((errors + 1))
    else szin_kiir ZOLD "✓ Hostname ($current_hostname) rendben."; fi

    # 3. Régi Samba fájlok/ütközés ellenőrzése
    if [ -f /etc/samba/smb.conf ]; then
        if grep -q "server role = standalone" /etc/samba/smb.conf; then
            szin_kiir SARGA "FIGYELEM: Találtunk egy Standalone szerver konfigurációt. A Provisioning előtt ezt automatikusan töröljük. (Ezt a V7.9.5 kezeli.)";
        fi
    fi
    
    szin_kiir LILA "--- Előfeltételek Ellenőrzése Befejezve ($errors Hiba) ---"
    
    if [ $errors -gt 0 ]; then return 1; fi
    return 0
}


set_hostname_and_hosts() {
    szin_kiir NARANCS "Rendszer hostname beállítása: $HOSTNAME_FQDN"
    hostnamectl set-hostname "$HOSTNAME_FQDN"
    print_command_status "Hostname beállítása"

    szin_kiir NARANCS "Hosts fájl frissítése..."
    local local_ip=$(hostname -I | awk '{print $1}')
    if grep -q "$HOSTNAME_FQDN" /etc/hosts; then
        sed -i "/$HOSTNAME_FQDN/c\\$local_ip\t$HOSTNAME_FQDN ${HOSTNAME_FQDN%%.*}" /etc/hosts
    else
        sed -i "/127.0.0.1.*$HOSTNAME_FQDN/d" /etc/hosts 
        echo -e "$local_ip\t$HOSTNAME_FQDN ${HOSTNAME_FQDN%%.*}" >> /etc/hosts
    fi
    print_command_status "Hosts fájl frissítése"
}

provision_domain() {
    local attempts=3
    szin_kiir NARANCS "--> Samba Provisioning Parancs indítása..."
    while [ $attempts -gt 0 ]; do
        szin_kiir NARANCS "Tartomány provisioning indítása. Próbálkozás $attempts..."
        # Provisioning
        if samba-tool domain provision --use-rfc2307 --realm="$REALM" --domain="$DOMAIN_NETBIOS" --server-role="dc" --dns-backend="SAMBA_INTERNAL" --adminpass="$ADMIN_PASSWORD"; then
            print_command_status "Samba Provisioning"
            return 0
        fi
        ((attempts--)); szin_kiir PIROS "Provision sikertelen, újrapróbálás ($attempts maradt)... Ellenőrizd a DNS/Hálózatot!"; sleep 5
    done
    szin_kiir PIROS "HIBA: A samba-tool domain provision sikertelen volt 3 próbálkozás után."; return 1
}

run_update_upgrade() {
    szin_kiir NARANCS "Rendszer frissítése (apt update & upgrade)..."
    apt update && apt upgrade -y
    print_command_status "Rendszer frissítés"
}

# ------------------------------------------------------------------------------
# FŐ TELEPÍTÉSI LOGIKA (V7.9.5)
# ------------------------------------------------------------------------------

run_installation() {
    szin_kiir LILA "Konfiguráció kész. Telepítés indul..."
    
    # Kötelező mezők ellenőrzése
    if [[ -z "$HOSTNAME_FQDN" || -z "$REALM" || -z "$DOMAIN_NETBIOS" || -z "$ADMIN_PASSWORD" ]]; then
        szin_kiir PIROS "HIBA: Kötelező mezők hiányoznak (1, 2, 3, 5 opciók)! Kérlek, állítsd be őket a menüben."
        return 1
    fi
    
    # 0. KÖRNYEZETI GARANCIA (Samba maszkolás, régi konfigok törlése)
    szin_kiir VASTAG ">>> KÖRNYEZETI GARANCIA: Systemd maszkolás feloldása + Alap konfigurációk törlése <<<"
    systemctl unmask samba-ad-dc samba smbd nmbd winbind || true
    rm -f /etc/samba/smb.conf /etc/krb5.conf
    systemctl daemon-reload
    print_command_status "Systemd maszkolások feloldása és alap config törlése"
    
    # Biztonsági mentés
    backup_config
    
    # Hostname beállítás
    set_hostname_and_hosts
    
    # Előfeltételek ellenőrzése
    if ! check_prerequisites; then
        szin_kiir PIROS "Telepítés megszakítva az előfeltételek miatt."
        return 1
    fi
    
    szin_kiir VASTAG "*** TELEPÍTÉSI FOLYAMAT INDUL ***"
    
    # 1. Csomaglista frissítés
    szin_kiir NARANCS "Csomaglista frissítése..."
    apt update
    print_command_status "APT update"
    
    # Csomagtelepítés
    export DEBIAN_FRONTEND=noninteractive
    szin_kiir NARANCS "Kötelező csomagok telepítése..."
    apt install -y samba-ad-dc krb5-user dnsutils chrony acl attr
    print_command_status "Csomagtelepítés"
    export DEBIAN_FRONTEND=dialog
    
    # 2. Szolgáltatások leállítása és maszkolása (régi Samba szolgáltatások)
    systemctl stop samba smbd nmbd winbind || true
    systemctl disable samba smbd nmbd winbind || true
    systemctl mask samba smbd nmbd winbind || true
    
    # 3. Provisioning ELŐTTI KRITIKUS JAVÍTÁS
    szin_kiir LILA "--- Samba AD Provisioning ---"
    
    # KRITIKUS JAVÍTÁS: A csomagtelepítés által létrehozott smb.conf törlése.
    rm -f /etc/samba/smb.conf
    print_command_status "Provisioning előtti smb.conf eltávolítás"
    
    if ! provision_domain; then
        szin_kiir PIROS "A Provisioning sikertelen volt. Telepítés megszakítva."
        return 1
    fi
    
    # DNS konfiguráció (resolv.conf)
    szin_kiir NARANCS "DNS konfiguráció beállítása (resolv.conf)..."
    cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    echo "search ${REALM_LOWER}" >> /etc/resolv.conf
    print_command_status "DNS konfiguráció"
    
    # DNS Továbbító beállítása
    if [[ -n "$DNS_FORWARDER" ]] && ! grep -q "dns forwarder" /etc/samba/smb.conf; then
        szin_kiir NARANCS "DNS továbbító beállítása: $DNS_FORWARDER..."
        sed -i "/\[global\]/a \        dns forwarder = $DNS_FORWARDER" /etc/samba/smb.conf
        print_command_status "DNS továbbító beállítása (/etc/samba/smb.conf)"
    fi
    
    # 4. Szolgáltatások indítása/újraindítása
    szin_kiir NARANCS "Samba AD DC szolgáltatás indítása/újraindítása..."
    systemctl unmask samba-ad-dc
    systemctl enable samba-ad-dc
    systemctl restart samba-ad-dc
    print_command_status "Samba AD DC indítása"
    
    szin_kiir SARGA "Várjunk 10 másodpercet a Samba teljes indulásáig..."
    sleep 10
    
    # Kerberos konfiguráció
    szin_kiir NARANCS "Kerberos konfiguráció másolása..."
    if [ -f /var/lib/samba/private/krb5.conf ]; then
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        print_command_status "Kerberos konfiguráció"
    else
        szin_kiir PIROS "KÉZIKÖNYV HIBA: A /var/lib/samba/private/krb5.conf nem található! A Samba AD DC nem fut megfelelően!"
        return 1
    fi

    # Chrony beállítása
    szin_kiir NARANCS "Chrony szinkronizálás beállítása a tartományhoz..."
    sed -i '/^pool/d' /etc/chrony/chrony.conf
    echo "server $HOSTNAME_FQDN prefer iburst" >> /etc/chrony/chrony.conf
    systemctl restart chrony
    print_command_status "Chrony konfiguráció"
    
    # 5. Első felhasználó létrehozása
    if [[ -n "$FIRST_USER" ]] && [[ -n "$FIRST_USER_PASSWORD" ]]; then
        szin_kiir LILA "--- Első Felhasználó Létrehozása/Beállítása ---"
        szin_kiir NARANCS "Felhasználó ($FIRST_USER) létrehozása/jelszó beállítása..."
        
        # Jegy beolvasása teszthez
        echo "$ADMIN_PASSWORD" | kinit administrator@$REALM &>/dev/null
        
        if samba-tool user setpassword "$FIRST_USER" --newpassword="$FIRST_USER_PASSWORD" --adminpass="$ADMIN_PASSWORD" 2>/dev/null; then
            print_command_status "Felhasználó ($FIRST_USER) jelszó beállítása"
        elif samba-tool user create "$FIRST_USER" "$FIRST_USER_PASSWORD" --given-name="First" --surname="User" --must-change-at-next-login --adminpass="$ADMIN_PASSWORD" 2>/dev/null; then
            print_command_status "Felhasználó ($FIRST_USER) létrehozása"
        else
            szin_kiir PIROS "HIBA: A felhasználó ($FIRST_USER) művelet sikertelen. Ellenőrizd a Kerberos jegyet és a Samba AD DC állapotát!"
            return 1
        fi
        kdestroy &>/dev/null
    fi
    
    # 6. Tűzfal beállítások
    szin_kiir LILA "--- Tűzfal beállítása (UFW) ---"
    if command -v ufw &> /dev/null; then
        ufw --force enable
        ufw allow 53/tcp && ufw allow 53/udp
        ufw allow 88/tcp && ufw allow 88/udp
        ufw allow 135/tcp
        ufw allow 137/udp && ufw allow 138/udp
        ufw allow 139/tcp && ufw allow 389/tcp
        ufw allow 389/udp && ufw allow 445/tcp
        ufw allow 464/tcp && ufw allow 464/udp
        ufw allow 636/tcp && ufw allow 3268/tcp
        ufw allow 3269/tcp
        ufw allow 49152:65535/tcp 
        ufw reload
        print_command_status "Tűzfal beállítás"
    else
        szin_kiir SARGA "UFW nem található. Tűzfal konfiguráció kihagyva."
    fi
    
    szin_kiir ZOLD ">>> TELEPÍTÉS ÉS KONFIGURÁCIÓ KÉSZ <<<"
    return 0
}

# ------------------------------------------------------------------------------
# MENÜ ÉS KONFIGURÁCIÓS FUNKCIÓK
# ------------------------------------------------------------------------------

option_1() {
    szin_kiir LILA "» Hostname beállítása (FQDN) «"
    szin_kiir SARGA "Az FQDN (Fully Qualified Domain Name) legyen a teljes szervernév, ami tartalmazza a tartományt is."
    szin_kiir SARGA "PÉLDA: dc1.cegem.local vagy szerver1.budapest.lan"
    read -r -p "$(szin_kiir NARANCS "Add meg a szerver teljes hostname-jét (FQDN, pl. dc1.cegem.local): ")" HOSTNAME_INPUT
    HOSTNAME_FQDN=$(echo "$HOSTNAME_INPUT" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$HOSTNAME_FQDN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        szin_kiir PIROS "Hibás FQDN formátum!"
        HOSTNAME_FQDN=""
    fi
    szin_kiir ZOLD "Hostname beállítva: $HOSTNAME_FQDN"
}
option_2() {
    szin_kiir LILA "» Tartomány beállítása (REALM) «"
    szin_kiir SARGA "A REALM (Kerberos tartomány) névnek **NAGYBETŰS** formában kell lennie a szabvány szerint."
    szin_kiir SARGA "PÉLDA: CEGEM.LOCAL vagy BUDAPEST.LAN"
    read -r -p "$(szin_kiir NARANCS "Add meg a tartományt (REALM, pl. CEGEM.LOCAL): ")" REALM_INPUT
    REALM=$(echo "$REALM_INPUT" | tr '[:lower:]' '[:upper:]')
    if [[ -n "$REALM" ]]; then REALM_LOWER=$(echo "$REALM" | tr '[:upper:]' '[:lower:]'); fi
    szin_kiir ZOLD "REALM beállítva: $REALM"
}
option_3() {
    szin_kiir LILA "» Tartomány NetBIOS neve «"
    szin_kiir SARGA "A NetBIOS név a régebbi Windows rendszerek által használt név, általában a tartomány (REALM) **NAGYBETŰS**, rövidített formája."
    szin_kiir SARGA "PÉLDA: CEGEM vagy BUDAPEST"
    read -r -p "$(szin_kiir NARANCS "Add meg a tartomány NetBIOS nevét (pl. CEGEM): ")" NETBIOS_INPUT
    DOMAIN_NETBIOS=$(echo "$NETBIOS_INPUT" | tr '[:lower:]' '[:upper:]')
    szin_kiir ZOLD "NetBIOS Név beállítva: $DOMAIN_NETBIOS"
}
option_4() {
    szin_kiir LILA "» DNS továbbító beállítása «"
    szin_kiir SARGA "Ez az a DNS szerver, amelyhez a Samba fordul, ha nem tudja feloldani a belső tartományban lévő nevet."
    szin_kiir SARGA "PÉLDA: Google DNS: 8.8.8.8, vagy egy belső router IP-je."
    read -r -p "$(szin_kiir NARANCS "Add meg a DNS továbbító IP címét (pl. 8.8.8.8, üresen hagyható): ")" DNS_FORWARDER_INPUT
    DNS_FORWARDER="$DNS_FORWARDER_INPUT"
    if [[ -n "$DNS_FORWARDER" ]] && [[ ! "$DNS_FORWARDER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        szin_kiir PIROS "Hibás IP cím formátum! Törölve."
        DNS_FORWARDER=""
    fi
    szin_kiir ZOLD "DNS Továbbító beállítva: $DNS_FORWARDER"
}
option_5() {
    szin_kiir LILA "» Adminisztrátor Jelszó beállítása «"
    szin_kiir SARGA "Ez a tartományi (Active Directory) Administrator felhasználó jelszava. **ERŐS** jelszót válassz!"
    get_password "Add meg az Administrator jelszót" "ADMIN_PASSWORD" 8
    szin_kiir ZOLD "Adminisztrátor Jelszó: BEÁLLÍTVA"
}
option_6() {
    szin_kiir LILA "» Első felhasználó neve «"
    szin_kiir SARGA "Ez egy tesztfelhasználó, amelyet a telepítés végén hoz létre a szkript. **KISBETŰS** javasolt."
    read -r -p "$(szin_kiir NARANCS "Add meg az első felhasználó nevét (KISBETŰS JAVASOLT, pl. rgaz): ")" FIRST_USER_INPUT
    FIRST_USER=$(echo "$FIRST_USER_INPUT" | tr '[:upper:]' '[:lower:]')
    szin_kiir ZOLD "Első Felhasználó Név: $FIRST_USER"
}
option_7() {
    if [[ -z "$FIRST_USER" ]]; then
        szin_kiir PIROS "Előbb add meg a felhasználó nevét (6. opció)!"
        return 1
    fi
    szin_kiir LILA "» Első felhasználó jelszava «"
    szin_kiir SARGA "Ez a $FIRST_USER felhasználó jelszava. **ERŐS** jelszót válassz!"
    get_password "Add meg $FIRST_USER jelszavát" "FIRST_USER_PASSWORD" 8
    szin_kiir ZOLD "Első Felhasználó Jelszó: BEÁLLÍTVA"
}

display_status_summary() {
    szin_kiir LILA "--- Rendszer állapot összegzés ---"
    echo "Hostname: $(hostname)"
    echo "FQDN: $(hostname -f)"
    echo "IP cím: $(hostname -I)"
    
    local services=("samba-ad-dc" "bind9" "nmbd" "smbd")
    for service in "${services[@]}"; do
        if systemctl is-active "$service" &>/dev/null; then
            szin_kiir ZOLD "✓ $service: fut"
        else
            szin_kiir SARGA "✗ $service: nem fut"
        fi
    done
    
    local temp_admin_pass="$ADMIN_PASSWORD"
    if [ -n "$temp_admin_pass" ] && [ -n "$REALM" ]; then
        echo "$temp_admin_pass" | kinit administrator@$REALM &> /dev/null
        if [ $? -eq 0 ]; then
            szin_kiir ZOLD "✓ Kerberos jegy beolvasva (administrator)"
            kdestroy &> /dev/null
        else
            szin_kiir SARGA "✗ Kerberos jegy nem olvasható be (administrator). Ellenőrizd az /etc/krb5.conf fájlt és a Samba logokat."
        fi
    else
        szin_kiir SARGA "Admin jelszó vagy REALM hiányzik a Kerberos teszteléshez."
    fi
}

display_summary_and_suggestions() {
    szin_kiir LILA "--- Összegzés és kezelési javaslatok ---"
    
    szin_kiir SARGA "» KONFIGURÁCIÓS ÖSSZEFOGLALÓ"
    echo "  - FQDN:          $HOSTNAME_FQDN"
    echo "  - REALM:         $REALM"
    echo "  - NetBIOS Név:   $DOMAIN_NETBIOS"
    echo "  - DNS Továbbító: $DNS_FORWARDER"
    
    szin_kiir SARGA "» KEZELÉSI JAVASLATOK"
    echo "1. A telepítés után ellenőrizd a DNS működését:"
    echo "   nslookup $HOSTNAME_FQDN"
    echo "   nslookup $REALM_LOWER"
    echo "2. Teszteld a tartomány csatlakozást:"
    echo "   kinit administrator@$REALM"
    echo "3. Windows gépek csatlakoztatása:"
    echo "   Tartomány neve: $REALM_LOWER (pl. budapest.lan)"
    echo "   NetBIOS név: $DOMAIN_NETBIOS (pl. BUDAPEST)"
    
    szin_kiir LILA "--------------------------------------------"
}

# ------------------------------------------------------------------------------
# FŐ MENÜ
# ------------------------------------------------------------------------------

display_config() {
    load_config_from_files
    
    HOSTNAME_DISPLAY=${HOSTNAME_FQDN:-"NINCS BEÁLLÍTVA"}
    REALM_DISPLAY=${REALM:-"NINCS BEÁLLÍTVA"}
    DOMAIN_NETBIOS_DISPLAY=${DOMAIN_NETBIOS:-"NINCS BEÁLLÍTVA"}
    DNS_DISPLAY=${DNS_FORWARDER:-"NINCS"}
    PASSWORD_DISPLAY=${ADMIN_PASSWORD:+BEÁLLÍTVA}
    FIRST_USER_DISPLAY=${FIRST_USER:-"NINCS BEÁLLÍTVA"}
    USER_PASSWORD_DISPLAY=${FIRST_USER_PASSWORD:+BEÁLLÍTVA}
    
    local DC_IP_ADDR=$(hostname -I | awk '{print $1}')

    szin_kiir LILA "======================================================"
    szin_kiir LILA " ⚙️ Samba 4 AD DC Konfigurációs Menü (V7.9.5)"
    szin_kiir LILA "======================================================"
    szin_kiir SARGA "» HÁLÓZATI ÉS TARTOMÁNY ALAPOK"
    echo -e "  $(szin_kiir VASTAG "Szerver IP címe:")         ${DC_IP_ADDR}"
    echo -e "  $(szin_kiir VASTAG "1. Szerver Hostname (FQDN):") ${HOSTNAME_DISPLAY} (KISBETŰS JAVASOLT)"
    echo -e "  $(szin_kiir VASTAG "2. Tartomány (REALM) név:")   ${REALM_DISPLAY} (NAGYBETŰS KÖTELEZŐ)"
    echo -e "  $(szin_kiir VASTAG "3. Tartomány NetBIOS név:")   ${DOMAIN_NETBIOS_DISPLAY} (NAGYBETŰS JAVASOLT)"
    echo -e "  $(szin_kiir VASTAG "4. DNS Továbbító IP:")        ${DNS_DISPLAY} (Példa: 8.8.8.8, Opcionális)"
    szin_kiir LILA "------------------------------------------------------"
    szin_kiir SARGA "» ALAPVETŐ AD HITELESÍTÉS"
    echo -e "  $(szin_kiir VASTAG "5. Adminisztrátor Jelszó:")   ${PASSWORD_DISPLAY:-"NINCS BEÁLLÍTVA"}"
    echo -e "  $(szin_kiir VASTAG "6. Első Felhasználó Név:")    ${FIRST_USER_DISPLAY} (KISBETŰS JAVASOLT)"
    echo -e "  $(szin_kiir VASTAG "7. Első Felhasználó Jelszó:") ${USER_PASSWORD_DISPLAY:-"NINCS BEÁLLÍTVA"}"
    szin_kiir LILA "------------------------------------------------------"
    szin_kiir NARANCS "» MŰVELETEK"
    echo -e "  $(szin_kiir VASTAG "8. Telepítés és Konfigurálás Indítása")"
    echo -e "  $(szin_kiir VASTAG "9. Gyors Állapot Ellenőrzés")"
    echo -e "  $(szin_kiir VASTAG "10. Rendszer Frissítés (apt update/upgrade)")"
    echo -e "  $(szin_kiir VASTAG "11. Összegzés és Kezelési Javaslatok")"
    echo -e "  $(szin_kiir VASTAG "0. Kilépés a szkriptből")"
    echo
}

configure_menu() {
    while true; do
        display_config
        read -r -p "$(szin_kiir NARANCS "Válassz egy opciót (1-11, 0 a kilépéshez): ")" CHOICE
        
        case "$CHOICE" in
            1) option_1 ;; 
            2) option_2 ;;
            3) option_3 ;;
            4) option_4 ;;
            5) option_5 ;;
            6) option_6 ;;
            7) option_7 ;;
            8) run_installation; [ $? -eq 0 ] && return 0 ;;
            9) display_status_summary ;; 
            10) run_update_upgrade ;; 
            11) display_summary_and_suggestions ;; 
            0) szin_kiir ZOLD "Kilépés a szkriptből. Viszlát!"; exit 0 ;;
            *) szin_kiir PIROS "Érvénytelen opció. Kérlek, válassz 0 és 11 között." ;;
        esac
    done
}


main() {
    szin_kiir LILA "======================================================"
    szin_kiir LILA " 🚀 Samba 4 AD DC Telepítő Varázsló (HU) V7.9.5"
    szin_kiir LILA "======================================================"
    setup_logging
    
    load_config_from_files
    
    configure_menu 
}

# A fő program elindítása
main
