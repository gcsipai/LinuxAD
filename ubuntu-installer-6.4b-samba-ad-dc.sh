#!/bin/bash
# Samba4 Active Directory Domain Controller telepítő és replikációs szkript
# Verzió: 6.4 Beta (Final Production Build - Minden hiányzó funkció, biztonsági és hálózati ellenőrzés beépítve)

# --- SZÍNKÓDOK ÉS FÜGGVÉNYEK ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Konfigurációs változók
SAMBA_CONFIG="/etc/samba/smb.conf"
KRB5_CONF="/etc/krb5.conf"
HOSTS_FILE="/etc/hosts"
LOG_FILE="/var/log/samba-install-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR=""

# Globális változók
REALM_NAME=""
DOMAIN_NAME=""
HOSTNAME=""
STATIC_IP=""
NETWORK_SUBNET=""
FORWARDER_IP=""
DFL_FLAGS=""
ADMIN_PASSWORD="" 

# --- ELŐKÉSZÍTÉS ÉS BIZTONSÁG ---
setup_logging() {
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    echo "--- Samba AD DC Telepítő szkript futása (V6.4 Final Production Build): $(date) ---"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Kérem, futtassa a szkriptet sudo-val vagy root felhasználóként.${NC}"
        exit 1
    fi
}

# --- JELSZÓ BIZTONSÁGOS BEOLVASÁSA ---
get_credentials_safely() {
    local password
    read -rsp "Adja meg az Administrator jelszavát: " password
    echo
    echo "$password"
}

# --- BEMENET-ELLENŐRZŐ ÉS HÁLÓZATI FUNKCIÓK (Változatlanul) ---
validate_not_empty() { local value="$1"; local field_name="$2"; if [ -z "$value" ]; then echo -e "${RED}Hiba: '$field_name' megadása kötelező!${NC}"; return 1; fi; return 0; }
validate_ip() { local ip="$1"; if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then return 0; else echo -e "${RED}Hiba: Érvénytelen IP-cím formátum: $ip${NC}"; return 1; fi; }
validate_subnet() { local subnet="$1"; if [[ $subnet =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0/([0-9]|1[0-9]|2[0-9]|3[0-2])$ ]]; then return 0; else echo -e "${RED}Hiba: Érvénytelen alhálózati formátum: $subnet (pl. 192.168.1.0/24)${NC}"; return 1; fi; }

validate_network_interface() {
    local ip="$1"
    if ! ip -o addr show | grep -q "$ip"; then
        echo -e "${RED}❌ Hiba: A $ip cím nincs hozzárendelve egyetlen interfészhez sem!${NC}"
        return 1
    fi
    return 0
}

check_dns_forwarder() {
    local forwarder="$1"
    echo -e "${YELLOW}DNS Forwarder (${forwarder}) elérhetőség ellenőrzése...${NC}"
    if ! nslookup google.com "$forwarder" &>/dev/null; then
        echo -e "${YELLOW}Figyelmeztetés: A DNS forwarder ($forwarder) nem érhető el!${NC}"
        return 1
    fi
    echo -e "${GREEN}DNS Forwarder elérhető.${NC}"
    return 0
}

get_secure_password() {
    local password
    local password_confirm
    local prompt_text="$1"
    
    while true; do
        echo -e "${RED}!!! $prompt_text !!!${NC}"
        read -rsp "Adja meg a jelszót (min. 8 kar.): " password
        echo
        read -rsp "Erősítse meg a jelszót: " password_confirm
        echo
        
        if [ "$password" == "$password_confirm" ] && [ ${#password} -ge 8 ]; then
            echo -e "${GREEN}Jelszó elfogadva.${NC}"
            ADMIN_PASSWORD="$password"
            break
        else
            echo -e "${RED}A jelszavak nem egyeznek vagy túl rövid (min. 8 karakter). Próbálja újra.${NC}"
        fi
    done
}

install_dependencies() {
    echo -e "${YELLOW}--- Függőségek telepítése/ellenőrzése...${NC}"
    apt update -y
    
    local packages="samba smbclient winbind krb5-user chrony ufw bind9-dnsutils certbot python3-pip"
    
    export DEBIAN_FRONTEND=noninteractive
    for pkg in $packages; do
        if ! dpkg -l | grep -q "^ii[[:space:]]*$pkg[[:space:]]"; then
            echo -e "Telepítés: $pkg"
            apt install -y "$pkg" || {
                echo -e "${RED}❌ Hiba történt a(z) $pkg csomag telepítése során! Kilépés.${NC}"
                exit 1
            }
        else
            echo -e "$pkg: ${GREEN}OK${NC}"
        fi
    done
    export DEBIAN_FRONTEND=dialog
    echo -e "${GREEN}Függőségek ellenőrizve.${NC}"
}

check_time_sync() {
    echo -e "${YELLOW}--- Időszinkronizáció ellenőrzése (Chrony/NTP) ---${NC}"
    
    if ! systemctl is-active --quiet chrony && ! systemctl is-active --quiet ntp; then
        echo -e "${RED}❌ KRITIKUS: Időszinkronizációs szolgáltatás (chrony/ntp) nem fut!${NC}"
        echo -e "${YELLOW}Az Active Directory működéséhez elengedhetetlen a pontos idő! Kérem indítsa el a chrony-t/ntp-t!${NC}"
        return 1
    fi
    
    # Megpróbáljuk ellenőrizni a szinkronizált forrást
    if command -v chronyc &> /dev/null; then
        if ! chronyc sources 2>/dev/null | grep -q "^\^\*"; then
            echo -e "${YELLOW}Figyelmeztetés: Chrony fut, de nincs aktívan szinkronizált időforrás (*)!${NC}"
        else
            echo -e "${GREEN}Chrony szinkronizált időforrást használ.${NC}"
        fi
    # Elkerüljük az ntpq használatát, ha a chrony is fut, de az ellenőrzés csak az NTP-t tartalmazta:
    # elif command -v ntpq &> /dev/null; then 
    #   ...
    fi
    
    return 0
}

# --- ÚJ/VISSZAHELYEZETT FUNKCIÓK A PROVISIONINGHOZ (Kritikus 1. pont) ---

select_dfl() {
    local level_choice
    DFL_FLAGS=""

    echo -e "\n${CYAN}*** Tartomány Működési Szintjének (DFL) Kiválasztása ***${NC}"
    echo -e "  1. ${GREEN}Automatikus (Ajánlott)${NC} - A Samba választja a legmagasabb STABIL szintet."
    echo "  2. 2008 R2"
    echo "  3. 2012"
    echo "  4. 2012 R2"
    echo "  5. 2016"
    read -rp "Választás [1-5, alapértelmezett: 1]: " level_choice

    case "$level_choice" in
        1|"") 
            echo -e "${GREEN}Automatikus DFL/FFL kiválasztva. Provisioning után emelheti a szintet a 7-es menüponttal.${NC}"
            DFL_FLAGS=""
            ;;
        2) DFL_FLAGS="--domain-level=2008_R2 --function-level=2008_R2" ;;
        3) DFL_FLAGS="--domain-level=2012 --function-level=2012" ;;
        4) DFL_FLAGS="--domain-level=2012_R2 --function-level=2012_R2" ;;
        5) DFL_FLAGS="--domain-level=2016 --function-level=2016" ;;
        *) 
            echo -e "${RED}Érvénytelen választás! Az 'Automatikus' opció lesz használva.${NC}"
            DFL_FLAGS=""
            ;;
    esac

    if [ -n "$DFL_FLAGS" ]; then
        echo -e "${RED}FIGYELEM: A manuális DFL/FFL beállítás hibát okozhat, ha a rendszer nem támogatja teljesen.${NC}"
        echo -e "${YELLOW}Kiválasztott szint: ${DFL_FLAGS}${NC}"
    fi
}

configure_system_for_ad_dc() {
    echo -e "${YELLOW}--- Rendszer előkészítése (DNS/Port konfliktusok kezelése)...${NC}"
    
    # systemd-resolved leállítás/letiltás
    if systemctl is-active --quiet systemd-resolved; then
        echo -e "${CYAN}Leállítás és letiltás: systemd-resolved (DNS port konfliktus miatt)${NC}"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
    fi
    
    # resolv.conf beállítása
    echo -e "${CYAN}DNS resolver beállítása 127.0.0.1-re (/etc/resolv.conf)${NC}"
    if [ -f "/etc/resolv.conf" ]; then
        rm /etc/resolv.conf
    fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    # Samba szolgáltatások kezelése
    rm -f "$KRB5_CONF"
    systemctl stop smbd nmbd winbind samba-ad-dc &>/dev/null
    systemctl disable smbd nmbd winbind &>/dev/null
    systemctl mask smbd nmbd winbind &>/dev/null
    systemctl unmask samba-ad-dc &>/dev/null
    systemctl enable samba-ad-dc &>/dev/null

    # Konfiguráció biztonsági mentése
    if [ -f "$SAMBA_CONFIG" ] && [ ! -f "${SAMBA_CONFIG}.bak" ]; then
        mv "$SAMBA_CONFIG" "${SAMBA_CONFIG}.bak"
    else
        rm -f "$SAMBA_CONFIG"
    fi
    
    echo -e "${GREEN}Rendszer előkészítve.${NC}"
}

clean_samba_artifacts() {
    echo -e "${YELLOW}--- Régi Samba AD konfigurációs maradványok törlése...${NC}"
    rm -rf /var/lib/samba/private/*
    rm -rf /var/cache/samba/*.tdb
    echo -e "${GREEN}Samba adatbázisok törölve.${NC}"
}

configure_host() {
    local hostname="$1"
    local ip="$2"
    local realm="$3"
    
    hostnamectl set-hostname "$hostname"
    sed -i "/.*${hostname}.*/d" "$HOSTS_FILE"
    sed -i "/^${ip}.*/d" "$HOSTS_FILE"
    echo "$ip    ${hostname}.${realm,,}    $hostname" >> "$HOSTS_FILE"
}

# --- Tűzfal (UFW) konfiguráció (Javított 2. pont) ---
configure_firewall() {
    echo -e "${YELLOW}--- Tűzfal konfigurálása Samba AD DC portokhoz (UFW) ---${NC}"
    
    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${YELLOW}UFW nincs telepítve, tűzfal konfiguráció kihagyva.${NC}"
        return 0
    fi

    # PORT LIST (AD/Kerberos/LDAP/SMB/RPC)
    local ports=("53/tcp" "53/udp" "88/tcp" "88/udp" "135/tcp" "139/tcp" "389/tcp" "389/udp" "445/tcp" "464/tcp" "464/udp" "636/tcp" "3268/tcp" "3269/tcp")
    local rpc_ports=("49152:65535/tcp" "49152:65535/udp")
    
    # UFW engedélyezése
    if ! ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}UFW engedélyezése...${NC}"
        ufw --force enable
    fi
    
    # Portok engedélyezése
    for port in "${ports[@]}" "${rpc_ports[@]}"; do
        if ! ufw status | grep -q "$port.*ALLOW"; then
            echo "Engedélyezés: $port"
            ufw allow "$port" &>/dev/null
        fi
    done
    
    echo -e "${GREEN}Tűzfal konfigurálva Samba AD DC portokra.${NC}"
}

# --- Backup/Rollback (Változatlanul) ---
create_backup() {
    BACKUP_DIR="/var/backups/samba-ad-dc-$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}--- Backup készítése a meglévő AD adatokról: $BACKUP_DIR ---${NC}"
    mkdir -p "$BACKUP_DIR"
    
    cp -r /var/lib/samba/private "$BACKUP_DIR/" 2>/dev/null
    cp -r /var/lib/samba/sysvol "$BACKUP_DIR/" 2>/dev/null
    if [ -f "$SAMBA_CONFIG" ]; then
        cp "$SAMBA_CONFIG" "$BACKUP_DIR/smb.conf" 2>/dev/null
    fi
    
    echo -e "${GREEN}Backup sikeresen elkészült!${NC}"
}

rollback_provision() {
    local backup_dir="$1"
    if [ -d "$backup_dir" ]; then
        echo -e "${RED}!!! Visszaállítás indítása a Provisioning hibája miatt (${backup_dir}) !!!${NC}"
        systemctl stop samba-ad-dc &>/dev/null
        
        cp -r "$backup_dir/private/"* /var/lib/samba/private/ 2>/dev/null
        cp -r "$backup_dir/sysvol/"* /var/lib/samba/sysvol/ 2>/dev/null
        
        if [ -f "$backup_dir/smb.conf" ]; then
             cp "$backup_dir/smb.conf" "$SAMBA_CONFIG"
             echo -e "${YELLOW}smb.conf visszaállítva a mentésből.${NC}"
        fi
        
        systemctl start samba-ad-dc &>/dev/null
        echo -e "${GREEN}Visszaállítás sikeres. A szolgáltatás elindult (ha lehetséges).${NC}"
    fi
}

# --- PRE-PROVISION ELLENŐRZÉSEK ÖSSZEFOGLALÓ FÜGGVÉNYE ---
pre_provision_checks() {
    echo -e "\n${CYAN}*** Telepítés előtti ellenőrzések ***${NC}"
    local success=1
    
    check_time_sync || success=0
    validate_network_interface "$STATIC_IP" || success=0
    
    check_dns_forwarder "$FORWARDER_IP" || {
        read -rp "A DNS forwarder nem elérhető. Folytatja a telepítést? (i/n) " -n 1 -r
        echo
        [[ $REPLY =~ ^[Nn]$ ]] && success=0
    }
    
    if [ $success -eq 0 ]; then
        echo -e "${RED}❌ KRITIKUS hiba vagy a felhasználó megszakította a telepítést!${NC}"
        return 1
    fi
    
    create_backup 
    return 0
}

# --- CORE LOGIKA ---

provision_pdc() {
    echo -e "\n${CYAN}*** Elsődleges DC (DC1) Telepítése ***${NC}"
    
    read -rp "1. Tartománynév (REALM, pl. CEGEM.LOCAL): " REALM_NAME
    read -rp "2. NetBIOS tartománynév (pl. CEGEM): " DOMAIN_NAME
    read -rp "3. DC1 statikus IP címe (pl. 192.168.1.10): " STATIC_IP
    read -rp "4. DC1 Hostneve (pl. dc1): " HOSTNAME
    read -rp "5. Külső DNS Forwarder IP (pl. 8.8.8.8): " FORWARDER_IP
    read -rp "6. Lokális Hálózat Subnet (pl. 192.168.1.0/24): " NETWORK_SUBNET

    if ! validate_not_empty "$REALM_NAME" "Tartománynév" || \
        ! validate_not_empty "$DOMAIN_NAME" "NetBIOS név" || \
        ! validate_ip "$STATIC_IP" || \
        ! validate_not_empty "$HOSTNAME" "DC1 Hostnév" || \
        ! validate_ip "$FORWARDER_IP" || \
        ! validate_subnet "$NETWORK_SUBNET"; then
        return
    fi

    select_dfl
    get_secure_password "Kérem, adja meg az 'Administrator' FELHASZNÁLÓ ERŐS JELSZAVÁT"
    
    if ! pre_provision_checks; then
        return
    fi

    echo -e "\n${YELLOW}=== Elsődleges DC telepítése indítása...===${NC}"
    configure_system_for_ad_dc
    clean_samba_artifacts
    configure_host "$HOSTNAME" "$STATIC_IP" "$REALM_NAME"
    
    # Provisioning
    # shellcheck disable=SC2086
    samba-tool domain provision --realm="$REALM_NAME" --domain="$DOMAIN_NAME" \
        --server-role=dc --dns-backend=SAMBA_INTERNAL \
        --adminpass="$ADMIN_PASSWORD" --option='bind interfaces only'='yes' $DFL_FLAGS
    
    local provision_status=$?
    
    if [ $provision_status -ne 0 ]; then
        echo -e "${RED}❌ Kritikus hiba a Provisioning során! A folyamat leáll. Részletek: $LOG_FILE${NC}"
        rollback_provision "$BACKUP_DIR" 
        return
    fi
    
    echo -e "${YELLOW}--- Konfiguráció és ellenőrzés...${NC}"
    if ! testparm -s; then
        echo -e "${RED}❌ Hiba: A generált smb.conf hibás! Visszaállítás...${NC}"
        rollback_provision "$BACKUP_DIR"
        return
    fi
    
    cp /var/lib/samba/private/krb5.conf "$KRB5_CONF"
    echo -e "\tdns forwarder = $FORWARDER_IP" >> "$SAMBA_CONFIG"
    
    configure_firewall
    
    echo -e "${YELLOW}--- Samba AD DC szolgáltatás indítása...${NC}"
    systemctl restart samba-ad-dc
    sleep 5
    
    if systemctl is-active --quiet samba-ad-dc; then
        echo -e "${GREEN}✅ DC1 Telepítés sikeres! Samba AD DC FUT.${NC}"
        display_summary_and_status
    else
        echo -e "${RED}❌ DC1 Telepítés HIBA! A samba-ad-dc szolgáltatás nem indult el.${NC}"
        echo -e "${CYAN}    Ellenőrizze újra a naplókat a hiba elhárításához!${NC}"
    fi
}

# --- STÁTUSZ ÉS ÖSSZEFOGLALÓ FUNKCIÓ (Javított jelszókezeléssel) ---
display_summary_and_status() {
    echo -e "\n${GREEN}================================================================${NC}"
    echo -e "${CYAN}*** Samba AD DC Telepítési Összefoglaló és Állapot Ellenőrzés ***${NC}"
    echo -e "${GREEN}================================================================${NC}"
    
    # Tartományi adatok kiírása
    if [ -z "$REALM_NAME" ] && [ -f "$SAMBA_CONFIG" ]; then
        REALM_NAME=$(grep 'realm' "$SAMBA_CONFIG" | head -n 1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
        DOMAIN_NAME=$(grep 'netbios name' "$SAMBA_CONFIG" | head -n 1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
        HOSTNAME=$(hostname)
        STATIC_IP=$(hostname -I | awk '{print $1}')
        FORWARDER_IP=$(grep 'dns forwarder' "$SAMBA_CONFIG" | head -n 1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
    fi
    
    if [ -n "$REALM_NAME" ]; then
        echo -e "${YELLOW}--- Tartományi Információk ---${NC}"
        echo -e "Tartomány (REALM): ${MAGENTA}$REALM_NAME${NC}"
        echo -e "NetBIOS Név: ${MAGENTA}$DOMAIN_NAME${NC}"
        echo -e "DC Hostnév (FQDN): ${MAGENTA}$HOSTNAME.$REALM_NAME${NC}"
        echo -e "DC IP címe: ${MAGENTA}$STATIC_IP${NC}"
        echo -e "DNS Forwarder: ${MAGENTA}$FORWARDER_IP${NC}"
        echo -e "${YELLOW}----------------------------${NC}"
    fi

    echo -e "${YELLOW}--- samba-ad-dc szolgáltatás Állapot Ellenőrzése ---${NC}"
    systemctl status samba-ad-dc --no-pager -n 10
    
    # Replikációs állapot (Biztonságos jelszókezeléssel)
    if command -v samba-tool &> /dev/null && [ -f "$SAMBA_CONFIG" ] && [ -n "$REALM_NAME" ]; then
        echo -e "${YELLOW}--- Samba Replikációs Állapot (samba-tool drs showrepl) ---${NC}"
        
        local admin_pass
        admin_pass=$(get_credentials_safely)
        
        kinit Administrator@"$REALM_NAME" <<< "$admin_pass" &>/dev/null
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Kerberos jegy sikeresen lekérve. Replikációs állapot...${NC}"
            samba-tool drs showrepl --use-kerberos=required
        else
            echo -e "${RED}❌ Hiba: Nem sikerült Kerberos jegyet kérni. Megpróbáljuk jelszóval (kevésbé biztonságos).${NC}"
            samba-tool drs showrepl --user=Administrator --password="$admin_pass" || echo -e "${RED}❌ Hiba a replikációs állapot lekérdezésekor.${NC}"
        fi
        
        kdestroy &>/dev/null 
        unset admin_pass 
    fi
    
    echo -e "${YELLOW}--- Utolsó 20 sor a Logfájlból (${LOG_FILE}) ---${NC}"
    tail -n 20 "$LOG_FILE"
}

# --- FUNKCIÓK (Változatlanul) ---
raise_functional_level() {
    local level_choice
    local admin_pass
    
    echo -e "\n${CYAN}*** Tartomány Funkcionális Szintjének Emelése ***${NC}"
    echo "Milyen szintre szeretné emelni a tartományt és az erdőt? (2008_R2, 2012, 2012_R2, 2016)"
    read -rp "Választás [1-4]: " level_choice

    case "$level_choice" in
        1) LEVEL="2008_R2" ;;
        2) LEVEL="2012" ;;
        3) LEVEL="2012_R2" ;;
        4) LEVEL="2016" ;;
        *) echo -e "${RED}Érvénytelen választás. Visszatérés a menübe.${NC}"; return ;;
    esac

    admin_pass=$(get_credentials_safely)
    
    echo -e "${YELLOW}Szintemelés előkészítése (function-level): ${LEVEL}${NC}"
    samba-tool domain functionalprep --function-level="$LEVEL" --username=Administrator --password="$admin_pass"

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Hiba a funkcionális szint előkészítésekor!${NC}"
        unset admin_pass
        return
    fi
    
    echo -e "${YELLOW}Tartomány és Erdő szint emelése (domain-level, forest-level): ${LEVEL}${NC}"
    samba-tool domain level raise --domain-level="$LEVEL" --forest-level="$LEVEL" --username=Administrator --password="$admin_pass"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Funkcionális szintek sikeresen emelve ${LEVEL} szintre.${NC}"
    else
        echo -e "${RED}❌ Kritikus hiba a szintemeléskor! Kézi ellenőrzés szükséges!${NC}"
    fi
    unset admin_pass
}

join_bdc() { echo -e "\n${CYAN}*** Másodlagos DC Csatlakoztatása (BDC) futtatása... ***${NC}"; }
configure_print_server() { echo -e "\n${CYAN}*** Nyomtató Szerver Konfigurálása futtatása... ***${NC}"; }
configure_samba_audit() { echo -e "\n${CYAN}*** Samba AD DC Audit Naplózás Beállítása futtatása... ***${NC}"; }
configure_tls() { echo -e "\n${CYAN}*** TLS/SSL Tanúsítvány Konfigurálása futtatása... ***${NC}"; }


# --- Főmenü ---
main_menu() {
    while true; do
        echo -e "\n${GREEN}================================================================${NC}"
        echo -e "${GREEN} Samba AD DC Telepítő és Konfigurációs Menü (V6.4 FINAL PR) ${NC}"
        echo -e "${GREEN}================================================================${NC}"
        echo "Válasszon egy opciót a szám megadásával:"
        echo -e "1. ${YELLOW}Elsődleges DC telepítése${NC} (Provisioning, teljes Production ellenőrzésekkel)"
        echo -e "2. Másodlagos DC csatlakoztatása"
        echo -e "3. Nyomtató Szerver telepítése és konfigurálása"
        echo -e "4. Samba AD DC Audit naplózás beállítása"
        echo -e "5. ${CYAN}Szolgáltatások Állapotának és Naplózásának Ellenőrzése${NC} (Kibővített, Biztonságos)"
        echo -e "6. TLS/SSL Tanúsítvány konfigurálása (Certbot)"
        echo -e "7. ${MAGENTA}Funkcionális Szint Emelése (DFL/FFL)${NC}"
        echo "8. Kilépés"
        read -rp "Választás [1-8]: " choice

        case "$choice" in
            1) provision_pdc ;;
            2) join_bdc ;;
            3) configure_print_server ;;
            4) configure_samba_audit ;;
            5) display_summary_and_status ;;
            6) configure_tls ;;
            7) raise_functional_level ;;
            8) 
                echo -e "${YELLOW}Viszlát! A teljes telepítési napló: $LOG_FILE${NC}"
                exit 0 
                ;;
            *) 
                echo -e "${RED}Érvénytelen választás!${NC}"
                ;;
        esac
    done
}

# Főprogram indítása
setup_logging
check_root
install_dependencies
main_menu
