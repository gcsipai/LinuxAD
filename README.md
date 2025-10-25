# 🚀 Samba AD DC Telepítő Szkript (v2.0)

A szkript célja a **Samba Active Directory Domain Controller (AD DC)** telepítésének és kritikus konfigurációjának automatizálása Linuxon. Fő funkciója a DNS, Kerberos és NetBIOS hibák kiküszöbölése, stabil és Windows-kompatibilis tartományvezérlő létrehozásával.

***

## 💻 Támogatott Operációs Rendszerek

Mivel a szkript **`apt-get`** parancsokat és modern `systemd` szolgáltatásokat használ, elsősorban a következő **Debian-alapú** rendszereket támogatja:

| Rendszer | Verzió | Ikon | Megjegyzés |
| :--- | :--- | :--- | :--- |
| **Debian** | 13 (Trixie) | 🌀 | *A Debian alapjait szimbolizáló szimbólum.* |
| **Ubuntu Server** | 22.04 LTS (Jammy) | 🌐 | *A Linux és közösség szimbóluma.* |

***

## 🛠️ Telepített Főbb Szolgáltatások

A szkript a következő kritikus szolgáltatásokat telepíti/konfigurálja:

| Szolgáltatás | Ikon | Leírás |
| :--- | :--- | :--- |
| **Samba AD DC** | 💾 | A fő tartományvezérlő szoftver. |
| **DNS Szerver** | 📡 | A Samba saját, belső DNS szervere kezeli a tartományi feloldást. |
| **Kerberos** | 🔑 | Biztosítja a hitelesítést (KDC - Key Distribution Center). |
| **LDAP** | 📖 | Directory Service az AD objektumok tárolására (felhasználók, csoportok). |
| **NetBIOS** | 🔄 | Támogatás a régebbi Windows-os hálózati névfeloldáshoz. |

***

## ✨ Főbb Jellemzők és Hibajavítások

A szkript a provisionálás során felmerülő legkritikusabb problémák kezelésére fókuszál:

| Problémakör | Célja |
| :--- | :--- |
| **DNS Ütközés (Fix)** | Leállítja és letiltja a `systemd-resolved` szolgáltatást, majd beállítja a `127.0.0.1` címet (Samba belső DNS) elsődleges névszervernek az `/etc/resolv.conf` fájlban. |
| **Kerberos Konfiguráció (Fix)** | Biztosítja a Samba által generált, helyes `krb5.conf` fájl használatát. |
| **NetBIOS Kompatibilitás** | Automatikusan beállítja a `netbios name` és `workgroup` paramétereket az `smb.conf` fájlban. |

***

## 📝 Használat

Töltse le a szkriptet, tegye futtathatóvá, majd futtassa `root` jogokkal:

```bash
# Töltse le a szkriptet
wget [a szkript linkje] -O samba-ad-install.sh

# Tegye futtathatóvá
chmod +x samba-ad-install.sh

# Futtatás
sudo ./samba-ad-install.sh
