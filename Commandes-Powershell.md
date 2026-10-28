# Listing complet des commandes PowerShell – Projet Agrisky

Ce document regroupe l'ensemble des commandes PowerShell de configuration des machines de l'infrastructure Agrisky. Les scripts sont disponibles à part, dans le dossier `scripts`.

---

## 1. Contrôleurs de domaine : AD DS, DNS, DHCP

**Plan d'adressage v3**

| Site | VLAN | Réseau | Passerelle |
|---|---|---|---|
| Siège | V15-AD | `172.16.15.0/29` | `172.16.15.1` |
| Saran | V15-AD | `172.16.115.0/29` | `172.16.115.1` |

À exécuter étape par étape : un redémarrage sépare certaines étapes. Vérifier d'abord le nom de la carte réseau avec `Get-NetAdapter`, puis l'adapter dans la variable ci-dessous.

```powershell
$If = "Ethernet"   # à adapter selon Get-NetAdapter
```

### Prérequis (hors PowerShell)

- **Proxmox** : carte réseau de la VM 3002 sur `vmbr3001`, `tag=15`.
- **OPNsense** : interface AD en `172.16.15.1/29`, et une règle `AD net` → `172.16.15.1` port 53.
- **Mot de passe de l'Administrateur local robuste** : il devient celui de l'Administrateur du domaine à la création de la forêt.

### Étape 1 – Préparation de ORL-DC01

```powershell
Rename-Computer -NewName "ORL-DC01"
New-NetIPAddress -InterfaceAlias $If -IPAddress 172.16.15.2 -PrefixLength 29 -DefaultGateway 172.16.15.1
Set-DnsClientServerAddress -InterfaceAlias $If -ServerAddresses 127.0.0.1
Restart-Computer
```

### Étape 2 – Rôle AD DS et création de la forêt

Le rôle DNS est installé en même temps, par le paramètre `-InstallDns`.

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest `
    -DomainName "agrisky.lan" `
    -DomainNetbiosName "AGRISKY" `
    -ForestMode WinThreshold -DomainMode WinThreshold `
    -InstallDns `
    -SafeModeAdministratorPassword (Read-Host "Mot de passe DSRM" -AsSecureString) `
    -Force
```

Le serveur redémarre automatiquement. Se reconnecter ensuite avec `AGRISKY\Administrateur`.

**Vérifications**

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode
Get-Service adws, kdc, netlogon, dns | Select-Object Name, Status
dcdiag /q
```

### Étape 3 – DNS : redirecteur et zone inverse (sur ORL-DC01)

Les DC n'ont pas d'accès Internet : ils transmettent les requêtes externes au résolveur de l'OPNsense (Unbound), qui sort pour eux. Une seule zone inverse couvre tout le réseau interne ; elle est répliquée dans la forêt.

```powershell
Set-DnsServerForwarder -IPAddress 172.16.15.1
Add-DnsServerPrimaryZone -NetworkId "172.16.0.0/16" -ReplicationScope Forest
```
