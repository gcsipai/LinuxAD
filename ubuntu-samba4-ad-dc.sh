#!/bin/bash

# =================================================================
# SAMBA 4 ACTIVE DIRECTORY TARTOMÁNYVEZÉRLŐ TELEPÍTŐ SCRIPT
# Támogatott rendszerek: Ubuntu 22.04 LTS-től
# Csak a hivatalos Ubuntu tárolókat használja.
# Kritikus hosts fájl beállítás az első lépésben.
# Helyes /etc/resolv.conf és DNS teszt beépítve.
# =================================================================

# -----------------------------------------------------------------
# Színkódok
# -----------------------------------------------------------------
CLR_ORANGE='\e[38;2;233;84;32m'
CLR_AUBERGINE='\e[38;2;119;33;111m'
CLR_RESET='\e[0m'

# -----------------------------------------------------------------
# 1. KRITIKUS HOSTS FÁJL KONFIGURÁCIÓS ADATOK BEKÉRÉSE
# -----------------------------------------------------------------
echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
echo -e "${CLR_AUBERGINE}        1. KRITIKUS HOSTS FÁJL BEÁLLÍTÁSÁHOZ SZÜKSÉGES ADATOK${CLR_RESET}"
echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"

# Szerver IP címe
read -p "$(echo -e "${CLR_ORANGE}▶️ Szerver statikus IP címe (Pl: 192.168.1.100): ${CLR_RESET}")" SERVER_IP

# Hosztnév
read -p "$(echo -e "${CLR_ORANGE}▶️ Szerver rövid hosztneve (Pl: dc1): ${CLR_RESET}")" HOST_NAME

# Teljes tartománynév (kisbetűvel)
read -p "$(echo -e "${CLR_ORANGE}▶️ Teljes tartománynév (kisbetűvel, Pl: cegnev.local): ${CLR_RESET}")" DOMAIN_NAME_LOWER

# Értékek ellenőrzése
if [ -z "$HOST_NAME" ] || [ -z "$DOMAIN_NAME_LOWER" ] || [ -z "$SERVER_IP" ]; then
    echo "================================================================="
    echo "❌ HIBA: A script megszakadt, mert hiányzik egy kritikus hálózati adat."
    echo "Kérjük, futtassa újra, és adja meg mindhárom kért értéket."
    exit 1
fi

# -----------------------------------------------------------------
# HOSTS FÁJL KÉZI MÓDOSÍTÁSÁNAK MEGERSÍTÉSE
# -----------------------------------------------------------------
echo -e "${CLR_ORANGE}=================================================================${CLR_RESET}"
echo -e "${CLR_ORANGE}!!! KÉREM VÉGEZZE EL A HOSTS FÁJL KÉZI BEÁLLÍTÁSÁT MOST !!!${CLR_RESET}"
echo "Nyissa meg a /etc/hosts fájlt, és illessze be a következő sort:"
echo -e "   ${CLR_AUBERGINE}${SERVER_IP} ${HOST_NAME}.${DOMAIN_NAME_LOWER} ${HOST_NAME}${CLR_RESET}"
echo "A folytatás előtt ez elengedhetetlen a Samba megfelelő névfeloldásához!"
echo "-----------------------------------------------------------------"
read -p "$(echo -e "${CLR_AUBERGINE}Ha a /etc/hosts fájl be van állítva, nyomjon ENTER-t a folytatáshoz...${CLR_RESET}")"

# -----------------------------------------------------------------
# 2. TOVÁBBI KONFIGURÁCIÓS ADATOK BEKÉRÉSE
# -----------------------------------------------------------------
echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
echo -e "${CLR_AUBERGINE}        2. TOVÁBBI TARTOMÁNY BEÁLLÍTÁSOK${CLR_RESET}"
echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"

# NetBIOS név (NAGYBETŰVEL)
read -p "$(echo -e "${CLR_ORANGE}▶️ NetBIOS tartománynév (NAGYBETŰVEL, Pl: CEGNEV): ${CLR_RESET}")" DOMAIN_NETBIOS

# Külső DNS továbbító
read -p "$(echo -e "${CLR_ORANGE}▶️ Külső DNS továbbító (Pl: 8.8.8.8): ${CLR_RESET}")" DNS_FORWARDER

# A többi adat automatikus generálása/átalakítása
DOMAIN_NAME_UPPER=$(echo "$DOMAIN_NAME_LOWER" | tr '[:lower:]' '[:upper:]')
ADMIN_PASSWORD="" 

if [ -z "$DOMAIN_NETBIOS" ]; then
    echo "================================================================="
    echo "❌ HIBA: A script megszakadt, mert hiányzik a NetBIOS név."
    echo "Kérjük, futtassa újra, és adja meg az összes kért értéket."
    exit 1
fi

# -----------------------------------------------------------------
# Funkciók
# -----------------------------------------------------------------

# Adminisztrátori jelszó bekérése biztonságosan
get_admin_password() {
    echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
    echo -e "${CLR_AUBERGINE}!!! ADJON MEG ADMINISZTRÁTORI JELSZÓT A PROVISIONING-HOZ !!!${CLR_RESET}"
    echo "Ez lesz a tartományi 'Administrator' felhasználó jelszava."
    
    while true; do
        read -s -p "Jelszó: " ADMIN_PASSWORD_1
        echo
        read -s -p "Jelszó megerősítése: " ADMIN_PASSWORD_2
        echo
        
        if [ "$ADMIN_PASSWORD_1" = "$ADMIN_PASSWORD_2" ]; then
            if [ -z "$ADMIN_PASSWORD_1" ]; then
                echo "❌ Hiba: A jelszó nem lehet üres. Próbálja újra."
            else
                ADMIN_PASSWORD="$ADMIN_PASSWORD_1"
                echo "✅ Jelszó sikeresen beállítva."
                break
            fi
        else
            echo "❌ Hiba: A két jelszó nem egyezik. Próbálja újra."
        fi
    done
}

# -----------------------------------------------------------------
# 3. ELŐKÉSZÜLETEK ÉS FRISSÍTÉS
# -----------------------------------------------------------------
echo -e "${CLR_ORANGE}▶️ 3. Előkészületek és Frissítés${CLR_RESET}"

# Előzetes futtatási ellenőrzések
if [ "$EUID" -ne 0 ]; then
  echo "❌ Hiba: Ezt a scriptet root jogosultsággal kell futtatni (sudo)."
  exit 1
fi

read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a csomagforrások frissítéséhez és a rendszer frissítéséhez...${CLR_RESET}")"

apt-get update -y
apt-get upgrade -y

echo "✅ A csomaglista frissítése és a rendszer frissítése sikeres volt."
read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a 4. lépéshez (Hosztnév beállítás)...${CLR_RESET}")"

# -----------------------------------------------------------------
# 4. HOSZTNÉV ÉS BEÁLLÍTÁSOK
# -----------------------------------------------------------------
echo -e "${CLR_ORANGE}▶️ 4. Hosztnév és alap beállítások${CLR_RESET}"
read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a hosztnév beállításához...${CLR_RESET}")"

# Hosztnév beállítása
hostnamectl set-hostname "${HOST_NAME}"
echo "   (A hosztnév beállítva: ${HOST_NAME})"

# Cloud-init beállítás
if [ -f /etc/cloud/cloud.cfg ]; then
    if ! grep -q "preserve_hostname: true" /etc/cloud/cloud.cfg; then
        echo "preserve_hostname: true" >> /etc/cloud/cloud.cfg
        echo "   (preserve_hostname beállítva a cloud-init-ben)"
    fi
fi

echo "✅ Hosztnév és cloud-init beállítások elvégezve."
read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t az 5. lépéshez (Samba és Kerberos telepítés)...${CLR_RESET}")"

# -----------------------------------------------------------------
# 5. SAMBA ÉS KERBEROS TELEPÍTÉS (INTERAKTÍV RÉSZ!)
# -----------------------------------------------------------------
echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
echo -e "${CLR_AUBERGINE}!!! FIGYELEM: FELUGRO ABLAKOK JÖNNEK (Kerberos konfiguráció) !!!${CLR_RESET}"
echo "Ezekben az ablakokban **kézzel** kell megadnod a beállításokat:"
echo "-----------------------------------------------------------------"
echo "1. Default Kerberos version 5 realm:"
echo "   -> ADJA MEG A TARTOMÁNYT NAGYBETŰVEL! (Pl: ${DOMAIN_NAME_UPPER})"
echo "2. Kerberos servers for your realm:"
echo "   -> ADJA MEG A DC TELJES NEVÉT! (Pl: ${HOST_NAME}.${DOMAIN_NAME_LOWER})"
echo "3. Administrative server for your realm:"
echo "   -> ADJA MEG A DC TELJES NEVÉT! (Pl: ${HOST_NAME}.${DOMAIN_NAME_LOWER})"
echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
read -p "$(echo -e "${CLR_AUBERGINE}Nyomjon ENTER-t a telepítés és a felugró ablakok elindításához...${CLR_RESET}")"

# Csomagok telepítése a hivatalos Ubuntu tárolóból
SAMBA_PACKAGES="samba-ad-dc krb5-user dnsutils python3-setproctitle"
apt-get install -y ${SAMBA_PACKAGES}

echo "✅ Samba és Kerberos csomagok telepítve."
read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a 6. lépéshez (Tartomány provisionálása)...${CLR_RESET}")"

# -----------------------------------------------------------------
# 6. TARTOMÁNY LÉTREHOZÁSA (PROVISIONING)
# -----------------------------------------------------------------
echo -e "${CLR_ORANGE}▶️ 6. Samba tartomány létrehozása (Provisioning)${CLR_RESET}"

# Jelszó bekérése közvetlenül a Provisioning előtt
get_admin_password
echo

read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a Provisioning végrehajtásához...${CLR_RESET}")"

# Előző smb.conf fájl átnevezése/mentése
if [ -f /etc/samba/smb.conf ]; then
    mv /etc/samba/smb.conf /etc/samba/smb.conf.bak
    echo "   (/etc/samba/smb.conf átnevezve smb.conf.bak-ra)"
fi

echo "   (Tartomány provisionálása... Ez eltarthat egy percig.)"
# A Samba provisionálás futtatása
samba-tool domain provision \
    --server-role=dc \
    --use-rfc2307 \
    --dns-backend=SAMBA_INTERNAL \
    --realm="${DOMAIN_NAME_UPPER}" \
    --domain="${DOMAIN_NETBIOS}" \
    --adminpass="${ADMIN_PASSWORD}"

# Ellenőrizzük a provisionálás kilépési kódját!
if [ $? -ne 0 ]; then
    echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
    echo "❌ VÉGZETES HIBA: A Provisioning (tartománylétrehozás) sikertelen volt."
    echo "Kérjük, ellenőrizze a fenti hibaüzeneteket."
    echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
    read -p "Nyomjon ENTER-t a script VÉGLEGES leállításához."
    exit 1
fi

# Mivel a provisioning sikerült, a krb5.conf létrejött.
if [ -f /var/lib/samba/private/krb5.conf ]; then
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    echo "   (Kerberos konfiguráció átmásolva: /etc/krb5.conf)"
else
    echo "❌ Hiba: A krb5.conf fájl nem található a Provisioning után. Ez kritikus hiba."
    read -p "Nyomjon ENTER-t a script VÉGLEGES leállításához."
    exit 1
fi

# KRITIKUS JAVÍTÁS: A szerver beállítása, hogy saját magát (DC) használja DNS-nek
echo "   (A szerver beállítása, hogy saját magát (DC) használja DNS-nek a resolv.conf-ban)"
# 1. Megszüntetjük a symlinket, ha a systemd-resolved hozta létre
if [ -L /etc/resolv.conf ]; then
    unlink /etc/resolv.conf
fi
# 2. Létrehozzuk az új resolv.conf-ot a 127.0.0.1 (helyi DNS) címmel
echo "# Generálva Samba AD DC Provisioning által" > /etc/resolv.conf
echo "nameserver 127.0.0.1" >> /etc/resolv.conf
echo "search ${DOMAIN_NAME_LOWER}" >> /etc/resolv.conf
echo "   (/etc/resolv.conf beállítva 127.0.0.1-re)"


echo "✅ Tartomány sikeresen létrehozva (Provisioning)."
read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a 7. lépéshez (Befejező beállítások)...${CLR_RESET}")"

# -----------------------------------------------------------------
# 7. BFEJEZŐ BEÁLLÍTÁSOK
# -----------------------------------------------------------------
echo -e "${CLR_ORANGE}▶️ 7. Befejező beállítások${CLR_RESET}"
read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a DNS továbbító és systemd-resolved beállításához...${CLR_RESET}")"

# DNS továbbító beállítása (külső feloldáshoz)
echo "   (DNS továbbító beállítása: ${DNS_FORWARDER})"
sed -i "/\[global\]/a\\    dns forwarder = ${DNS_FORWARDER}" /etc/samba/smb.conf

# Systemd-resolved kikapcsolása
echo "   (Systemd-resolved kikapcsolása a DNS konfliktus elkerülése érdekében)"
systemctl disable systemd-resolved.service
systemctl stop systemd-resolved.service

echo "✅ Befejező beállítások (DNS forwarder, systemd-resolved) elvégezve."
read -p "$(echo -e "${CLR_ORANGE}Nyomjon ENTER-t a 8. lépéshez (Ellenőrzés és Újraindítás)...${CLR_RESET}")"

# -----------------------------------------------------------------
# 8. ELLENŐRZÉS ÉS ÚJRAINDÍTÁS
# -----------------------------------------------------------------
echo -e "${CLR_AUBERGINE}▶️ 8. Ellenőrzés és Újraindítás${CLR_RESET}"

# Indítsuk el a Sambát az ellenőrzéshez
service samba-ad-dc restart 2>/dev/null || samba

echo "--- MŰKÖDÉSI ELLENŐRZÉS: DNS TESZT ---"

# KRITIKUS JAVÍTÁS: DNS feloldás ellenőrzése a DC saját IP-címén keresztül
echo "   (nslookup futtatása a szerver IP-címén: ${SERVER_IP})"
nslookup "${DOMAIN_NAME_LOWER}" ${SERVER_IP}

if [ $? -eq 0 ]; then
    echo ""
    echo "🎉 SIKERES DNS TESZT! A ${DOMAIN_NAME_LOWER} tartomány IP-címe látható a fenti kimenetben."
    echo "Ez azt jelenti, hogy a Samba AD DC szolgáltatás már fut és válaszol a DNS kérésekre."
else
    echo ""
    echo "❌ HIBA A DNS TESZTBEN! A tartomány feloldása nem sikerült."
    echo "Kérjük, ellenőrizze a HOSTS fájlt és a Provisioning logjait a hiba feletti kimenetben."
fi

echo -e "${CLR_AUBERGINE}=================================================================${CLR_RESET}"
echo "A telepítés befejeződött. Az összes beállítás érvényesítéséhez újraindítás szükséges."
read -p "$(echo -e "${CLR_AUBERGINE}Nyomjon ENTER-t a szerver **VÉGLEGES** újraindításához...${CLR_RESET}")"

# Újraindítás
reboot
