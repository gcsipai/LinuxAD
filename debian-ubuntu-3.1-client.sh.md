# Active Directory (AD) Integrációs Script – Debian/Ubuntu (V3.1)

Ez a Bash script egy **interaktív, menüvezérelt megoldás** Active Directory tartományba való integrációra Debian vagy Ubuntu Linux szervereken. Célja a **központosított AD hitelesítés (SSSD)** és a stabil tartományi működéshez elengedhetetlen hálózati (DNS/Netplan) és időszinkronizációs (NTP/Chrony) beállítások automatizálása.

---

## 🚀 Főbb Jellemzők

* **Teljesen menüvezérelt:** A felhasználót a szükséges konfigurációs lépéseken vezeti végig.
* **Kritikus komponensek:** Telepíti és konfigurálja a **`realmd`**, **`sssd`**, **`chrony`** és **`netplan.io`** csomagokat.
* **Hálózati előkészítés:** Beállítja az időzónát, az **NTP szinkronizációt** a DC-vel, és a Netplan DNS beállításait a Domain Controller IP-címére.
* **SSSD finomhangolás:** Lehetővé teszi az olyan fejlett beállításokat, mint a **teljesen minősített nevek (FQN) elhagyása** és a **fix UID/GID** használata.
* **Biztonsági mentés:** Minden kritikus konfigurációs fájl módosítása előtt **automatikusan mentést** készít időbélyegzővel.
* **Visszaállítási opció:** Külön menüpontot tartalmaz a tartomány elhagyására (`realm leave`).

---

## ⚠️ Előfeltételek

A stabil integrációhoz az alábbiak szükségesek:

1.  **Jogosultság:** A scriptet **root felhasználóként** kell futtatni (`sudo`).
2.  **Hálózat:** A szerver rendelkezzen **statikus IP-címmel**.
3.  **AD adatok:** Ismert DC IP-cím és egy AD Domain Admin hitelesítő adatai szükségesek.
4.  **Hostnév:** A Linux szerver hostneve legyen a kívánt név a tartományban.

---

## 🛠️ Használat és Ajánlott Sorrend

A script futtatásához használja a következő parancsot:

```bash
sudo ./debian-ubuntu-3.1-client.sh
