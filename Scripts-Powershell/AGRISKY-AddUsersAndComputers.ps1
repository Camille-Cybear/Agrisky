#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Création des comptes utilisateurs et des postes Agrisky dans l'AD à partir des exports
    du registre des matricules (Google Sheet).

.DESCRIPTION
    Entrées (exports CSV du registre, Fichier > Télécharger > CSV) :
      - Export-AD-Utilisateurs.csv : Matricule, Prenom, Nom, Categorie, Population, Service, Site,
                                     Societe, Expiration, OU, Description, Groupes
      - Export-AD-Postes.csv       : Nom, OU, Site, Description, Matricule, ConnexionExclusive, Groupes

    Prérequis : OU et groupes créés par le script de structure AD (onglet « Structure AD »).

    Conventions appliquées (naming-agrisky.md) :
      - sAMAccountName = matricule (ex. JD0042I), stocké aussi dans EmployeeID
      - UPN = prenom.nom@agrisky.lan, mail = prenom.nom@agrisky.fr (homonymes : prenom.nom2)
      - Nom affiché = "Prénom NOM" (accents conservés à l'affichage, retirés dans les identifiants)
      - Expiration obligatoire pour les externes (E) ; pour les internes (I), seulement si le registre en donne une
      - Groupes : GG_<POP>_Tous, GG_<SITE>_Tous (+ GG_NOM_Tous, groupes métier) calculés dans le Sheet

    Le script est idempotent : un matricule déjà présent dans l'AD est ignoré, un poste existant aussi.

.EXAMPLE
    .\AGRISKY-AddUsersAndComputers.ps1 -WhatIf -Verbose     # simulation, rien n'est créé
    .\AGRISKY-AddUsersAndComputers.ps1 -Verbose              # exécution réelle
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FichierUsers   = (Join-Path $PSScriptRoot 'Export-AD-Utilisateurs.csv'),
    [string]$FichierPostes  = (Join-Path $PSScriptRoot 'Export-AD-Postes.csv'),
    [ValidateRange(12, 64)]
    [int]$LongueurMdp       = 14,
    [string]$DomaineMail    = 'agrisky.fr',
    # Dossier d'export des mots de passe : HORS du dépôt Git, accès restreint
    [string]$DossierMdp     = 'C:\Ressources\Secrets',
    # Active la protection contre la suppression accidentelle sur les objets créés
    [switch]$Proteger
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

#region --- Journalisation ---------------------------------------------------------------------
$LogFolder = Join-Path $PSScriptRoot 'Les Logs Scripts'
$LogFile   = Join-Path $LogFolder "LogsduScript-Agrisky-AddUsersAndComputers_$(Get-Date -Format 'yyyy-MM-dd').log"
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force -WhatIf:$false | Out-Null }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','SUCCESS','ERROR','WARN')][string]$Level = 'INFO'
    )
    $Prefixe = if ($WhatIfPreference) { '[SIMULATION] ' } else { '' }
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Prefixe$Message" -Encoding UTF8 -WhatIf:$false
    switch ($Level) {
        'ERROR' { Write-Warning $Message }
        'WARN'  { Write-Warning $Message }
        default { Write-Verbose $Message }
    }
}
#endregion

#region --- Fonctions utilitaires ----------------------------------------------------------------

# Identifiant technique : sans accents, sans espaces ni apostrophes, en minuscules, seuls a-z 0-9 - autorisés
function Format-Identifiant {
    param([string]$Texte)
    $Texte = $Texte.Trim() -replace '[\u2013\u2014]', '-' -replace 'œ', 'oe' -replace 'Œ', 'OE' -replace 'æ', 'ae' -replace 'Æ', 'AE' -replace 'ß', 'ss'
    $d = $Texte.Normalize([Text.NormalizationForm]::FormD)
    $SansAccent = -join ($d.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    ($SansAccent.ToLower() -replace "[\s']", '' -replace '[^a-z0-9-]', '')
}

# "AGRISKY/Utilisateurs/INF" -> "OU=INF,OU=Utilisateurs,OU=AGRISKY,DC=agrisky,DC=lan"
function ConvertTo-OuDN {
    param([string]$Chemin)
    $Parties = $Chemin.Trim('/').Split('/')
    [array]::Reverse($Parties)
    (($Parties | ForEach-Object { "OU=$_" }) -join ',') + ",$DomainDN"
}

$OuVerifiees = @{}
function Test-OU {
    param([string]$DN)
    if (-not $OuVerifiees.ContainsKey($DN)) {
        $OuVerifiees[$DN] = [bool](Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$DN'" -ErrorAction SilentlyContinue)
    }
    $OuVerifiees[$DN]
}

$GroupesVerifies = @{}
function Test-Groupe {
    param([string]$Nom)
    if (-not $GroupesVerifies.ContainsKey($Nom)) {
        $GroupesVerifies[$Nom] = [bool](Get-ADGroup -Filter "SamAccountName -eq '$Nom'" -ErrorAction SilentlyContinue)
    }
    $GroupesVerifies[$Nom]
}

# Mot de passe aléatoire : 1 majuscule, 1 minuscule, 1 chiffre, 1 spécial minimum, sans caractères ambigus
$Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function Get-Aleatoire {
    param([uint32]$Max)
    $Octets = [byte[]]::new(4)
    $Rng.GetBytes($Octets)
    [BitConverter]::ToUInt32($Octets, 0) % $Max
}
function New-MotDePasse {
    param([int]$Longueur = 14)
    $Maj = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $Min = 'abcdefghijkmnpqrstuvwxyz'
    $Chi = '23456789';                 $Spe = '!@#$%*-_+=?'
    $Tous = $Maj + $Min + $Chi + $Spe
    $Car  = @($Maj[(Get-Aleatoire $Maj.Length)], $Min[(Get-Aleatoire $Min.Length)],
              $Chi[(Get-Aleatoire $Chi.Length)], $Spe[(Get-Aleatoire $Spe.Length)])
    $Car += 1..($Longueur - 4) | ForEach-Object { $Tous[(Get-Aleatoire $Tous.Length)] }
    -join ($Car | Sort-Object { Get-Aleatoire ([uint32]::MaxValue) })
}
#endregion

#region --- Chargement des données ---------------------------------------------------------------
foreach ($f in $FichierUsers, $FichierPostes) {
    if (-not (Test-Path $f)) { throw "Fichier introuvable : $f" }
}
# Les CSV exportés de Google Sheets sont en UTF-8 sans BOM : sans -Encoding, PowerShell 5.1 casse les accents
$Users  = @(Import-Csv -Path $FichierUsers  -Delimiter ',' -Encoding UTF8)
$Postes = @(Import-Csv -Path $FichierPostes -Delimiter ',' -Encoding UTF8)

$Domaine   = Get-ADDomain
$DomainDN  = $Domaine.DistinguishedName
$SuffixUpn = $Domaine.DNSRoot          # agrisky.lan

# Index de l'existant : on ne charge que les attributs utiles
$SamUtilises  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$UpnUtilises  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$MailUtilises = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$EmpUtilises  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
Get-ADUser -Filter * -Properties EmployeeID, mail | ForEach-Object {
    if ($_.SamAccountName)    { [void]$SamUtilises.Add($_.SamAccountName) }
    if ($_.UserPrincipalName) { [void]$UpnUtilises.Add($_.UserPrincipalName) }
    if ($_.mail)              { [void]$MailUtilises.Add($_.mail) }
    # Les comptes d'administration (MATRICULE-A0/A1/A2) peuvent porter le même EmployeeID que le compte
    # standard : on ne les compte pas, sinon le compte standard serait ignoré à tort
    if ($_.EmployeeID -and $_.SamAccountName -notmatch '-A[0-2]$') { [void]$EmpUtilises.Add($_.EmployeeID) }
}
$PostesExistants = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
Get-ADComputer -Filter * | ForEach-Object { [void]$PostesExistants.Add($_.Name) }

$TableauMotsDePasse = [System.Collections.Generic.List[PSObject]]::new()
$Stats = @{ UsersCrees = 0; UsersIgnores = 0; UsersErreurs = 0; PostesCrees = 0; PostesIgnores = 0; PostesErreurs = 0 }
#endregion

#region --- Utilisateurs -------------------------------------------------------------------------
Write-Log "Début du traitement : $($Users.Count) utilisateurs, $($Postes.Count) postes" -Level INFO
$i = 0
foreach ($U in $Users) {
    $i++
    Write-Progress -Activity 'Création des utilisateurs' -Status "$i / $($Users.Count)" -PercentComplete ($i / $Users.Count * 100)

    $Matricule = "$($U.Matricule)".Trim().ToUpper()
    $Prenom    = "$($U.Prenom)".Trim()
    $Nom       = "$($U.Nom)".Trim().ToUpper()

    # --- Contrôles de cohérence de la ligne
    if ($Matricule -notmatch '^[A-Z]{2}\d{4}[IE]$') {
        Write-Log "Ligne $i ignorée : matricule invalide « $Matricule »" -Level ERROR; $Stats.UsersErreurs++; continue
    }
    if (-not $Prenom -or -not $Nom) {
        Write-Log "$Matricule ignoré : prénom ou nom vide" -Level ERROR; $Stats.UsersErreurs++; continue
    }
    if ($EmpUtilises.Contains($Matricule) -or $SamUtilises.Contains($Matricule)) {
        Write-Log "$Matricule ($Prenom $Nom) existe déjà, ignoré" -Level WARN; $Stats.UsersIgnores++; continue
    }

    $Expiration = $null
    if ($U.Expiration) {
        $Expiration = [datetime]::ParseExact($U.Expiration.Trim(), 'yyyy-MM-dd', $null).AddDays(1)  # +1 j : le compte reste valide toute la dernière journée
    }
    elseif ($U.Categorie -eq 'E') {
        Write-Log "$Matricule ignoré : date d'expiration obligatoire pour un externe (E)" -Level ERROR; $Stats.UsersErreurs++; continue
    }

    $Path = ConvertTo-OuDN $U.OU
    if (-not (Test-OU $Path)) {
        Write-Log "$Matricule ignoré : OU absente ($Path). Lancer d'abord le script de structure AD." -Level ERROR; $Stats.UsersErreurs++; continue
    }

    # --- UPN et mail, avec gestion des homonymes (john.doe, john.doe2, john.doe3...)
    $Base = "$(Format-Identifiant $Prenom).$(Format-Identifiant $Nom)"
    $n = 1
    do {
        $Suffixe = if ($n -gt 1) { "$n" } else { '' }
        $Upn  = "$Base$Suffixe@$SuffixUpn"
        $Mail = "$Base$Suffixe@$DomaineMail"
        $n++
    } while ($UpnUtilises.Contains($Upn) -or $MailUtilises.Contains($Mail))

    $DisplayName = "$Prenom $Nom"
    $CN          = if ($Suffixe) { "$DisplayName $Suffixe" } else { $DisplayName }   # évite un conflit de CN dans la même OU
    $MotDePasse  = New-MotDePasse -Longueur $LongueurMdp

    $Params = @{
        Name                  = $CN
        SamAccountName        = $Matricule
        UserPrincipalName     = $Upn
        EmailAddress          = $Mail
        GivenName             = $Prenom
        Surname               = $Nom
        DisplayName           = $DisplayName
        EmployeeID            = $Matricule
        Description           = $U.Description
        Department            = $U.Service
        Company               = $U.Societe
        Office                = $U.Site
        Path                  = $Path
        AccountPassword       = (ConvertTo-SecureString -AsPlainText $MotDePasse -Force)
        ChangePasswordAtLogon = $true
        Enabled               = $true
    }
    if ($Expiration) { $Params.AccountExpirationDate = $Expiration }

    if ($PSCmdlet.ShouldProcess("$Matricule ($DisplayName) dans $Path", 'Créer l''utilisateur')) {
        try {
            $Nouveau = New-ADUser @Params -PassThru
            if ($Proteger) { Set-ADObject $Nouveau -ProtectedFromAccidentalDeletion $true }

            [void]$SamUtilises.Add($Matricule); [void]$EmpUtilises.Add($Matricule)
            [void]$UpnUtilises.Add($Upn);       [void]$MailUtilises.Add($Mail)
            $TableauMotsDePasse.Add([PSCustomObject]@{
                Matricule = $Matricule; Prenom = $Prenom; Nom = $Nom; UPN = $Upn; MotDePasse = $MotDePasse })
            Write-Log "Utilisateur $Matricule créé ($Upn)" -Level SUCCESS
            $Stats.UsersCrees++

            # Groupes calculés dans le Sheet (séparés par des virgules)
            foreach ($G in ("$($U.Groupes)".Split(',') | ForEach-Object Trim | Where-Object { $_ })) {
                if (Test-Groupe $G) {
                    Add-ADGroupMember -Identity $G -Members $Nouveau
                    Write-Log "  $Matricule ajouté à $G" -Level INFO
                }
                else { Write-Log "  Groupe $G introuvable : $Matricule non ajouté" -Level WARN }
            }
        }
        catch {
            Write-Log "ECHEC création utilisateur $Matricule : $($_.Exception.Message)" -Level ERROR
            $Stats.UsersErreurs++
        }
    }
}
Write-Progress -Activity 'Création des utilisateurs' -Completed
#endregion

#region --- Export des mots de passe initiaux ----------------------------------------------------
if ($TableauMotsDePasse.Count -gt 0) {
    if (-not (Test-Path $DossierMdp)) {
        New-Item -Path $DossierMdp -ItemType Directory -Force | Out-Null
        # Héritage coupé : accès réservé aux administrateurs et au compte qui lance le script
        icacls $DossierMdp /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "$($env:USERDOMAIN)\$($env:USERNAME):(OI)(CI)F" | Out-Null
    }
    $FichierMdp = Join-Path $DossierMdp "MotsDePasse-Agrisky_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').csv"
    $TableauMotsDePasse | Export-Csv -Path $FichierMdp -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Write-Log "Mots de passe initiaux exportés : $FichierMdp ($($TableauMotsDePasse.Count) comptes). A supprimer après remise aux utilisateurs." -Level INFO
}
#endregion

#region --- Postes -------------------------------------------------------------------------------
$i = 0
foreach ($P in $Postes) {
    $i++
    Write-Progress -Activity 'Création des postes' -Status "$i / $($Postes.Count)" -PercentComplete ($i / $Postes.Count * 100)

    $Nom = "$($P.Nom)".Trim().ToUpper()
    if ($Nom -notmatch '^(ORL|SAR|NOM)-P[FPA]\d{4}$' -or $Nom.Length -gt 15) {
        Write-Log "Ligne $i ignorée : nom de poste invalide « $Nom »" -Level ERROR; $Stats.PostesErreurs++; continue
    }
    if ($PostesExistants.Contains($Nom)) {
        Write-Log "Poste $Nom existe déjà, ignoré" -Level WARN; $Stats.PostesIgnores++; continue
    }
    $Path = ConvertTo-OuDN $P.OU
    if (-not (Test-OU $Path)) {
        Write-Log "Poste $Nom ignoré : OU absente ($Path)" -Level ERROR; $Stats.PostesErreurs++; continue
    }

    $Params = @{ Name = $Nom; Path = $Path; Description = $P.Description; Enabled = $true }

    # Utilisateur attribué : champ « Géré par » (ManagedBy), utile pour l'inventaire GLPI
    $Proprio = $null
    $Matricule = "$($P.Matricule)".Trim()
    if ($Matricule) {
        $Proprio = Get-ADUser -Filter "SamAccountName -eq '$Matricule'" -ErrorAction SilentlyContinue
        if ($Proprio) { $Params.ManagedBy = $Proprio }
        elseif (-not $WhatIfPreference) { Write-Log "Poste $Nom : utilisateur $Matricule introuvable, ManagedBy non renseigné" -Level WARN }
    }

    if ($PSCmdlet.ShouldProcess("$Nom dans $Path", 'Créer le poste')) {
        try {
            $NouveauPoste = New-ADComputer @Params -PassThru
            if ($Proteger) { Set-ADObject $NouveauPoste -ProtectedFromAccidentalDeletion $true }
            [void]$PostesExistants.Add($Nom)
            Write-Log "Poste $Nom créé" -Level SUCCESS
            $Stats.PostesCrees++

            # Groupes ordinateurs (GG_PC_<Usage>) calculés dans le Sheet, créés par le script de structure AD
            foreach ($G in ("$($P.Groupes)".Split(',') | ForEach-Object Trim | Where-Object { $_ })) {
                if (Test-Groupe $G) {
                    Add-ADGroupMember -Identity $G -Members $NouveauPoste
                    Write-Log "  $Nom ajouté à $G" -Level INFO
                }
                else { Write-Log "  Groupe $G introuvable : $Nom non ajouté" -Level WARN }
            }

            # Poste de paiement : l'utilisateur ne peut ouvrir de session que sur ce poste (Log On To)
            if ($P.ConnexionExclusive -eq 'Oui' -and $Proprio) {
                Set-ADUser $Proprio -LogonWorkstations $Nom
                Write-Log "  $Matricule limité à la connexion sur $Nom" -Level INFO
            }
        }
        catch {
            Write-Log "ECHEC création poste $Nom : $($_.Exception.Message)" -Level ERROR
            $Stats.PostesErreurs++
        }
    }
}
Write-Progress -Activity 'Création des postes' -Completed
$Rng.Dispose()
#endregion

$Bilan = "Bilan - utilisateurs : $($Stats.UsersCrees) créés, $($Stats.UsersIgnores) déjà présents, $($Stats.UsersErreurs) erreurs | " +
         "postes : $($Stats.PostesCrees) créés, $($Stats.PostesIgnores) déjà présents, $($Stats.PostesErreurs) erreurs"
Write-Log $Bilan -Level INFO
Write-Host $Bilan
