# 🚀 Samba AD DC Telepítő Szkript (v2.0b) 💾

## `ubuntu22x-debian13-samba4-ad-dc-2.0b.sh`

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Shell](https://img.shields.io/badge/Shell-Bash-blue)](https://www.gnu.org/software/bash/)
[![Systemd](https://img.shields.io/badge/Init-systemd-darkred)](https://systemd.io/)
[![Samba AD DC](https://img.shields.io/badge/Samba%204.x-AD%20DC-0077D4?logo=samba&logoColor=white)](https://www.samba.org/)

---

## 💡 Áttekintés

Ez a Bash szkript automatizálja a **Samba Active Directory Domain Controller (AD DC)** telepítését és kritikus konfigurációját. Kifejezetten a modern **Debian-alapú** Linux rendszerekhez lett optimalizálva, kiküszöbölve a provisionálás során felmerülő gyakori **DNS, Kerberos és NetBIOS hibákat**. A cél egy stabil és Windows-kliensekkel teljesen kompatibilis tartományvezérlő létrehozása.

**Verzió:** `v2.0b (Optimized & Fix-applied)`

---

## 💻 Támogatott Platformok és Szolgáltatások

| Kategória | Alkalmazás / Rendszer | Verzió / Ikon | Szerep |
| :--- | :--- | :--- | :--- |
| **Operációs Rendszer** | Ubuntu Server | [![Ubuntu Supported](https://img.shields.io/badge/Ubuntu-22.04%20LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/) | Célplatform |
| **Operációs Rendszer** | Debian | [![Debian Supported](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A80030?logo=debian&logoColor=white)](https://www.debian.org/) | Célplatform |
| **Core Szolgáltatás** | Samba AD DC | [![Samba 4.x](https://img.shields.io/badge/Samba-4.x%20AD%20DC-0077D4?logo=samba&logoColor=white)](https://www.samba.org/) | Tartományvezérlő |
| **Core Szolgáltatás** | DNS Szerver | `📡` | Belső DNS feloldás és AD zónák kezelése |
| **Core Szolgáltatás** | Kerberos KDC | `🔑` | Hitelesítési (ticket) szolgáltatás |
| **Core Szolgáltatás** | LDAP | `📖` | Directory Services adatbázis |
| **Kiegészítő** | `apt-get` | `📦` | Csomagkezelő motor |

---

## ✨ Kritikus Javítások és Főbb Funkciók

A szkript a provisionálás során felmerülő leggyakoribb stabilitási problémák kezelésére fókuszál:

| Funkció Kategória | Kulcsfunkciók | Leírás / Megbízhatóság |
| :--- | :--- | :--- |
| **DNS Konfliktus Kezelése** | `configure_dns_fix` | **Letiltja a `systemd-resolved`-et** és az `/etc/resolv.conf` fájlt 127.0.0.1-re állítja. Ez kritikus a Samba stabil DNS-működéséhez. |
| **Kerberos Stabilitás** | `configure_kerberos_fix` | Átmásolja a Samba által generált, garantáltan helyes `krb5.conf` fájlt az `/etc` mappába, biztosítva a megbízható hitelesítést. |
| **NetBIOS Kompatibilitás** | `configure_netbios_fix` | Hozzáadja a NetBIOS nevet és a `dns forwarder` beállítást az `smb.conf`-hoz a Windows kliensekkel való kompatibilitás érdekében. |
| **Interakció** | Adatbekérés és Provisionálás | Interaktívan bekéri a **Statikus IP**, **Tartományi Név** és **Adminisztrátori Jelszó** adatokat a `samba-tool domain provision` előtt. |

---

## 🚀 Használat

### 1. Előkészítés

Győződjön meg róla, hogy a szkript **`ubuntu22x-debian13-samba4-ad-dc-2.0b.sh`** néven létezik a rendszereden, és a szerverhez **statikus IP-cím** van beállítva!

```bash
# Adjon futtatási jogosultságot
sudo chmod +x ubuntu22x-debian13-samba4-ad-dc-2.0b.sh
