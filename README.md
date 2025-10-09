# 🛡️ Samba Active Directory Domain Controller Telepítő Szkript (V6.4 FINAL PR)

**Fájlnév:** `ubuntu-installer-6.4-samba-ad-dc.sh`

Ez a szkript egy robusztus, biztonságos és automatizált megoldás a **Samba4 Active Directory Domain Controller (AD DC)** telepítésére Debian-alapú rendszereken, különös tekintettel az **Ubuntu 22.04 LTS** és újabb szerververziókra.

A V6.4-es verzió **Production Ready** minősítést kapott, magába foglalva a kritikus biztonsági és megbízhatósági funkciókat.

---

## 🚀 Főbb Jellemzők és Előnyök

* **Biztonságos Jelszókezelés:** Kerberos alapú hitelesítés a `samba-tool` parancsokhoz, elkerülve a jelszavak futásidejű láthatóságát.
* **Production Ready Ellenőrzések:**
    * **Időszinkronizáció (NTP/Chrony)** ellenőrzése (kritikus az AD-működéshez).
    * **Hálózati validáció:** Statikus IP és DNS Forwarder elérhetőségének ellenőrzése.
* **Tűzfal Automata Konfiguráció:** Automatikus **UFW** konfiguráció az összes szükséges AD, LDAP, Kerberos, SMB és dinamikus RPC portra.
* **Hibakezelés és Visszaállítás:** Részleges provisioning esetén **backup/rollback mechanizmus** áll rendelkezésre a rendszer integritásának megőrzésére.

---

## 📋 Használati Útmutató

### 1. Előkészítés és Futtathatóvá Tétel

```bash
# Helyezze a szkript tartalmát az ubuntu-installer-6.4-samba-ad-dc.sh fájlba.

# Tegye futtathatóvá a fájlt
chmod +x ubuntu-installer-6.4-samba-ad-dc.sh
