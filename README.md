# Samba Active Directory Tartományvezérlő Telepítő (Ubuntu)

## 📜 Áttekintés

Ez a Bash szkript automatizálja a **Samba 4** telepítését és konfigurálását **Active Directory (AD) tartományvezérlőként (DC)** Ubuntu szervereken (22.04 LTS vagy újabb). A szkript a maximális stabilitás érdekében kizárólag a **hivatalos Ubuntu tárolókat** használja a `samba-ad-dc` csomag telepítéséhez, és gondoskodik a DNS és Kerberos konfigurációk megfelelő beállításáról, elkerülve a gyakori `systemd-resolved` alapú DNS hibákat.

***

## ⚠️ Előfeltételek és Kritikus Első Lépés

A szkript futtatása előtt a szervernek statikus IP-címmel kell rendelkeznie, és a hálózati névfeloldásnak megfelelően be kell állítva.

### 1. Hosts Fájl Beállítása (Kritikus!)

A Samba AD DC megfelelő működéséhez a szervernek saját magát kell feloldania a teljes és rövid nevén is.

**Nyissa meg a `/etc/hosts` fájlt és illessze be a következő sort (cserélje ki a példákat a saját adataira):**

| Adat | Példa |
| :--- | :--- |
| **IP Cím** | `192.168.1.100` |
| **Teljes Név** | `dc1.cegnev.local` |
| **Rövid Név** | `dc1` |

**Beillesztendő sor:**

```hosts
192.168.1.100 dc1.cegnev.local dc1
