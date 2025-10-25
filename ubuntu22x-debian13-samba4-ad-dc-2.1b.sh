#!/bin/bash

# =================================================================
# SAMBA AD DC TELEPÍTŐ SCRIPT - JAVÍTOTT VERZIÓ 2.1 DevOFALL 2025
# Támogatott disztribúciók: Debian 11+, Ubuntu 20.04+
# =================================================================

# Színkódok
CLR_GREEN='\033[38;2;40;167;69m'
CLR_RED='\033[38;2;215;10;83m'
CLR_BLUE='\033[38;2;0;115;183m'
CLR_YELLOW='\033[38;2;255;179;0m'
CLR_PURPLE='\033[38;2;103;58;183m'
CLR_RESET='\033[0m'

# Log fájl
LOG_FILE="/var/log/samba-ad-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================================"
echo "Samba AD DC telepítés - JAVÍTOTT VERZIÓ 2.1 DevOFALL 2025"
echo "Támogatott disztribúciók: Debian 11+, Ubuntu 20.04+"
echo "================================================================"

# --- Funkciók ---
info_msg() { echo -e "${CLR_GREEN}✅ $1${CLR_RESET}"; }
warn_msg() { echo -e "${CLR_YELLOW}⚠️  $1${CLR_RESET}"; }
error_msg() { echo -e "${CLR_RED}❌ HIBA: $1${CLR_RESET}"; }
section_header() {
    echo -e "${CLR_BLUE}=================================================================${CLR_RESET}"
    echo -e "${CLR_BLUE}      $1${CLR_RESET}"
    echo -e "${CLR_BLUE}=================================================================${CLR_RESET}"
}

# --- JAVÍTOTT DNS KONFIGURÁCIÓ ---
configure_dns_fix() {
    section_header "DNS KONFIGURÁCIÓ JAVÍTÁSA"

    info_msg "DNS beállítások ellenőrzése és javítása..."

    # Biztonsági mentés
    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

    # Symlink és védelem eltávolítása
    [ -L /etc/resolv.conf ] && unlink /etc/resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # Systemd-resolved letiltása
    if systemctl is-active --quiet systemd-resolved; then
        warn_msg "Systemd-resolved letiltása..."
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        systemctl mask systemd-resolved
    fi

    # Helyes DNS konfiguráció
    cat > /etc/resolv.conf <<EOF
# Samba AD DC DNS - $(date)
nameserver 127.0.0.1
nameserver ${DNS_FORWARDER}
search ${DOMAIN_NAME_LOWER}
options timeout:2 attempts:3
EOF

    info_msg "DNS konfiguráció beállítva"
    echo -e "${CLR_BLUE}=== Aktuális DNS konfiguráció ===${CLR_RESET}"
    cat /etc/resolv.conf
    echo -e "${CLR_BLUE}=================================${CLR_RESET}"
}

# --- JAVÍTOTT KERBEROS KONFIGURÁCIÓ ---
configure_kerberos_fix() {
    section_header "KERBEROS KONFIGURÁCIÓ JAVÍTÁSA"

    info_msg "Kerberos konfiguráció ellenőrzése..."

    # Mindig másoljuk át a Samba által generált konfigurációt
    if [ -f /var/lib/samba/private/krb5.conf ]; then
        info_msg "Samba Kerberos konfiguráció másolása..."
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    else
        error_msg "Samba Kerberos konfiguráció nem található!"
        return 1
    fi

    # Ellenőrizzük a tartalmat
    if ! grep -q "default_realm = ${DOMAIN_NAME_UPPER}" /etc/krb5.conf; then
        error_msg "Kerberos konfiguráció hibás!"
        return 1
    fi

    info_msg "Kerberos konfiguráció ellenőrizve"

    # Kerberos tesztelése
    info_msg "Kerberos alapvető teszt..."
    if timeout 10 klist -s 2>/dev/null; then
        info_msg "Kerberos ticket cache működik"
    else
        warn_msg "Nincs érvényes Kerberos ticket"
    fi

    return 0
}

# --- JAVÍTOTT NETBIOS KONFIGURÁCIÓ ---
configure_netbios_fix() {
    section_header "NETBIOS NÉV KONFIGURÁCIÓ"

    # NetBIOS név biztosítása
    local netbios_name=$(echo "${HOST_NAME}" | cut -c1-15 | tr '[:lower:]' '[:upper:]')

    if ! grep -q "netbios name" /etc/samba/smb.conf; then
        warn_msg "NetBIOS név hiányzik, hozzáadás: ${netbios_name}"
        # Hozzáadás a [global] szekció után
        sed -i "/\[global\]/a\    netbios name = ${netbios_name}" /etc/samba/smb.conf
    fi

    # NetBIOS domain név biztosítása
    if ! grep -q "workgroup = ${DOMAIN_NETBIOS}" /etc/samba/smb.conf; then
        warn_msg "NetBIOS domain név beállítása: ${DOMAIN_NETBIOS}"
        # Csere a meglévő workgroup bejegyzésen
        sed -i "s/^workgroup = .*/workgroup = ${DOMAIN_NETBIOS}/" /etc/samba/smb.conf
    fi

    info_msg "NetBIOS konfiguráció ellenőrizve"
}

# --- JAVÍTOTT ADATBEKÉRÉS ---
get_input_data() {
    section_header "ALAPADATOK BEKÉRÉSE"

    while true; do
        echo -ne "${CLR_BLUE}▶️ Szerver statikus IP címe: ${CLR_RESET}"
        read SERVER_IP
        if [[ $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IFS='.' read -r i1 i2 i3 i4 <<< "$SERVER_IP"
            if [ $i1 -le 255 ] && [ $i2 -le 255 ] && [ $i3 -le 255 ] && [ $i4 -le 255 ]; then
                break
            fi
        fi
        error_msg "Érvénytelen IP cím formátum."
    done

    echo -ne "${CLR_BLUE}▶️ Szerver rövid hosztneve (pl: dc01): ${CLR_RESET}"
    read HOST_NAME

    while true; do
        echo -ne "${CLR_BLUE}▶️ Teljes tartománynév (pl: cegnev.local): ${CLR_RESET}"
        read DOMAIN_NAME_LOWER
        # RFC 1035 ellenőrzés: betű, szám, kötőjel, pont, minimum 2 karakteres TLD
        if [[ $DOMAIN_NAME_LOWER =~ ^[a-zA-Z0-9]+([-.][a-zA-Z0-9]+)*\.[a-zA-Z]{2,}$ ]]; then
            break
        fi
        error_msg "Érvénytelen tartománynév formátum."
    done

    while true; do
        echo -ne "${CLR_BLUE}▶️ NetBIOS tartománynév (NAGYBETŰVEL, max 15 karakter): ${CLR_RESET}"
        read DOMAIN_NETBIOS
        DOMAIN_NETBIOS=$(echo "$DOMAIN_NETBIOS" | tr '[:lower:]' '[:upper:]' | cut -c1-15)
        if [[ -z "$DOMAIN_NETBIOS" ]]; then
            error_msg "A NetBIOS név nem lehet üres."
        elif [[ ${#DOMAIN_NETBIOS} -gt 15 ]]; then
            error_msg "A NetBIOS név túl hosszú (maximum 15 karakter)."
        else
            break
        fi
    done

    while true; do
        echo -ne "${CLR_BLUE}▶️ Külső DNS továbbító (pl: 8.8.8.8): ${CLR_RESET}"
        read DNS_FORWARDER
        if [[ $DNS_FORWARDER =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IFS='.' read -r i1 i2 i3 i4 <<< "$DNS_FORWARDER"
            if [ $i1 -le 255 ] && [ $i2 -le 255 ] && [ $i3 -le 255 ] && [ $i4 -le 255 ]; then
                break
            fi
        fi
        error_msg "Érvénytelen DNS továbbító IP cím."
    done

    DOMAIN_NAME_UPPER=$(echo "$DOMAIN_NAME_LOWER" | tr '[:lower:]' '[:upper:]')
}

# --- JAVÍTOTT TELEPÍTÉSI FOLYAMAT ---

section_header "SAMBA AD DC TELEPÍTÉS - JAVÍTOTT VERZIÓ 2.1"

# Adatok bekérése
get_input_data

# --- 1. HOSTS FÁJL ---
section_header "1. HOSTS FÁJL BEÁLLÍTÁSA"
cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d-%H%M%S)
# Töröljük a régi bejegyzést a szerver IP-hez, ha van
sed -i "/${SERVER_IP}/d" /etc/hosts 2>/dev/null || true
echo -e "\n# Samba AD DC - $(date)" >> /etc/hosts
echo "${SERVER_IP} ${HOST_NAME}.${DOMAIN_NAME_LOWER} ${HOST_NAME}" >> /etc/hosts
info_msg "Hosts fájl beállítva"

# --- 2. ÖSSZEFOGLALÓ ---
section_header "TELEPÍTÉSI ÖSSZEFOGLALÓ"
echo "Szerver IP: ${CLR_BLUE}$SERVER_IP${CLR_RESET}"
echo "Hosztnév: ${CLR_BLUE}$HOST_NAME${CLR_RESET}"
echo "Teljes Tartomány: ${CLR_BLUE}$DOMAIN_NAME_LOWER${CLR_RESET}"
echo "NetBIOS Tartomány: ${CLR_BLUE}$DOMAIN_NETBIOS${CLR_RESET}"
echo "Külső DNS Forwarder: ${CLR_BLUE}$DNS_FORWARDER${CLR_RESET}"

read -p "$(echo -e "${CLR_YELLOW}Biztosan folytatja a fenti adatokkal? (i/n): ${CLR_RESET}")" -n 1 -r; echo
if [[ ! $REPLY =~ ^[Ii]$ ]]; then
    info_msg "Telepítés megszakítva."; exit 0;
fi

# --- 3. RENDSZER FRISSÍTÉS ---
section_header "2. RENDSZER FRISSÍTÉS ÉS HOSZTNÉV"
info_msg "Csomagforrások frissítése..."
if apt-get update -y; then
    info_msg "Rendszerfrissítés..."
    apt-get upgrade -y || warn_msg "Rendszerfrissítés részben sikertelen"
else
    error_msg "APT frissítés SIKERTELEN. Ellenőrizze az internetkapcsolatot és a forrásokat."
    exit 1
fi

# --- 4. HOSZTNÉV ---
section_header "3. HOSZTNÉV BEÁLLÍTÁSA"
hostnamectl set-hostname "${HOST_NAME}"
info_msg "Hosztnév beállítva: ${HOST_NAME}"

# --- 5. KERBEROS ELŐKONFIGURÁCIÓ ---
section_header "4. KERBEROS ELŐKONFIGURÁCIÓ"
debconf-set-selections <<EOF
krb5-config krb5-config/default_realm string ${DOMAIN_NAME_UPPER}
krb5-config krb5-config/kerberos_servers string ${HOST_NAME}.${DOMAIN_NAME_LOWER}
krb5-config krb5-config/admin_server string ${HOST_NAME}.${DOMAIN_NAME_LOWER}
krb5-config krb5-config/add_servers_realm string ${DOMAIN_NAME_UPPER}
krb5-config krb5-config/add_servers boolean true
krb5-config krb5-config/read_config boolean true
EOF
info_msg "Kerberos előkonfiguráció beállítva"

# --- 6. SAMBA TELEPÍTÉS ---
section_header "5. SAMBA TELEPÍTÉS"
# krb5-user: a kinit parancshoz
# dnsutils: a host és dig parancsokhoz
# python3-setproctitle: Samba igényli
SAMBA_PACKAGES="samba-ad-dc krb5-user dnsutils python3-setproctitle net-tools"
info_msg "Telepítendő csomagok: $SAMBA_PACKAGES"

if apt-get install -y ${SAMBA_PACKAGES}; then
    info_msg "Samba csomagok sikeresen telepítve"
else
    error_msg "Samba csomagok telepítése SIKERTELEN."
    exit 1
fi

# --- 7. JELSZÓ BEKÉRÉS ---
section_header "6. ADMIN JELSZÓ BEÁLLÍTÁSA"
echo -e "${CLR_PURPLE}!!! ADJON MEG ADMINISZTRÁTORI JELSZÓT !!!${CLR_RESET}"
echo "A jelszónak meg kell felelnie a minimális Windows jelszóházirendnek (minimum 8 karakter, kis- és nagybetű, szám)."

while true; do
    echo -ne "${CLR_BLUE}Jelszó: ${CLR_RESET}"
    read -s ADMIN_PASSWORD_1
    echo
    echo -ne "${CLR_BLUE}Jelszó megerősítése: ${CLR_RESET}"
    read -s ADMIN_PASSWORD_2
    echo

    if [ "$ADMIN_PASSWORD_1" != "$ADMIN_PASSWORD_2" ]; then
        error_msg "A két jelszó NEM egyezik."
        continue
    fi

    # Minimum 8 karakter, kisbetű, nagybetű, szám ellenőrzés (a Samba provision tool is ellenőriz)
    if [ ${#ADMIN_PASSWORD_1} -lt 8 ] || ! [[ "$ADMIN_PASSWORD_1" =~ [[:lower:]] ]] || ! [[ "$ADMIN_PASSWORD_1" =~ [[:upper:]] ]] || ! [[ "$ADMIN_PASSWORD_1" =~ [[:digit:]] ]]; then
        error_msg "A jelszó nem felel meg az AD jelszóházirendnek (min. 8 kar., kis-, nagybetű, szám)."
        continue
    fi

    ADMIN_PASSWORD="$ADMIN_PASSWORD_1"
    info_msg "Jelszó sikeresen beállítva."
    break
done

# --- 8. TARTOMÁNY LÉTREHOZÁSA ---
section_header "7. TARTOMÁNY LÉTREHOZÁSA (PROVISIONING)"

# Biztonsági mentések és a régi samba.conf eltávolítása
[ -f /etc/samba/smb.conf ] && mv /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%Y%m%d-%H%M%S)
[ -f /etc/krb5.conf ] && cp /etc/krb5.conf /etc/krb5.conf.bak.$(date +%Y%m%d-%H%M%S)

info_msg "Tartomány provisionálása..."
samba-tool domain provision \
    --server-role=dc \
    --use-rfc2307 \
    --dns-backend=SAMBA_INTERNAL \
    --realm="${DOMAIN_NAME_UPPER}" \
    --domain="${DOMAIN_NETBIOS}" \
    --adminpass="${ADMIN_PASSWORD}"

if [ $? -ne 0 ]; then
    error_msg "Provisioning SIKERTELEN. Ellenőrizze a hálózati beállításokat és a hosztnevet."
    exit 1
fi

info_msg "Tartomány sikeresen létrehozva"

# --- 9. KRITIKUS KONFIGURÁCIÓK ---
section_header "8. KRITIKUS KONFIGURÁCIÓK"

# JAVÍTOTT: DNS konfiguráció (Saját DNS-re és forwarder-re)
configure_dns_fix || exit 1

# JAVÍTOTT: Kerberos konfiguráció (Samba által generált krb5.conf másolása)
configure_kerberos_fix || exit 1

# JAVÍTOTT: NetBIOS konfiguráció (NetBIOS név és workgroup beállítása)
configure_netbios_fix

# DNS forwarder hozzáadása (samba-tool provision nem mindig teszi meg)
if ! grep -q "dns forwarder" /etc/samba/smb.conf; then
    warn_msg "DNS forwarder hozzáadása az smb.conf-hoz: ${DNS_FORWARDER}"
    # Hozzáadás a [global] szekció után
    sed -i "/\[global\]/a\    dns forwarder = ${DNS_FORWARDER}" /etc/samba/smb.conf
fi

info_msg "/etc/samba/smb.conf tartalom (global):"
grep -A 10 "\[global\]" /etc/samba/smb.conf

# --- 10. SZOLGÁLTATÁSOK INDÍTÁSA ---
section_header "9. SZOLGÁLTATÁSOK INDÍTÁSA"

# Ütköző szolgáltatások leállítása és letiltása (fontos, hogy csak a samba-ad-dc fusson)
for svc in smbd nmbd winbind; do
    if systemctl is-active --quiet $svc; then
        warn_msg "Ütköző szolgáltatás leállítása: $svc"
        systemctl stop $svc
        systemctl disable $svc
    fi
done

info_msg "Samba AD DC szolgáltatás indítása..."
systemctl daemon-reload
systemctl unmask samba-ad-dc 2>/dev/null || true # Biztos, ami biztos, unmaskeljük
systemctl enable samba-ad-dc
systemctl restart samba-ad-dc

if systemctl is-active --quiet samba-ad-dc; then
    info_msg "Samba AD DC szolgáltatás sikeresen elindult"
else
    error_msg "Samba AD DC szolgáltatás indítása SIKERTELEN."
    error_msg "Nézze meg a logot és a systemctl status samba-ad-dc parancs kimenetét!"
    exit 1
fi

# --- 11. RÉSZLETES TESZTELÉS ---
section_header "10. RÉSZLETES TESZTELÉS"

info_msg "Várakozás a szolgáltatások stabilizálódására (20 másodperc)..."
sleep 20

info_msg "Szolgáltatás állapot (első 5 sor):"
systemctl status samba-ad-dc --no-pager -l | head -5

info_msg "Port ellenőrzés (53, 88, 389, 445 - DNS, Kerberos, LDAP, SMB):"
netstat -tlnp | grep -E ":53|:88|:389|:445" | head -10 || true

info_msg "DNS teszt (Samba DNS feloldja a saját nevét):"
if host -t A "${HOST_NAME}.${DOMAIN_NAME_LOWER}" 127.0.0.1 >/dev/null 2>&1; then
    info_msg "✅ DNS feloldás SIKERES: ${HOST_NAME}.${DOMAIN_NAME_LOWER}"
else
    warn_msg "⚠️ DNS feloldás részben sikertelen. Ellenőrizze a /etc/resolv.conf fájlt."
fi

info_msg "Kerberos alapvető teszt (Admin hitelesítés):"
# Jelszó átadás biztonságosan a kinit-nek
if timeout 10 sh -c "echo '${ADMIN_PASSWORD}' | kinit administrator@'${DOMAIN_NAME_UPPER}'" 2>/dev/null; then
    info_msg "✅ Kerberos hitelesítés SIKERES"
    klist 2>/dev/null | head -5
    kdestroy 2>/dev/null
else
    warn_msg "⚠️ Kerberos hitelesítés részben sikertelen (kinit hiba)."
    warn_msg "Kézi ellenőrzés: kinit administrator@${DOMAIN_NAME_UPPER}"
fi

# --- 12. BEFEJEZÉS ---
section_header "11. BEFEJEZÉS"

# Jelszó változó törlése a memóriából
unset ADMIN_PASSWORD ADMIN_PASSWORD_1 ADMIN_PASSWORD_2
info_msg "Admin jelszó törölve a memóriából."

echo -e "${CLR_GREEN}=================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}🎉 SAMBA AD DC TARTOMÁNYVEZÉRLŐ SIKERESEN TELEPÍTVE!${CLR_RESET}"
echo -e "${CLR_GREEN}=================================================================${CLR_RESET}"
echo ""
echo "📋 TELEPÍTÉSI ÖSSZEFOGLALÓ:"
echo -e "    • Tartomány (FQDN): ${CLR_BLUE}$DOMAIN_NAME_LOWER${CLR_RESET}"
echo -e "    • Admin felhasználó: ${CLR_BLUE}administrator@$DOMAIN_NAME_UPPER${CLR_RESET}"
echo -e "    • DC Hosztnév: ${CLR_BLUE}$HOST_NAME.$DOMAIN_NAME_LOWER${CLR_RESET}"
echo -e "    • DC IP: ${CLR_BLUE}$SERVER_IP${CLR_RESET}"
echo -e "    • NetBIOS Név: ${CLR_BLUE}$DOMAIN_NETBIOS${CLR_RESET}"
echo ""
echo "⚠️  FONTOS: Javasolt újraindítás a teljes funkcionalitás és a DNS beállítások érvényesítése érdekében!"
echo -e "${CLR_GREEN}=================================================================${CLR_RESET}"

echo -ne "${CLR_YELLOW}Nyomjon ENTER-t az újraindításhoz (ajánlott) vagy Ctrl+C a kézi újraindításhoz...${CLR_RESET}"
read

info_msg "Szerver újraindítása..."
if command -v reboot >/dev/null 2>&1; then
    reboot
else
    warn_msg "A reboot parancs nem elérhető. Kézzel indítsa újra!"
    echo "Használja: systemctl reboot"
fi

echo "================================================================"
echo "Telepítés befejezve: $(date)"
echo "================================================================"
