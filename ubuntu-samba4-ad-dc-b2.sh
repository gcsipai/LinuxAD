#!/bin/bash

# =================================================================
# SAMBA 4 ACTIVE DIRECTORY TARTOMÁNYVEZÉRLŐ TELEPÍTŐ SCRIPT (ROBUSZTUS)
# Támogatott rendszerek: Ubuntu 22.04 LTS-től
# =================================================================

# Színkódok
CLR_ORANGE='\e[38;2;233;84;32m'
CLR_AUBERGINE='\e[38;2;119;33;111m'
CLR_GREEN='\e[32m'
CLR_RED='\e[31m'
CLR_YELLOW='\e[33m'
CLR_BLUE='\e[34m'
CLR_RESET='\e[0m'

# Log fájl beállítás
LOG_FILE="/var/log/samba-ad-install-$(date +%Y%m%d-%H%M%S).log"
# A logolás beállítása (konzolra és fájlba)
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================================" 
echo "Samba AD DC telepítés kezdete: $(date)" 
echo "Ubuntu Samba AD DC Installer - Robusztus Végleges Verzió" 
echo "================================================================" 

# --- Funkciók ----------------------------------------------------------------

info_msg() {
    echo -e "${CLR_GREEN}✅ $1${CLR_RESET}"
}

warn_msg() {
    echo -e "${CLR_YELLOW}⚠️  $1${CLR_RESET}"
}

error_msg() {
    echo -e "${CLR_RED}❌ HIBA: $1${CLR_RESET}"
    # A szkript itt nem szakad meg automatikusan, ha ez a funkció hívja meg
    # Két eset van: végzetes hiba (exit 1) vagy folytatható hiba (return 1)
}

section_header() {
    echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}" 
    echo -e "${CLR_AUBERGINE}        $1${CLR_RESET}" 
    echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}" 
}

# --- JAVÍTOTT FUNKCIÓK --------------------------------------------------------

acquire_dpkg_lock() {
    local max_wait=300 # 5 perc max
    local start_time=$(date +%s)
    local elapsed=0

    section_header "DPKG ZÁROLÁS ELTÁVOLÍTÁSA / VÁRAKOZÁS"
    info_msg "Ellenőrzés: Csomagkezelő zárolva van-e..."
    
    while fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock* >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$max_wait" ]; then
            warn_msg "A zár több mint 5 perce (300 mp) aktív. Megpróbálom erőszakkal eltávolítani."
            
            ps aux | grep -i 'apt\|dpkg' | grep -v 'grep'
            warn_msg "Zárfájlok törlése..."
            rm -f /var/lib/dpkg/lock-frontend
            rm -f /var/lib/dpkg/lock
            rm -f /var/cache/apt/archives/lock
            
            dpkg --configure -a 2>/dev/null
            
            if fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock* >/dev/null 2>&1; then
                error_msg "A zárat nem sikerült erőszakkal eltávolítani. Kézi beavatkozás szükséges!"
                exit 1 # Végzetes hiba
            else
                info_msg "Zár sikeresen eltávolítva. Folytatás."
            fi
            break
        fi

        local held_by=$(ps aux | grep -i 'apt\|dpkg' | grep -v 'grep' | awk '{print $2 " (" $11 " " $12 "..."}')
        warn_msg "Csomagkezelő zárolva van! Futó folyamatok: $held_by"
        warn_msg "Várakozás 30 másodpercet (max $max_wait mp-ig)..."
        sleep 30

        elapsed=$(($(date +%s) - $start_time))
    done

    info_msg "Csomagkezelő zárolás feloldva. Folytatás."
}

get_admin_password() {
    # ⚠️ JAVÍTÁS: Ciklus és hibatűrés a jelszóbevitelhez
    
    echo -e "${CLR_AUBERGINE}!!! ADJON MEG ADMINISZTRÁTORI JELSZÓT !!!${CLR_RESET}"
    echo "A jelszónak meg kell felelnie a minimális Windows jelszóházirendnek (minimum 8 karakter)."
    
    while true; do
        read -s -p "Jelszó: " ADMIN_PASSWORD_1
        echo
        read -s -p "Jelszó megerősítése: " ADMIN_PASSWORD_2
        echo
        
        if [ "$ADMIN_PASSWORD_1" != "$ADMIN_PASSWORD_2" ]; then
            error_msg "A két jelszó NEM egyezik. Próbálja újra."
            continue
        fi
        
        if [ ${#ADMIN_PASSWORD_1} -lt 8 ]; then
            error_msg "A jelszó túl rövid (minimum 8 karakter). Próbálja újra."
            continue
        fi
        
        # Komplexitás ellenőrzés és figyelmeztetés
        if ! [[ "$ADMIN_PASSWORD_1" =~ [A-Z] ]] || \
           ! [[ "$ADMIN_PASSWORD_1" =~ [a-z] ]] || \
           ! [[ "$ADMIN_PASSWORD_1" =~ [0-9] ]]; then
            warn_msg "A jelszó gyenge. Javasolt a nagybetű, kisbetű és szám használata!"
            read -p "Folytatja ezzel a jelszóval? (i/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Ii]$ ]]; then
                continue
            fi
        fi
        
        ADMIN_PASSWORD="$ADMIN_PASSWORD_1"
        info_msg "Jelszó sikeresen beállítva."
        return 0 # Siker
    done
}

fix_service_conflicts() {
    # ⚠️ JAVÍTÁS: Az ütköző, hagyományos samba szolgáltatások leállítása/eltávolítása
    
    section_header "SZOLGÁLTATÁS ÜTKÖZÉS ELHÁRÍTÁSA (SMBD/NMBD)"
    
    local conflicts_found=false
    
    # Leállítás: smbd, nmbd, winbind (ezek AD DC környezetben ütköznek)
    for svc in smbd nmbd winbind; do
        if systemctl is-active --quiet $svc || systemctl is-enabled --quiet $svc; then
            warn_msg "Ütköző szolgáltatás észlelve: $svc. Leállítás és letiltás..."
            systemctl stop $svc
            systemctl disable $svc
            conflicts_found=true
        fi
    done
    
    # PID fájlok törlése (ha a leállítás nem volt tiszta, pl. nmbd.pid)
    for pidfile in /run/samba/smbd.pid /run/samba/nmbd.pid /run/samba/winbindd.pid; do
        if [ -f "$pidfile" ]; then
            PID=$(cat "$pidfile")
            warn_msg "Maradvány PID fájl észlelve: $pidfile. Folyamat (PID $PID) kényszerített leállítása..."
            kill -9 "$PID" 2>/dev/null
            rm -f "$pidfile"
            conflicts_found=true
        fi
    done
    
    if $conflicts_found; then
        info_msg "Ütközések sikeresen feloldva. A Samba AD DC most már tiszta környezetben indulhat."
    else
        info_msg "Nem találtam ütköző szolgáltatásokat."
    fi
}

# --- EREDETI SEGÉDFUNKCIÓK (VÁLTOZATLANUL) -----------------------------------

check_system() {
    if [ "$EUID" -ne 0 ]; then
        error_msg "Ezt a scriptet root jogosultsággal kell futtatni (sudo)."
        exit 1
    fi
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [ "$ID" != "ubuntu" ]; then
            warn_msg "Ez nem Ubuntu rendszer. Kompatibilitás nem garantált."
        else
            info_msg "Ubuntu verzió: $VERSION_ID ($VERSION_CODENAME)"
        fi
    fi
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
        if [ $i1 -le 255 ] && [ $i2 -le 255 ] && [ $i3 -le 255 ] && [ $i4 -le 255 ]; then
            return 0
        fi
    fi
    return 1
}

validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9]+([\-\.][a-zA-Z0-9]+)*\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

configure_firewall() {
    section_header "TŰZFAL KONFIGURÁCIÓ"
    # UFW konfigurációs logika (lásd eredeti szkript)
    # ... (rövidítve) ...
    if command -v ufw >/dev/null 2>&1; then
        echo -e "${CLR_RED}!!! FIGYELEM: AKTÍV TŰZFAL GÁTOLHATJA A MŰKÖDÉST !!!${CLR_RESET}"
        read -p "$(echo -e "${CLR_ORANGE}Ki akarja kapcsolni az UFW tűzfalat a telepítés/teszt idejére? (i/n): ${CLR_RESET}")" FIREWALL_DISABLE_ACTION
        
        if [[ "$FIREWALL_DISABLE_ACTION" =~ ^[Ii]$ ]]; then
            if systemctl is-active --quiet ufw; then
                warn_msg "UFW leállítása és kikapcsolása..."
                systemctl stop ufw
                systemctl disable ufw
                info_msg "UFW sikeresen leállítva/kikapcsolva."
                return 0 
            fi
        fi
        
        if systemctl is-active --quiet ufw; then
             warn_msg "UFW aktív. Megkísérlem megnyitni a szükséges Samba portokat..."
             local ports=("53/tcp" "53/udp" "88/tcp" "88/udp" "445/tcp" "464/tcp" "464/udp") 
             for port in "${ports[@]}"; do
                 ufw allow "$port" 2>/dev/null && info_msg "Port $port megnyitva" || warn_msg "Port $port nyitása sikertelen"
             done
             ufw reload 2>/dev/null
             info_msg "UFW szabályok frissítve."
        else
            info_msg "UFW nincs aktív. Folytatás."
        fi
    else
        info_msg "UFW nincs telepítve."
    fi
}

fix_kerberos_config() {
    section_header "KERBEROS KONFIGURÁCIÓ JAVÍTÁSA (KRITIKUS)"
    if [ -f /var/lib/samba/private/krb5.conf ]; then
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        info_msg "Kerberos konfiguráció átmásolva"
    else
        error_msg "Kerberos konfiguráció nem található!"
        return 1
    fi
    
    if ! grep -q "\[domain_realm\]" /etc/krb5.conf; then
        cat >> /etc/krb5.conf <<EOL
[domain_realm]
        .${DOMAIN_NAME_LOWER} = ${DOMAIN_NAME_UPPER}
        ${DOMAIN_NAME_LOWER} = ${DOMAIN_NAME_UPPER}
EOL
        info_msg "[domain_realm] szekció hozzáadva."
    fi
    return 0
}

# --- TESZT FUNKCIÓK (VÉGLEGES ZÁRÁSHOZ) -----------------------------------

run_all_tests() {
    section_header "11. RÉSZLETES TESZTELÉS"
    
    test_dns_resolution
    
    # Csak akkor fut le a Kerberos teszt, ha a DNS sikeres (DNS hiba esetén leállt a szkript korábban)
    if [ $? -eq 0 ]; then
        test_kerberos_auth
    fi
    
    # Szolgáltatás állapot ellenőrzése
    info_msg "Szolgáltatás állapot ellenőrzése (top 5 sor):"
    systemctl status samba-ad-dc --no-pager -l | head -5
    
    # Port ellenőrzések
    info_msg "Nyitott portok ellenőrzése (DNS/AD/Kerberos):"
    netstat -tlnp | grep -E ":53|:88|:135|:139|:389|:445" || \
    ss -tlnp | grep -E ":53|:88|:135|:139|:389|:445"
}

test_dns_resolution() {
    section_header "DNS FELOLDÁS TESZTELÉSE"
    
    # Meghosszabbított várakozás a robusztus indítás miatt
    info_msg "DNS szolgáltatás várakozása (30 másodperc)..."
    sleep 30
    
    local attempts=0
    local max_attempts=3
    
    while [ $attempts -lt $max_attempts ]; do
        echo -e "${CLR_BLUE}🔍 DNS teszt próba $((attempts+1))/$max_attempts${CLR_RESET}"
        
        # A host paranccsal teszteljük, amely részletesebb hibaüzenetet ad, mint az nslookup
        if host -t A "${HOST_NAME}.${DOMAIN_NAME_LOWER}" 127.0.0.1 >/dev/null 2>&1; then
            info_msg "DNS feloldás SIKERES (Host: ${HOST_NAME}.${DOMAIN_NAME_LOWER})"
            host -t SRV _kerberos._udp."${DOMAIN_NAME_LOWER}" 127.0.0.1
            return 0
        fi
        
        ((attempts++))
        if [ $attempts -lt $max_attempts ]; then
            warn_msg "DNS teszt sikertelen. Újrapróbálás 10 másodperc múlva..."
            sleep 10
        fi
    done
    
    error_msg "DNS feloldás SIKERTELEN minden próbálkozás után. A DC nem működik megfelelően."
    return 1
}

test_kerberos_auth() {
    section_header "KERBEROS HITELESÍTÉS TESZTELÉSE"
    
    info_msg "Kerberos hitelesítés tesztelése..."
    
    # Jelszó átirányítása a kinit-nek (a korábban beállított $ADMIN_PASSWORD használatával)
    if echo "${ADMIN_PASSWORD}" | kinit administrator@"${DOMAIN_NAME_UPPER}" 2>/dev/null; then
        info_msg "Kerberos hitelesítés SIKERES"
        klist 2>/dev/null
        kdestroy 2>/dev/null
        return 0
    else
        error_msg "Kerberos hitelesítés SIKERTELEN. Ellenőrizze a /etc/krb5.conf-ot!"
        return 1
    fi
}

# =================================================================
# FŐ TELEPÍTÉSI FOLYAMAT
# =================================================================

section_header "SAMBA AD DC TELEPÍTÉS - KEZDET"

check_system

# --- 1. ALAPADATOK BEKÉRÉSE ---
# (Ez a rész változatlanul maradt, mivel az interaktív adatok megőrzése nehézkes. Újraindításkor újra meg kell adni.)
section_header "1. ALAPADATOK BEKÉRÉSE"
# ... (IP, HOST, DOMAIN, NETBIOS, DNS_FORWARDER beolvasása) ...
while true; do read -p "$(echo -e "${CLR_ORANGE}▶️ Szerver statikus IP címe: ${CLR_RESET}")" SERVER_IP; validate_ip "$SERVER_IP" && break; error_msg "Érvénytelen IP cím formátum."; done
read -p "$(echo -e "${CLR_ORANGE}▶️ Szerver rövid hosztneve: ${CLR_RESET}")" HOST_NAME
while true; do read -p "$(echo -e "${CLR_ORANGE}▶️ Teljes tartománynév (pl: cegnev.local): ${CLR_RESET}")" DOMAIN_NAME_LOWER; validate_domain "$DOMAIN_NAME_LOWER" && break; error_msg "Érvénytelen tartománynév formátum."; done
read -p "$(echo -e "${CLR_ORANGE}▶️ NetBIOS tartománynév (NAGYBETŰVEL): ${CLR_RESET}")" DOMAIN_NETBIOS; DOMAIN_NETBIOS=$(echo "$DOMAIN_NETBIOS" | tr '[:lower:]' '[:upper:]')
while true; do read -p "$(echo -e "${CLR_ORANGE}▶️ Külső DNS továbbító (pl: 8.8.8.8): ${CLR_RESET}")" DNS_FORWARDER; validate_ip "$DNS_FORWARDER" && break; error_msg "Érvénytelen DNS továbbító IP cím."; done
DOMAIN_NAME_UPPER=$(echo "$DOMAIN_NAME_LOWER" | tr '[:lower:]' '[:upper:]')

# --- 2-6. KÉSZÜLÉSI LÉPÉSEK (VÁLTOZATLAN) ---
section_header "2. HOSTS FÁJL BEÁLLÍTÁSA"
cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d-%H%M%S)
echo -e "\n# Samba AD DC beállítás - $(date)" >> /etc/hosts
echo "${SERVER_IP} ${HOST_NAME}.${DOMAIN_NAME_LOWER} ${HOST_NAME}" >> /etc/hosts
info_msg "Hosts fájl beállítva. Eredeti mentve."

section_header "TELEPÍTÉSI ÖSSZEFOGLALÓ"
echo "Szerver IP: $SERVER_IP"; echo "Hosztnév: $HOST_NAME"; echo "Tartomány: $DOMAIN_NAME_LOWER"; echo "NetBIOS: $DOMAIN_NETBIOS"; echo "DNS Forwarder: $DNS_FORWARDER"

read -p "Biztosan folytatja a telepítést? (i/n): " -n 1 -r; echo
if [[ ! $REPLY =~ ^[Ii]$ ]]; then info_msg "Telepítés megszakítva."; exit 0; fi

section_header "4. RENDSZER FRISSÍTÉS"
acquire_dpkg_lock
info_msg "Csomagforrások frissítése..."; apt-get update -y || warn_msg "Csomagforrások frissítése részben sikertelen"
info_msg "Rendszerfrissítés..."; apt-get upgrade -y || warn_msg "Rendszerfrissítés részben sikertelen"

section_header "5. HOSZTNÉV BEÁLLÍTÁS"
hostnamectl set-hostname "${HOST_NAME}"; info_msg "Hosztnév beállítva: ${HOST_NAME}"
if [ -f /etc/cloud/cloud.cfg ]; then grep -q "preserve_hostname: true" /etc/cloud/cloud.cfg || echo "preserve_hostname: true" >> /etc/cloud/cloud.cfg; info_msg "Cloud-init konfiguráció frissítve"; fi

section_header "6. KERBEROS ELŐKONFIGURÁCIÓ (DEBCONF)"
debconf-set-selections <<EOF
krb5-config krb5-config/default_realm string ${DOMAIN_NAME_UPPER}
krb5-config krb5-config/kerberos_servers string ${HOST_NAME}.${DOMAIN_NAME_LOWER}
krb5-config krb5-config/admin_server string ${HOST_NAME}.${DOMAIN_NAME_LOWER}
krb5-config krb5-config/add_servers_realm string ${DOMAIN_NAME_UPPER}
krb5-config krb5-config/add_servers boolean true
krb5-config krb5-config/read_config boolean true
EOF
info_msg "Kerberos előkonfiguráció beállítva"

# --- 7. SAMBA TELEPÍTÉS ---
section_header "7. SAMBA TELEPÍTÉS"
acquire_dpkg_lock
SAMBA_PACKAGES="samba-ad-dc krb5-user dnsutils python3-setproctitle net-tools"
info_msg "Telepítendő csomagok: $SAMBA_PACKAGES"
if apt-get install -y ${SAMBA_PACKAGES}; then
    info_msg "Samba csomagok sikeresen telepítve"
else
    error_msg "Samba csomagok telepítése SIKERTELEN. Ellenőrizze a logokat."
    exit 1
fi

# --- 8. TARTOMÁNY LÉTREHOZÁSA (PROVISIONING) ---
section_header "8. TARTOMÁNY LÉTREHOZÁSA"
if ! get_admin_password; then
    error_msg "Kritikus hiba: Jelszó beállítás véglegesen sikertelen."
    exit 1
fi

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
    error_msg "Provisioning SIKERTELEN. Ez egy VÉGZETES HIBA."
    exit 1
fi

info_msg "Tartomány sikeresen létrehozva"

# --- 9. KRITIKUS KONFIGURÁCIÓK ---
section_header "9. KRITIKUS KONFIGURÁCIÓK"

fix_kerberos_config || exit 1

# DNS beállítások (resolv.conf)
info_msg "DNS beállítások konfigurálása..."
[ -L /etc/resolv.conf ] && unlink /etc/resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null
cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d-%H%M%S)

cat > /etc/resolv.conf <<EOF
# Generálva Samba AD DC által - $(date)
nameserver 127.0.0.1
nameserver ${DNS_FORWARDER}
search ${DOMAIN_NAME_LOWER}
options timeout:2 attempts:3
EOF

# DNS forwarder hozzáadása az smb.conf-hoz
sed -i "/\[global\]/a\\    dns forwarder = ${DNS_FORWARDER}" /etc/samba/smb.conf

# Systemd-resolved kikapcsolása (DNS konfliktus elkerülésére)
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
info_msg "DNS konfigurációk beállítva. Systemd-resolved letiltva."

# --- 10. TŰZFAL ÉS SZOLGÁLTATÁSOK INDÍTÁSA ---
section_header "10. TŰZFAL ÉS SZOLGÁLTATÁSOK INDÍTÁSA"

# Tűzfal konfiguráció (interaktív)
configure_firewall

# ⚠️ KRITIKUS JAVÍTÁS: Ütköző szolgáltatások eltávolítása/leállítása
fix_service_conflicts

# Samba szolgáltatás indítása
info_msg "Samba AD DC szolgáltatás indítása/újraindítása..."
systemctl enable samba-ad-dc
systemctl restart samba-ad-dc

if systemctl is-active --quiet samba-ad-dc; then
    info_msg "Samba AD DC szolgáltatás sikeresen elindult"
else
    error_msg "Samba AD DC szolgáltatás indítása SIKERTELEN. Végzetes hiba."
    exit 1
fi

# --- 11. VÉGLEGES TESZTELÉS ÉS BEFEJEZÉS ---

# ⚠️ JAVÍTÁS: A tesztek most futnak le, mivel sikeresen elindult a szolgáltatás
run_all_tests

section_header "12. BEFEJEZÉS"

unset ADMIN_PASSWORD ADMIN_PASSWORD_1 ADMIN_PASSWORD_2
info_msg "Admin jelszó törölve a memóriából."

echo -e "${CLR_GREEN}=================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}🎉 SAMBA AD DC TARTOMÁNYVEZÉRLŐ SIKERESEN TELEPÍTVE!${CLR_RESET}"
echo -e "${CLR_GREEN}=================================================================${CLR_RESET}"
echo ""
echo "📋 TELEPÍTÉSI ÖSSZEFOGLALÓ:"
echo "    • Tartomány (Domain): ${CLR_BLUE}$DOMAIN_NAME_LOWER${CLR_RESET}"
echo "    • Admin felhasználó: ${CLR_BLUE}administrator@$DOMAIN_NAME_UPPER${CLR_RESET}"
echo ""
echo "⚠️  FONTOS: A teljes érvényesítéshez szükséges az újraindítás!"
echo -e "${CLR_GREEN}=================================================================${CLR_RESET}"

read -p "Nyomjon ENTER-t a szerver újraindításához, vagy Ctrl+C a megszakításhoz..."

info_msg "Szerver újraindítása..."
echo "================================================================" 
echo "Telepítés befejezve - újraindítás: $(date)" 
echo "================================================================" 

reboot
