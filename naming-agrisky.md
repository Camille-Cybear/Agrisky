# Conventions de nommage – Agrisky

Projet WARMUP – ACPC Solutions. Référentiel unique pour l'annuaire, les machines, le réseau et les comptes.

Règles générales, valables partout :
- **Pas d'accents, pas d'espaces, pas de caractères spéciaux** dans les noms techniques (seuls `-` et `_` sont autorisés).
- **Un séparateur par usage** : `-` dans les noms de machines et DNS, `_` dans les objets d'annuaire (groupes, comptes de service) et les alias du pare-feu.
- **Aucune donnée personnelle ni fonction sensible** dans un nom visible sur le réseau (nom de machine, SSID, partage).
- **Un nom ne se réutilise jamais** : un matricule ou un numéro de machine libéré reste retiré.

---

## 1. Domaine

| Élément | Valeur |
|---|---|
| Domaine AD (FQDN) | `agrisky.lan` |
| Nom NetBIOS | `AGRISKY` |
| Suffixe UPN | `agrisky.lan` |
| Domaine de messagerie | `agrisky.fr` |

Choix d'un domaine interne `.lan` : l'infrastructure est une maquette isolée, sans publication de services internes ni certificats publics. En production, on retiendrait un sous-domaine du domaine public (ex. `ad.agrisky.fr`), recommandation de Microsoft.

> L'OPNsense du siège (`FW.agrisky.lan`) est à renommer `orl-fw01` pour suivre la convention des machines (section 6).

---

## 2. Sites et populations

### Sites

| Code | Site |
|---|---|
| `ORL` | Siège d'Orléans (2 étages, salle serveur) |
| `SAR` | Site de production de Saran |
| `NOM` | Nomades (rattachement administratif : siège) |

### Populations d'utilisateurs

Les codes suivent les VLAN qui accueillent des utilisateurs : un salarié est rattaché à la population de son VLAN, quel que soit son service.

| Code | Population | VLAN |
|---|---|---|
| `INF` | Service Informatique (comptes standard) | `V10-ADMINS` |
| `USR` | Salariés des services (dont bureau d'études, atelier, entrepôt) | `V40-USERS` |
| `DIR` | Direction et données sensibles (RH, paie, finance) | `V50-DIRECTION` |
| `CPT` | Comptabilité (seul le poste de paiement est en `V60-COMPTA`, les autres en `V50-DIRECTION`) | `V60-COMPTA` |

Le service exact de chaque salarié reste renseigné dans l'attribut *Service* (department) du compte.

---

## 3. Unités d'organisation (OU)

Principe : **les OU servent à appliquer des GPO et à déléguer l'administration**, pas à reproduire l'organigramme. Trois niveaux maximum sous la racine. Les comptes et machines d'administration sont isolés dans leur propre branche (modèle d'administration en niveaux recommandé par l'ANSSI).

```text
agrisky.lan
├── Domain Controllers              ← OU par défaut, ne pas déplacer les DC
└── AGRISKY
    ├── _ADMIN                      ← accès restreint au service Informatique
    │   ├── Comptes-T0              ← administrateurs du domaine
    │   ├── Comptes-T1              ← administrateurs des serveurs
    │   ├── Comptes-T2              ← administrateurs des postes (support)
    │   ├── Groupes-Admin
    │   └── Bastion                 ← serveur(s) d'administration
    ├── Utilisateurs
    │   ├── INF, USR, DIR, CPT
    ├── Postes
    │   ├── ORL
    │   │   ├── Standard
    │   │   ├── Conception          ← bureau d'études : GPO durcies
    │   │   └── Paiement            ← poste comptable dédié
    │   ├── SAR
    │   │   └── Partages            ← postes partagés atelier/entrepôt
    │   └── Portables               ← nomades
    ├── Serveurs
    │   ├── Infrastructure          ← fichiers, GLPI, supervision, journaux, IPBX
    │   └── DMZ                     ← si le serveur web est joint au domaine (déconseillé)
    ├── Groupes
    │   ├── Roles                   ← groupes globaux (GG)
    │   └── Ressources              ← groupes domaine local (DL)
    ├── Comptes-Service
    └── Desactives                  ← comptes et postes en attente de suppression
```

**Pourquoi les utilisateurs par population et les postes par usage** : les GPO utilisateur suivent la population (lecteurs réseau, restrictions), les GPO ordinateur suivent l'usage du poste (durcissement du bureau d'études, poste de paiement, postes partagés de Saran), indépendamment de qui s'y connecte.

---

## 4. Comptes utilisateurs

### Matricule (identifiant de connexion)

Format : **`<II><NNNN><C>`**

| Partie | Contenu | Exemple |
|---|---|---|
| `II` | Initiales prénom + nom, en majuscules | `JD` |
| `NNNN` | Numéro séquentiel unique, jamais réutilisé | `0042` |
| `C` | Catégorie de contrat | `I` |

| Catégorie | Signification |
|---|---|
| `I` | Interne (CDI, CDD) |
| `A` | Alternant / stagiaire (date de fin connue) |
| `P` | Prestataire externe (date de fin obligatoire) |

Exemple : John DOE, interne → **`JD0042I`**

Le numéro garantit l'unicité : deux personnes aux mêmes initiales ont des numéros différents. Le matricule ne change jamais, même en cas de changement de nom ou de service.

### Attributs

| Attribut | Format | Exemple |
|---|---|---|
| sAMAccountName | matricule | `JD0042I` |
| userPrincipalName | `prenom.nom@agrisky.lan` | `john.doe@agrisky.lan` |
| Nom affiché | `Prénom NOM` | `John DOE` |
| Mail | `prenom.nom@agrisky.fr` | `john.doe@agrisky.fr` |
| Service (department) | nom du service | `Informatique` |
| Description | `<POPULATION> – <fonction>` | `INF – Administratrice systèmes` |
| Date d'expiration | obligatoire pour `A` et `P` | date de fin de contrat |

Homonymie : ajout d'un chiffre après le nom, dans l'UPN comme dans le mail (`john.doe2`). La connexion se fait avec le matricule ; l'UPN suit le même format que le mail pour rester lisible.

### Comptes d'administration (doubles comptes)

Format : **`<matricule>-A<niveau>`**

| Compte | Niveau | Périmètre | Exemple |
|---|---|---|---|
| `-A0` | Tier 0 | Contrôleurs de domaine, annuaire | `JD0042I-A0` |
| `-A1` | Tier 1 | Serveurs, applications, pare-feux | `JD0042I-A1` |
| `-A2` | Tier 2 | Postes de travail, support | `JD0042I-A2` |

Règles :
- **Création sur demande** : ticket GLPI validé par le responsable informatique, qui précise le niveau et la durée.
- **Durée de validité obligatoire** (6 mois, renouvelable sur nouvelle demande) via la date d'expiration du compte.
- **Un compte d'un niveau ne se connecte jamais à une machine d'un niveau inférieur** (un `-A0` ne se connecte pas sur un poste).
- **Connexion uniquement depuis le bastion** pour les `-A0` et `-A1`.
- **Pas de messagerie, pas d'Internet** pour les comptes d'administration ; membres du groupe *Protected Users*.
- Le compte `Administrateur` intégré est renommé, désactivé en usage courant, et son mot de passe conservé sous enveloppe / coffre.

### Comptes de service

| Type | Format | Exemple |
|---|---|---|
| Compte de service géré (gMSA), à privilégier pour les services Windows | `gmsa_<appli>$` | `gmsa_bkp$` |
| Compte de service classique, pour les applications non Windows | `svc_<appli>_<usage>` | `svc_glpi_ldap` |

- **gMSA** : uniquement pour les services Windows qui le supportent (services, tâches planifiées, pools IIS, SQL Server). Nom limité à 15 caractères, soit 10 après le préfixe `gmsa_`. Mot de passe géré et renouvelé par l'AD, accès réservé aux serveurs autorisés.
- **Compte classique** : pour les applications qui ont besoin d'un identifiant et d'un mot de passe saisis dans leur configuration (GLPI, supervision sous Linux…). Mot de passe aléatoire de 25 caractères minimum stocké dans le gestionnaire de mots de passe, droits minimaux, rotation planifiée.
- Dans les deux cas : jamais de connexion interactive, description renseignée avec l'application et le responsable.

### Comptes génériques

À éviter. Pour les postes partagés de Saran, chaque opérateur a son propre compte (traçabilité). Si un compte générique est imposé : `gen_<site>_<usage><NN>` (ex. `gen_sar_atelier01`), restreint aux postes de l'OU `Partages` et sans accès aux partages sensibles.

---

## 5. Groupes de sécurité (AGDLP)

**A**ccount → **G**lobal → **D**omain **L**ocal → **P**ermission : les comptes vont dans des groupes globaux (qui est-on), les groupes globaux dans des groupes domaine local (à quoi on accède), et seuls les domaine local reçoivent des droits.

| Type | Format | Exemples |
|---|---|---|
| Global – population | `GG_<POPULATION>_Tous` | `GG_USR_Tous`, `GG_DIR_Tous` |
| Global – rôle métier | `GG_<POPULATION>_<Role>` | `GG_USR_Conception`, `GG_USR_SAV`, `GG_CPT_Paiement`, `GG_DIR_RH` |
| Global – tous les salariés d'un site | `GG_<SITE>_Tous` | `GG_SAR_Tous` |
| Global – ordinateurs (filtrage GPO) | `GG_PC_<Usage>` | `GG_PC_Conception`, `GG_PC_Partages` |
| Global – administration | `GG_ADM_T<n>_<Perimetre>` | `GG_ADM_T1_Serveurs`, `GG_ADM_T2_Postes` |
| Domaine local – ressource | `DL_<TYPE>_<Ressource>_<Droit>` | `DL_FIC_Plans_RW`, `DL_FIC_Plans_RO`, `DL_IMP_ORL-E1_Print` |

| Type de ressource | Code |
|---|---|
| Partage de fichiers | `FIC` |
| Imprimante | `IMP` |
| Application | `APP` |
| Accès VPN | `VPN` |

| Droit | Code |
|---|---|
| Lecture seule | `RO` |
| Lecture / écriture | `RW` |
| Contrôle total | `FC` |

Exemple bureau d'études : comptes du BE → `GG_USR_Conception` → `DL_FIC_Plans_RW` → droit NTFS Modification sur le partage des plans.

---

## 6. Machines

Contrainte : **15 caractères maximum** (limite NetBIOS). Le nom indique le site, le type et le rôle ; jamais le nom de l'utilisateur.

### Serveurs et équipements

Format : **`<SITE>-<ROLE><NN>`**

- **Serveur mono-rôle** : code du rôle (`ORL-DC01`, `ORL-WEB01`, `ORL-BAS01`).
- **Serveur multi-rôle** : code générique `SRV` (`ORL-SRV01`, `ORL-SRV02`). Ajouter ou retirer un rôle n'oblige pas à renommer la machine ; la liste des rôles est tenue dans GLPI et dans l'onglet « Naming machines » du registre.
- Les rôles critiques ou exposés restent **toujours seuls** sur leur serveur : contrôleur de domaine, bastion, serveur en DMZ, supervision.

| Code rôle | Rôle | Exemple |
|---|---|---|
| `DC` | Contrôleur de domaine (AD, DNS) | `ORL-DC01`, `ORL-DC02`, `SAR-DC01` |
| `FIC` | Serveur de fichiers | `ORL-FIC01` |
| `GLPI` | Inventaire et tickets | `ORL-GLPI01` |
| `SUP` | Supervision | `ORL-SUP01` |
| `LOG` | Centralisation des journaux | `ORL-LOG01` |
| `MAJ` | Mises à jour (WSUS ou équivalent) | `ORL-MAJ01` |
| `IPBX` | Téléphonie | `ORL-IPBX01` |
| `PRX` | Proxy filtrant | `ORL-PRX01` |
| `WDS` | Déploiement des postes | `ORL-WDS01` |
| `RDS` | Bureau à distance | `ORL-RDS01` |
| `MAIL` | Messagerie | `ORL-MAIL01` |
| `BKP` | Sauvegarde | `ORL-BKP01`, `SAR-BKP01` |
| `BAS` | Bastion | `ORL-BAS01` |
| `WEB` | Site vitrine (DMZ) | `ORL-WEB01` |
| `SRV` | Serveur multi-rôle | `ORL-SRV01`, `ORL-SRV02` |
| `HV` | Hyperviseur | `ORL-HV01`, `SAR-HV01` |
| `FW` | Pare-feu | `ORL-FW01`, `SAR-FW01` |
| `SWC` | Commutateur de cœur | `ORL-SWC01` |
| `SWA` | Commutateur d'accès | `ORL-SWA01`, `SAR-SWA01` |
| `AP` | Borne Wi-Fi | `ORL-AP01` |
| `IMP` | Imprimante / copieur | `ORL-IMP01` |

### Postes de travail

Format : **`<SITE>-<TYPE><NNNN>`**, le numéro étant celui de l'inventaire GLPI.

| Type | Signification | Exemple |
|---|---|---|
| `PF` | Poste fixe | `ORL-PF0012` |
| `PP` | Portable (nomade) | `NOM-PP0007` |
| `PA` | Poste d'administration | `ORL-PA0001` |

Le poste de paiement et les postes du bureau d'études suivent la numérotation standard : leur rôle est porté par leur OU et leur groupe, pas par leur nom (ne pas désigner une cible sur le réseau).



### DNS

Enregistrements en minuscules dans la zone `agrisky.lan` : `orl-dc01.agrisky.lan`, `orl-fw01.agrisky.lan`.

---

## 7. Réseau

### VLAN

Format : **`V<ID>-<NOM>`** (nom des VLAN sur les commutateurs). Mêmes identifiants sur les deux sites.

| VLAN | Nom | Siège | Saran |
|---|---|---|---|
| 10 | `V10-ADMINS` | ✓ | ✓ |
| 20 | `V20-SERVEURS` | ✓ | ✓ |
| 30 | `V30-SAUVEGARDE` | ✓ | ✓ |
| 40 | `V40-USERS` | ✓ | ✓ |
| 50 | `V50-DIRECTION` | ✓ | – |
| 60 | `V60-COMPTA` | ✓ | – |
| 70 | `V70-TOIP` | ✓ | ✓ |
| 80 | `V80-OT` | – | ✓ |
| 90 | `V90-INVITES` | ✓ | ✓ |
| 100 | `V100-DMZ` | ✓ | – |
| 999 | `V999-PARKING` | ✓ | ✓ |

### Interfaces OPNsense

Description en majuscules, identique au nom du VLAN sans préfixe : `ADMINS`, `SERVEURS`, `SAUVEGARDE`, `USERS`, `DIRECTION`, `COMPTA`, `TOIP`, `OT`, `INVITES`, `DMZ`. Interfaces VPN : `VPN_NOMADES`, `VPN_SARAN` (au siège) / `VPN_SIEGE` (à Saran).

### Alias du pare-feu

| Type | Format | Exemples |
|---|---|---|
| Réseau | `NET_<NOM>` | `NET_INTERNES` (172.16.0.0/16), `NET_ORL_USERS`, `NET_SAR_OT` |
| Hôte | `HOST_<NOM-MACHINE>` | `HOST_ORL-BAS01`, `HOST_ORL-DC01` |
| Groupe d'hôtes | `GRP_<USAGE>` | `GRP_DC` (tous les contrôleurs de domaine) |
| Ports | `PORT_<SERVICE>` | `PORT_AD`, `PORT_WEB`, `PORT_ADMIN` |


### Règles de pare-feu

Description : **`<SOURCE> -> <DESTINATION> : <service> (<référence>)`**

Exemple : `USERS -> SERVEURS : AD, fichiers, impression (CdCT flux n°3)`

La référence renvoie à la matrice des flux du DAT : chaque règle ouverte est justifiée.

### Wi-Fi

| SSID | Usage | VLAN |
|---|---|---|
| `AGRISKY` | Salariés, authentification 802.1X par compte AD | 40 |
| `AGRISKY-INVITES` | Visiteurs, Internet uniquement | 90 |

---

## 8. Partages de fichiers

Accès par l'espace de noms DFS, jamais par le nom du serveur : le serveur peut changer sans toucher aux postes.

| Élément | Format | Exemple |
|---|---|---|
| Racine | `\\agrisky.lan\partages` | – |
| Partage par population | `\\agrisky.lan\partages\<POPULATION>` | `\\agrisky.lan\partages\DIR` |
| Partage métier (accès par groupe DL) | `\\agrisky.lan\partages\<Ressource>` | `\\agrisky.lan\partages\Plans` |
| Partage transverse | `\\agrisky.lan\partages\Commun` | – |
| Dossier personnel | `\\agrisky.lan\perso\<matricule>` | `\\agrisky.lan\perso\CB0042I` |

---

## 9. GPO

Format : **`<CIBLE>_<PORTEE>_<Fonction>`**

| Partie | Valeurs |
|---|---|
| Cible | `C` (ordinateur), `U` (utilisateur) |
| Portée | `ALL`, code de site (`ORL`, `SAR`), code de population (`USR`, `DIR`…) ou usage de poste (`CONCEPTION`, `PAIEMENT`, `PARTAGES`) |
| Fonction | en mots attachés, majuscule à chaque mot |

| Exemple | Rôle |
|---|---|
| `C_ALL_SecuriteBitLocker` | Chiffrement des disques de tous les postes |
| `C_CONCEPTION_BlocageUSB` | Blocage du stockage USB au bureau d'études |
| `C_PAIEMENT_RestrictionNavigation` | Poste de paiement limité au site bancaire |
| `U_ALL_LecteursReseau` | Montage des partages selon la population et les groupes |
| `U_SAR_HorairesConnexion` | Plages horaires des postes partagés de Saran |

La **stratégie de mot de passe** reste dans la *Default Domain Policy* : pour les comptes du domaine, elle ne s'applique que si elle est liée à la racine du domaine ; les exigences plus fortes pour les administrateurs passent par une stratégie de mot de passe affinée (PSO) nommée `PSO_Admins`.

**Versionnage** : pas de date dans le nom (il faudrait renommer la GPO à chaque modification). La version et la date de dernière modification vont dans le commentaire de la GPO, et chaque modification fait l'objet d'un ticket GLPI.
