#!/bin/bash

# A script csak root jogosultságokkal futtatható
if [ "$EUID" -ne 0 ]; then
  echo "Kérjük, futtassa a scriptet root felhasználóként: sudo ./domain_integracio.sh"
  exit 1
fi

# ============================================================================
# === SCRIPT LEÍRÁS ÉS DOKUMENTÁCIÓ (V3.1) ===================================
# ============================================================================

# CÉL
# Ez a script automatizálja egy Debian vagy Ubuntu alapú Linux szerver Active 
# Directory (AD) tartományba való integrációjának folyamatát. 
# A cél a felhasználók és csoportok központi AD hitelesítésének engedélyezése, 
# a helyes időszinkronizáció (NTP) és a hálózati beállítások (DNS/Netplan) 
# biztosítása, amelyek elengedhetetlenek a stabil AD csatlakozáshoz.

# FŐ KOMPONENSEK
# - realmd/adcli: A tartományi csatlakozás vezérlésére.
# - sssd: A felhasználói hitelesítéshez (Authentication) és jogosultságokhoz 
#         (Authorization) szükséges szolgáltatás.
# - chrony: A hálózati időprotokoll (NTP) szinkronizáláshoz az AD DC-vel.
# - netplan.io: DNS beállítások konfigurálásához (Ubuntu/Debian 10+ esetén).

# ELŐFELTÉTELEK
# 1. A Linux szervernek rendelkeznie kell helyes hálózati beállításokkal (statikus IP ajánlott).
# 2. A Domain Controller (DC) IP-címe ismert.
# 3. Rendelkezni kell egy AD Domain Admin jogosultsággal a tartományhoz való csatlakozáshoz.
# 4. A szerver hostnevének egyeznie kell az AD tartományban használni kívánt névvel.
# 5. A Netplan konfiguráció ($NETPLAN_CONF) elérhető és szerkeszthető.

# JAVASOLT MŰVELETI SORREND
# Minden lépés egymásra épül. Kérjük, kövesse a javasolt sorrendet:
# A -> 1 -> 2 -> 3 -> 4 -> 5 -> 6

# ============================================================================

# ANSI Színkódok definiálása
GREEN='\033[0;32m'   # Zöld (Fő kiemelés, Siker)
RED='\033[0;31m'     # Piros (Visszaállítás, Hiba)
WHITE='\033[0;37m'   # Fehér (Alapvető szöveg)
YELLOW='\033[0;33m'  # Sárga (Figyelem, adatbevitel - Megbízható)
RESET='\033[0m'      # Szín visszaállítása

# ----------------------------------------------------------------------------
# --- Segédfüggvények ---

# Biztonsági másolat készítése adott fájlról
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${WHITE}  [INFO] Biztonsági másolat készült: ${file}.backup.*${RESET}"
    fi
}

# ----------------------------------------------------------------------------
# --- Fő Funkciók (rövidített tartalommal, mivel csak a leírás a lényeg) ---

# A) Előfeltételek és rendszer-kompatibilitás ellenőrzése
check_prerequisites() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}          ELŐFELTÉTELEK ELLENŐRZÉSE              ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    
    if ! grep -q "Ubuntu\|Debian" /etc/os-release; then
        echo -e "${RED}[HIBA] Ez a script csak Debian/Ubuntu rendszerekre van tesztelve! A futtatás kockázatos lehet.${RESET}"
    else
        echo -e "${GREEN}[OK] OS Ellenőrzés: Debian/Ubuntu alapú.${RESET}"
    fi
    
    if command -v netplan &> /dev/null; then
        echo -e "${GREEN}[OK] Netplan: Telepítve. DNS-hez ezt használjuk.${RESET}"
    else
        echo -e "${YELLOW}[FIGYELEM] Netplan nem található. Manuális DNS beállításra lehet szükség!${RESET}"
    fi
    
    read -n 1 -s -r -p $'\n'"Nyomjon meg egy gombot a főmenübe való visszatéréshez..."
}

# 1. Csomagok telepítése
install_packages() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}       TARTOMÁNYI CSOMAGOK TELEPÍTÉSE            ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    
    echo -e "${WHITE}  [AKCIÓ] Rendszerfrissítés (apt update)...${RESET}"
    apt update
    
    REQUIRED_PACKAGES="realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit chrony netplan.io"
    
    echo -e "${WHITE}  [AKCIÓ] Csomagok telepítése: ${REQUIRED_PACKAGES}...${RESET}"
    if apt install -y $REQUIRED_PACKAGES; then
        echo -e "${GREEN}[SIKER] A tartományi integrációs csomagok telepítve!${RESET}"
    else
        echo -e "${RED}[HIBA] Nem sikerült telepíteni a csomagokat. Ellenőrizze az internetkapcsolatot.${RESET}"
    fi
    read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
}

# 2. Időzóna beállítása
set_timezone() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}             IDŐZÓNA BEÁLLÍTÁSA                ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    
    CURRENT_TZ=$(timedatectl show --property=Timezone --value)
    echo -e "${WHITE}  [JELENLEGI] Időzóna:${RESET} ${CURRENT_TZ}"
    
    echo -n -e $'\n'"${WHITE}Adja meg a kívánt időzónát (pl.: Europe/Budapest) VAGY hagyja üresen az aktuális megtartásához: ${RESET}"
    read TIMEZONE_INPUT
    
    TIMEZONE=${TIMEZONE_INPUT:-$CURRENT_TZ}
    
    echo -e "${WHITE}  [AKCIÓ] Beállítás: ${TIMEZONE}...${RESET}"
    if timedatectl set-timezone "$TIMEZONE"; then
        echo -e "${GREEN}[SIKER] Az időzóna beállítva: ${TIMEZONE}${RESET}"
    else
        echo -e "${RED}[HIBA] Nem sikerült beállítani az időzónát. Ellenőrizze a megadott időzóna nevét.${RESET}"
    fi
    read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
}

# 3. NTP szinkronizáció beállítása
set_ntp_sync() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}          IDŐSZINKRONIZÁCIÓ (CHRONY)            ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    
    if systemctl is-active systemd-timesyncd &> /dev/null; then
        echo -e "${WHITE}  [INFO] Leállítás: systemd-timesyncd (konfliktus elkerülése)...${RESET}"
        systemctl stop systemd-timesyncd
        systemctl disable systemd-timesyncd
    fi

    echo -n -e $'\n'"${WHITE}Adja meg az Active Directory Domain Controller IP-címét VAGY Hostnevét (Pl.: 10.0.0.100): ${RESET}"
    read DC_NTP_SERVER
    
    if [ -z "$DC_NTP_SERVER" ]; then
        echo -e "${YELLOW}[FIGYELEM] Nem adott meg NTP szervert. Alapértelmezett chrony beállítások maradnak.${RESET}"
        read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
        return
    fi
    
    CHRONY_CONF="/etc/chrony/chrony.conf"
    backup_file $CHRONY_CONF
    
    sed -i '/^\(pool\|server\)/d' $CHRONY_CONF
    sed -i "1s/^/server $DC_NTP_SERVER iburst\npool 2.debian.pool.ntp.org iburst\n/" $CHRONY_CONF
    
    echo -e "${WHITE}  [AKCIÓ] Újraindítás: chrony szolgáltatás...${RESET}"
    systemctl restart chrony
    systemctl enable chrony
    
    echo -e "${GREEN}[SIKER] Chrony beállítva. Szinkronizáció ellenőrzése:${RESET}"
    chronyc sources -v
    
    read -n 1 -s -r -p $'\n'"Nyomjon meg egy gombot a folytatáshoz..."
}

# 4. DNS beállítása (Netplan)
set_dns() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}          DNS BEÁLLÍTÁSA (NETPLAN)             ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${YELLOW}  ! FIGYELEM: A Netplan fájl manuális ellenőrzése ajánlott a futás után. !${RESET}"
    
    echo -n -e $'\n'"${WHITE}Adja meg a Domain Controller IP-címét (Pl.: 10.0.0.100): ${RESET}"
    read DC_IP
    
    if [ -z "$DC_IP" ]; then
        echo -e "${RED}[HIBA] IP-cím megadása kötelező. Visszatérés a főmenübe.${RESET}"
        read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
        return
    fi
    
    NETPLAN_CONF=$(find /etc/netplan/ -maxdepth 1 -type f -name "*.yaml" | head -n 1)
    
    if [ -z "$NETPLAN_CONF" ]; then
        echo -e "${RED}[KRITIKUS HIBA] Netplan konfigurációs fájl nem található. Kérem manuálisan konfigurálja a DNS-t!${RESET}"
        read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
        return
    fi
    
    backup_file $NETPLAN_CONF
    
    if grep -q "nameservers:" "$NETPLAN_CONF"; then
        sed -i "/addresses:/c\            addresses: [$DC_IP]" "$NETPLAN_CONF"
        if ! grep -q "nameservers:" "$NETPLAN_CONF"; then
            sed -i "/            addresses/i \        nameservers:" "$NETPLAN_CONF"
        fi
    else
        if grep -q "ethernets:" "$NETPLAN_CONF"; then
             sed -i "/ethernets:/a \ \ \ \ nameservers:\n            addresses: [$DC_IP]" "$NETPLAN_CONF"
        else
            echo -e "${YELLOW}[FIGYELEM] A Netplan fájl szerkezete nem azonosítható. Manuális szerkesztés szükséges!${RESET}"
        fi
    fi

    echo -e "${WHITE}  [AKCIÓ] Netplan beállítások alkalmazása (netplan apply)...${RESET}"
    if netplan apply; then
        echo -e "${GREEN}[SIKER] A DNS beállítások alkalmazva! Ellenőrizze a 'resolvectl status' paranccsal.${RESET}"
    else
        echo -e "${RED}[HIBA] Nem sikerült alkalmazni a Netplan beállításokat. Ellenőrizze a $NETPLAN_CONF szintaxisát!${RESET}"
    fi
    
    read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
}

# 5. Tartományhoz csatlakozás
join_domain_and_configure() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}        TARTOMÁNYHOZ CSATLAKOZÁS (AD)            ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    
    if ! command -v realm &> /dev/null; then
        echo -e "${RED}[HIBA] A 'realmd' nem található. Kérem telepítse a csomagokat (1. menüpont).${RESET}"
        read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
        return
    fi
    
    echo -n -e $'\n'"${WHITE}Adja meg az AD REALM nevét (NAGYBETŰVEL! Pl.: SRV.WORLD): ${RESET}"
    read REALM_NAME
    
    echo -n -e "${WHITE}Adja meg a Domain Admin felhasználónevét (Pl.: Administrator): ${RESET}"
    read AD_ADMIN_USER
    
    if [ -z "$REALM_NAME" ] || [ -z "$AD_ADMIN_USER" ]; then
        echo -e "${RED}[HIBA] Minden adat megadása kötelező. Visszatérés a főmenübe.${RESET}"
        read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
        return
    fi

    read -s -rp "${YELLOW}AD admin jelszó: ${RESET}" AD_PASSWORD
    echo

    echo -e "${WHITE}  [AKCIÓ] Csatlakozás a tartományhoz (--membership-software=samba)...${RESET}"

    if echo "$AD_PASSWORD" | realm join "$REALM_NAME" -U "$AD_ADMIN_USER" --client-software=sssd --membership-software=samba --automatic-setup; then
        echo -e "${GREEN}[SIKER] Sikeresen csatlakozott a(z) ${REALM_NAME} tartományhoz!${RESET}"
        
        PAM_CONF="/etc/pam.d/common-session"
        backup_file $PAM_CONF
        MKHOMEDIR_LINE="session optional        pam_mkhomedir.so skel=/etc/skel umask=077"
        if ! grep -q "pam_mkhomedir.so" $PAM_CONF; then
            echo -e "${WHITE}  [INFO] Automatikus Home könyvtár létrehozás beállítva.${RESET}"
            echo "$MKHOMEDIR_LINE" >> $PAM_CONF
        fi
        
    else
        echo -e "${RED}[HIBA] Nem sikerült csatlakozni a tartományhoz. Ellenőrizze a hiba részleteket alább! ${RESET}"
        echo -e "${YELLOW}-----------------------------------------${RESET}"
        echo -e "${WHITE}1. Ellenőrizze a DC-vel való hálózati kapcsolatot (ping).${RESET}"
        echo -e "${WHITE}2. Ellenőrizze a DNS beállításokat (nslookup $REALM_NAME).${RESET}"
        echo -e "${YELLOW}-----------------------------------------${RESET}"
    fi
    
    read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
}

# 6. SSSD beállításainak testreszabása
configure_sssd() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}       SSSD KONFIGURÁCIÓ TESTRESZABÁSA           ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    
    SSSD_CONF="/etc/sssd/sssd.conf"
    
    if [ ! -f "$SSSD_CONF" ]; then
        echo -e "${RED}[HIBA] Az SSSD konfigurációs fájl ($SSSD_CONF) nem található. Kérem előbb csatlakozzon a tartományhoz!${RESET}"
        read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
        return
    fi
    
    backup_file $SSSD_CONF
    echo -e "${WHITE}  [AKCIÓ] A jelenlegi SSSD beállítások módosítása...${RESET}"
    
    echo -n -e "${WHITE}1. ${YELLOW}Tartománynév elhagyása${WHITE} a felhasználónévben (Pl.: user helyett user@realm): ${RESET}"
    read FQN_CHOICE
    if [[ "$FQN_CHOICE" =~ ^[iI]$ ]]; then
        sed -i '/use_fully_qualified_names/c\use_fully_qualified_names = False' $SSSD_CONF
    fi

    echo -n -e "${WHITE}2. ${YELLOW}Fix UID/GID${WHITE} használata az AD attribútumok alapján (ldap_id_mapping = False): ${RESET}"
    read USE_FIXED_ID
    
    if [[ "$USE_FIXED_ID" =~ ^[iI]$ ]]; then
        sed -i '/ldap_id_mapping/c\ldap_id_mapping = False' $SSSD_CONF
        
        if ! grep -q "ldap_user_uid_number" $SSSD_CONF; then
            sed -i "/\[domain/a ldap_user_uid_number = uidNumber\nldap_user_gid_number = gidNumber" $SSSD_CONF
            echo -e "${GREEN}  [INFO] Hozzáadva az UID/GID attribútumok.${RESET}"
        fi
        
        echo -e "${WHITE}  [AKCIÓ] Töröljük a cache-t a változások érvényesítéséhez...${RESET}"
        rm -f /var/lib/sss/db/*
    fi
    
    echo -n -e "${WHITE}3. ${YELLOW}Automatikus csoportkezelés${WHITE} beállítása (simple_allow_groups): ${RESET}"
    read AUTO_GROUPS
    if [[ "$AUTO_GROUPS" =~ ^[iI]$ ]]; then
        sed -i '/simple_allow_groups/c\simple_allow_groups = true' $SSSD_CONF
        echo -e "${GREEN}  [INFO] Az automatikus csoportkezelés engedélyezve.${RESET}"
    fi

    echo -e "${WHITE}  [AKCIÓ] SSSD újraindítása...${RESET}"
    systemctl restart sssd
    
    echo -e "${GREEN}[SIKER] Az SSSD beállítások frissítve. ${RESET}"
    read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
}

# R) Visszaállítási Funkció
rollback_changes() {
    clear
    echo -e "${RED}=================================================${RESET}"
    echo -e "${RED}         VISSZAÁLLÍTÁSI FUNKCIÓK                 ${RESET}"
    echo -e "${RED}=================================================${RESET}"
    
    echo -e "${RED}1. Tartomány Elhagyása (realm leave)${RESET}"
    echo -e "${WHITE}2. Kilépés a Visszaállítási menüből${RESET}"

    echo -n -e $'\n'"${YELLOW}Kérem a választását (1-2): ${RESET}" 
    read ROLLBACK_CHOICE
    
    case $ROLLBACK_CHOICE in
        1)
            echo -n -e "${WHITE}Adja meg az elhagyandó REALM nevét (NAGYBETŰVEL!): ${RESET}"
            read REALM_TO_LEAVE
            
            echo -n -e "${WHITE}Adja meg a Domain Controller adminisztrátor felhasználónevét: ${RESET}"
            read AD_ADMIN_USER

            read -s -rp "${RED}AD admin jelszó: ${RESET}" AD_PASSWORD
            echo

            echo -e "${WHITE}  [AKCIÓ] Próbálkozás a tartomány elhagyásával...${RESET}"
            
            if echo "$AD_PASSWORD" | realm leave "$REALM_TO_LEAVE" -U "$AD_ADMIN_USER"; then
                 echo -e "${GREEN}[SIKER] A(z) $REALM_TO_LEAVE tartomány elhagyva. ${RESET}"
                 echo -e "${WHITE}  [INFO] Ne feledje manuálisan visszaállítani a hálózati és konfigurációs fájlokat!${RESET}"
            else
                 echo -e "${RED}[HIBA] Nem sikerült elhagyni a tartományt. Ellenőrizze a REALM nevet, az admin felhasználót és jelszót.${RESET}"
            fi
            read -n 1 -s -r -p "Nyomjon meg egy gombot a folytatáshoz..."
            ;;
        *)
            return
            ;;
    esac
}

# ----------------------------------------------------------------------------
# --- Menü Rendszer ---

# Fő menü megjelenítése (Tiszta, Zöld Design)
show_menu() {
    clear
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}#     TARTOMÁNYI INTEGRÁCIÓS SCRPIT V3.1        #${RESET}"
    echo -e "${GREEN}#     DEBIAN/UBUNTU LINUX (Citk)                #${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    
    echo -e "\n${WHITE}*** AJÁNLOTT SORREND: A -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 ***${RESET}\n"
    
    echo -e "${GREEN}>>> ELŐKÉSZÍTÉS ÉS HÁLÓZAT${RESET}"
    echo -e "${WHITE}  [A] Előfeltételek és Kompatibilitás Ellenőrzése${RESET}"
    echo -e "${WHITE}  [1] Csomagok telepítése (realmd, sssd, chrony)${RESET}"
    echo -e "${WHITE}  [2] Időzóna Beállítása (timedatectl)${RESET}"
    echo -e "${WHITE}  [3] Időszinkronizáció Beállítása (NTP/Chrony)${RESET}"
    echo -e "${WHITE}  [4] Domain Controller DNS Beállítása (Netplan)${RESET}"
    
    echo -e "\n${GREEN}>>> DOMAIN INTEGRÁCIÓ${RESET}"
    echo -e "${WHITE}  [5] Tartományhoz Csatlakozás (realm join)${RESET}"
    echo -e "${WHITE}  [6] SSSD Konfiguráció Testreszabása (FQN, Fix UID/GID)${RESET}"
    
    echo -e "\n${GREEN}>>> KARBANTARTÁS ÉS KILÉPÉS${RESET}"
    echo -e "${RED}  [R] Visszaállítási Opciók (Tartomány Elhagyása)${RESET}"
    echo -e "${WHITE}  [Q] Kilépés a Scriptből${RESET}"
    echo -e "\n---------------------------------------------------"
    
    # FŐ PROMPT: A javított, megbízható módszer
    echo -n -e "${YELLOW}Választás (A/1-6/R/Q): ${RESET}"
    read CHOICE 
}

# Fő ciklus
while true; do
    show_menu
    case $CHOICE in
        A|a)
            check_prerequisites
            ;;
        1)
            install_packages
            ;;
        2)
            set_timezone
            ;;
        3)
            set_ntp_sync
            ;;
        4)
            set_dns
            ;;
        5)
            join_domain_and_configure
            ;;
        6)
            configure_sssd
            ;;
        R|r)
            rollback_changes
            ;;
        Q|q)
            echo -e "${GREEN}Kilépés a scriptből. Viszlát!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Érvénytelen választás. Kérjük, nyomjon meg egy gombot és próbálja újra.${RESET}"
            read -n 1 -s -r -p ""
            ;;
    esac
done
