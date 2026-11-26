#Requires -Modules ActiveDirectory
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Création des dossiers partagés Agrisky sur le serveur de fichiers (ORL-SRV01) :
    partages par population, partages transverse et métier, dossiers personnels.

.DESCRIPTION
    À lancer SUR le serveur de fichiers (chemins locaux, droits NTFS posés en local), avec un
    compte d'administration Tier 1 (-A1). Prérequis : module ActiveDirectory (RSAT-AD-PowerShell)
    et groupes DL_FIC_* créés par AGRISKY-CreateADStructure.ps1.

    Arborescence créée (naming-agrisky.md, section 8) :

      <Racine>\Partages            -> partage SMB « Partages »  -> \\agrisky.lan\partages
        INF, USR, DIR, CPT           (un dossier par population)
        Commun                       (transverse)
        Plans                        (métier : bureau d'études)
      <Racine>\Perso               -> partage SMB « Perso$ »    -> \\agrisky.lan\perso
        <matricule>                  (un dossier par compte de l'OU Utilisateurs)

    Droits (AGDLP) : seuls les groupes DL_FIC_<Ressource>_<RW|RO> reçoivent des droits NTFS,
    jamais un utilisateur ou un GG directement. Exception : le dossier personnel, où seul son
    titulaire a accès (avec SYSTEM et les administrateurs locaux).
    Les deux partages SMB sont en énumération basée sur l'accès : chacun ne voit que ce qu'il peut ouvrir.

    Ensuite, sauf -SansQuotas / -SansCliches :
      - quotas FSRM : dur sur chaque dossier perso (2 Go par défaut), souple sur chaque dossier
        partagé (20 Go par défaut, alerte seulement) ; alerte à 80 % dans le journal d'événements ;
      - clichés instantanés (VSS) sur le volume des données : espace réservé (10 % du volume),
        tâche planifiée du lundi au vendredi à 7 h et 12 h, et un premier cliché tout de suite.
        Les utilisateurs restaurent eux-mêmes par clic droit > Versions précédentes.
        Ce n'est pas une sauvegarde : un cliché disparaît avec le disque.

    Idempotent : un dossier existant n'est pas recréé. Ses droits ne sont réappliqués qu'avec
    -ReappliquerAcl (remise en conformité si quelqu'un les a modifiés à la main).
    Rien n'est jamais supprimé : le dossier perso d'un compte parti reste en place.

.EXAMPLE
    .\AGRISKY-AddSharedFolders.ps1 -WhatIf -Verbose
    .\AGRISKY-AddSharedFolders.ps1 -Racine 'D:\Donnees' -Verbose
    .\AGRISKY-AddSharedFolders.ps1 -ReappliquerAcl -Verbose
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Dossier racine des données sur le serveur de fichiers (idéalement un disque dédié)
    [string]$Racine = 'D:\Donnees',
    [string]$OuUtilisateurs = 'AGRISKY/Utilisateurs',
    [switch]$ReappliquerAcl,
    [int]$QuotaPersoGo   = 2,
    [int]$QuotaPartageGo = 20,
    [string[]]$HeuresCliches = @('07:00', '12:00'),
    [switch]$SansQuotas,
    [switch]$SansCliches
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

#region --- Journalisation ---------------------------------------------------------------------
$LogFolder = Join-Path $PSScriptRoot 'Les Logs Scripts'
$LogFile   = Join-Path $LogFolder "LogsduScript-Agrisky-AddSharedFolders_$(Get-Date -Format 'yyyy-MM-dd').log"
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force -WhatIf:$false | Out-Null }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','SUCCESS','ERROR','WARN')][string]$Level = 'INFO'
    )
    $Prefixe = if ($WhatIfPreference) { '[SIMULATION] ' } else { '' }
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Prefixe$Message" -Encoding UTF8 -WhatIf:$false
    if ($Level -in 'ERROR', 'WARN') { Write-Warning $Message } else { Write-Verbose $Message }
}
#endregion

#region --- Paramétrage des dossiers partagés ----------------------------------------------------
# Dossier => groupes DL et droit NTFS (Modify = lecture/écriture, ReadAndExecute = lecture seule)
$DossiersPartages = [ordered]@{
    'INF'    = @{ 'DL_FIC_INF_RW'    = 'Modify' }
    'USR'    = @{ 'DL_FIC_USR_RW'    = 'Modify' }
    'DIR'    = @{ 'DL_FIC_DIR_RW'    = 'Modify' }
    'CPT'    = @{ 'DL_FIC_CPT_RW'    = 'Modify' }
    'Commun' = @{ 'DL_FIC_Commun_RW' = 'Modify' }
    'Plans'  = @{ 'DL_FIC_Plans_RW'  = 'Modify'; 'DL_FIC_Plans_RO' = 'ReadAndExecute' }
}
$RacinePartages = Join-Path $Racine 'Partages'
$RacinePerso    = Join-Path $Racine 'Perso'
#endregion

#region --- Fonctions ----------------------------------------------------------------------------
$Domaine  = Get-ADDomain
$NetBIOS  = $Domaine.NetBIOSName
$DomainDN = $Domaine.DistinguishedName

# Comptes intégrés par SID : fonctionne quelle que soit la langue de Windows
function Get-NomCompte { param([string]$Sid) ([System.Security.Principal.SecurityIdentifier]$Sid).Translate([System.Security.Principal.NTAccount]).Value }
$Administrateurs = Get-NomCompte 'S-1-5-32-544'   # BUILTIN\Administrateurs
$Systeme         = Get-NomCompte 'S-1-5-18'       # NT AUTHORITY\SYSTEM
$UtilAuthentifies = Get-NomCompte 'S-1-5-11'      # NT AUTHORITY\Utilisateurs authentifiés

function New-Regle {
    param([string]$Identite, [string]$Droit, [switch]$CeDossierSeulement)
    $Heritage = if ($CeDossierSeulement) { 'None' } else { 'ContainerInherit, ObjectInherit' }
    [System.Security.AccessControl.FileSystemAccessRule]::new($Identite, $Droit, $Heritage, 'None', 'Allow')
}

# Remplace les droits du dossier : héritage coupé, administrateurs + SYSTEM en contrôle total, puis les règles données
function Set-DroitsDossier {
    param([string]$Chemin, [System.Security.AccessControl.FileSystemAccessRule[]]$Regles)
    $Acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $Acl.SetAccessRuleProtection($true, $false)
    $Acl.AddAccessRule((New-Regle $Administrateurs 'FullControl'))
    $Acl.AddAccessRule((New-Regle $Systeme 'FullControl'))
    foreach ($R in $Regles) { $Acl.AddAccessRule($R) }
    Set-Acl -Path $Chemin -AclObject $Acl
}

function New-Dossier {
    param([string]$Chemin)
    if (Test-Path $Chemin) { return $false }
    if ($PSCmdlet.ShouldProcess($Chemin, 'Créer le dossier')) { New-Item -Path $Chemin -ItemType Directory -Force | Out-Null }
    return $true
}

function New-Partage {
    param([string]$Nom, [string]$Chemin, [string]$Description)
    if (Get-SmbShare -Name $Nom -ErrorAction SilentlyContinue) { Write-Log "Partage SMB $Nom existe déjà" -Level INFO; return }
    if ($PSCmdlet.ShouldProcess("$Nom -> $Chemin", 'Créer le partage SMB')) {
        # Droits de partage larges, c'est NTFS qui filtre ; énumération basée sur l'accès activée
        New-SmbShare -Name $Nom -Path $Chemin -Description $Description `
                     -FullAccess $Administrateurs -ChangeAccess $UtilAuthentifies `
                     -FolderEnumerationMode AccessBased | Out-Null
        Write-Log "Partage SMB \\$env:COMPUTERNAME\$Nom créé ($Chemin)" -Level SUCCESS
    }
}

$GroupesVerifies = @{}
function Test-Groupe {
    param([string]$Nom)
    if (-not $GroupesVerifies.ContainsKey($Nom)) {
        $GroupesVerifies[$Nom] = [bool](Get-ADGroup -Filter "SamAccountName -eq '$Nom'" -ErrorAction SilentlyContinue)
    }
    $GroupesVerifies[$Nom]
}

$Stats = @{ Crees = 0; AclPosees = 0; Ignores = 0; Erreurs = 0 }
#endregion

#region --- 1. Racines et partages SMB -----------------------------------------------------------
foreach ($R in $Racine, $RacinePartages, $RacinePerso) {
    if (New-Dossier $R) { Write-Log "Dossier $R créé" -Level SUCCESS }
}
if (-not $WhatIfPreference) {
    # Racines : les utilisateurs authentifiés peuvent seulement traverser et lister CE dossier, pas ses sous-dossiers
    foreach ($R in $RacinePartages, $RacinePerso) {
        Set-DroitsDossier $R @(New-Regle $UtilAuthentifies 'ReadAndExecute' -CeDossierSeulement)
    }
}
New-Partage -Nom 'Partages' -Chemin $RacinePartages -Description 'Partages Agrisky (populations, Commun, métiers)'
New-Partage -Nom 'Perso$'   -Chemin $RacinePerso    -Description 'Dossiers personnels Agrisky'
#endregion

#region --- 2. Dossiers par population, transverse et métier ------------------------------------
$i = 0
foreach ($Nom in $DossiersPartages.Keys) {
    $i++
    Write-Progress -Activity 'Dossiers partagés' -Status $Nom -PercentComplete ($i / $DossiersPartages.Count * 100)
    $Chemin = Join-Path $RacinePartages $Nom
    $Cree   = New-Dossier $Chemin
    if ($Cree) { Write-Log "Dossier $Chemin créé" -Level SUCCESS; $Stats.Crees++ }
    else       { Write-Log "Dossier $Chemin existe déjà" -Level INFO; $Stats.Ignores++ }

    if (-not ($Cree -or $ReappliquerAcl)) { continue }

    $Regles = @()
    foreach ($G in $DossiersPartages[$Nom].Keys) {
        if (Test-Groupe $G) { $Regles += New-Regle "$NetBIOS\$G" $DossiersPartages[$Nom][$G] }
        else { Write-Log "  $Nom : groupe $G introuvable, droit non posé (lancer le script de structure AD)" -Level WARN }
    }
    if ($PSCmdlet.ShouldProcess($Chemin, "Poser les droits NTFS ($($DossiersPartages[$Nom].Keys -join ', '))")) {
        try {
            Set-DroitsDossier $Chemin $Regles
            Write-Log "  Droits posés sur $Nom : $(($DossiersPartages[$Nom].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" -Level INFO
            $Stats.AclPosees++
        }
        catch { Write-Log "ECHEC droits sur $Chemin : $($_.Exception.Message)" -Level ERROR; $Stats.Erreurs++ }
    }
}
Write-Progress -Activity 'Dossiers partagés' -Completed
#endregion

#region --- 3. Dossiers personnels ---------------------------------------------------------------
$Parties = $OuUtilisateurs.Trim('/').Split('/'); [array]::Reverse($Parties)
$SearchBase = (($Parties | ForEach-Object { "OU=$_" }) -join ',') + ",$DomainDN"
$Utilisateurs = @(Get-ADUser -Filter 'Enabled -eq $true' -SearchBase $SearchBase)
Write-Log "Dossiers personnels : $($Utilisateurs.Count) comptes actifs dans $SearchBase" -Level INFO

$i = 0
foreach ($U in $Utilisateurs) {
    $i++
    Write-Progress -Activity 'Dossiers personnels' -Status $U.SamAccountName -PercentComplete ($i / $Utilisateurs.Count * 100)
    $Sam    = $U.SamAccountName
    $Chemin = Join-Path $RacinePerso $Sam
    $Cree   = New-Dossier $Chemin
    if ($Cree) { Write-Log "Dossier perso $Sam créé" -Level SUCCESS; $Stats.Crees++ }
    else       { Write-Log "Dossier perso $Sam existe déjà" -Level INFO; $Stats.Ignores++ }

    if (-not ($Cree -or $ReappliquerAcl)) { continue }
    if ($PSCmdlet.ShouldProcess($Chemin, "Droits : $Sam seul (Modify)")) {
        try {
            Set-DroitsDossier $Chemin @(New-Regle "$NetBIOS\$Sam" 'Modify')
            $Stats.AclPosees++
        }
        catch { Write-Log "ECHEC droits sur $Chemin : $($_.Exception.Message)" -Level ERROR; $Stats.Erreurs++ }
    }
}
Write-Progress -Activity 'Dossiers personnels' -Completed
#endregion

#region --- 4. Quotas FSRM ----------------------------------------------------------------------
if (-not $SansQuotas) {
    if (-not (Get-WindowsFeature FS-Resource-Manager).Installed) {
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Installer le rôle FSRM')) {
            Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools | Out-Null
            Import-Module FileServerResourceManager
            Write-Log "Rôle FSRM installé" -Level SUCCESS
        }
    }
    if (-not (Get-Command New-FsrmQuota -ErrorAction SilentlyContinue)) {
        Write-Log "FSRM non disponible (simulation ou installation impossible) : quotas non posés" -Level WARN
    }
    else {
        # Alerte à 80 % dans le journal Application (l'envoi de mail demande un serveur SMTP configuré dans FSRM)
        function Set-ModeleQuota {
            param([string]$Nom, [int]$TailleGo, [switch]$Souple)
            if (Get-FsrmQuotaTemplate -Name $Nom -ErrorAction SilentlyContinue) { return }
            if ($PSCmdlet.ShouldProcess($Nom, "Créer le modèle de quota ($TailleGo Go$(if ($Souple) {', souple'}))")) {
                $Action = New-FsrmAction -Type Event -EventType Warning -RunLimitInterval 180 `
                          -Body 'Quota [Quota Path] : [Quota Threshold] % atteint ([Quota Used MB] Mo sur [Quota Limit MB] Mo).'
                $Seuil  = New-FsrmQuotaThreshold -Percentage 80 -Action $Action
                New-FsrmQuotaTemplate -Name $Nom -Size ([uint64]$TailleGo * 1GB) -SoftLimit:$Souple -Threshold $Seuil | Out-Null
                Write-Log "Modèle de quota « $Nom » créé" -Level SUCCESS
            }
        }
        function Set-QuotaDossier {
            param([string]$Chemin, [string]$Modele)
            $Existant = try { Get-FsrmQuota -Path $Chemin -ErrorAction Stop } catch { $null }
            if ($Existant) { return }
            if ($PSCmdlet.ShouldProcess($Chemin, "Appliquer le quota « $Modele »")) {
                try { New-FsrmQuota -Path $Chemin -Template $Modele | Out-Null; Write-Log "  Quota « $Modele » sur $Chemin" -Level INFO }
                catch { Write-Log "ECHEC quota sur $Chemin : $($_.Exception.Message)" -Level ERROR; $Stats.Erreurs++ }
            }
        }

        $ModelePerso   = "Agrisky - Perso $QuotaPersoGo Go"
        $ModelePartage = "Agrisky - Partage $QuotaPartageGo Go (souple)"
        Set-ModeleQuota -Nom $ModelePerso   -TailleGo $QuotaPersoGo
        Set-ModeleQuota -Nom $ModelePartage -TailleGo $QuotaPartageGo -Souple

        foreach ($Nom in $DossiersPartages.Keys) { Set-QuotaDossier (Join-Path $RacinePartages $Nom) $ModelePartage }
        # Tous les dossiers perso présents, y compris ceux créés lors de lancements précédents
        Get-ChildItem -Path $RacinePerso -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Set-QuotaDossier $_.FullName $ModelePerso }
    }
}
#endregion

#region --- 5. Clichés instantanés (VSS) ---------------------------------------------------------
if (-not $SansCliches) {
    $Lettre = (Split-Path -Qualifier $Racine)                 # ex. D:
    $Volume = Get-CimInstance Win32_Volume -Filter "DriveLetter = '$Lettre'"
    if (-not $Volume) {
        Write-Log "Volume $Lettre introuvable : clichés instantanés non configurés" -Level ERROR; $Stats.Erreurs++
    }
    else {
        if ($Lettre -eq $env:SystemDrive) {
            Write-Log "Les données sont sur le disque système ($Lettre) : un disque de données dédié est recommandé" -Level WARN
        }

        # Espace réservé aux clichés : 10 % du volume, sur le volume lui-même
        $Stockage = Get-CimInstance Win32_ShadowStorage | Where-Object { $_.Volume.DeviceID -eq $Volume.DeviceID }
        if (-not $Stockage -and $PSCmdlet.ShouldProcess($Lettre, 'Réserver 10 % du volume aux clichés instantanés')) {
            $Res = Invoke-CimMethod -ClassName Win32_ShadowStorage -MethodName Create -Arguments @{
                       Volume = "$Lettre\"; DiffVolume = "$Lettre\"; MaxSpace = [uint64]($Volume.Capacity * 0.10) }
            if ($Res.ReturnValue -eq 0) { Write-Log "Stockage des clichés créé sur $Lettre (10 %)" -Level SUCCESS }
            else { Write-Log "ECHEC stockage des clichés sur $Lettre (code $($Res.ReturnValue))" -Level ERROR; $Stats.Erreurs++ }
        }

        # Tâche planifiée : un cliché à chaque heure demandée, du lundi au vendredi
        $NomTache = "Agrisky-ClichesInstantanes-$($Lettre.TrimEnd(':'))"
        if (-not (Get-ScheduledTask -TaskName $NomTache -ErrorAction SilentlyContinue) -and
            $PSCmdlet.ShouldProcess($NomTache, "Planifier les clichés ($($HeuresCliches -join ', '), lun-ven)")) {
            $Commande  = "Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = '$Lettre\' }"
            $Action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -Command `"$Commande`""
            $Triggers  = $HeuresCliches | ForEach-Object {
                             New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $_ }
            $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $NomTache -Action $Action -Trigger $Triggers -Principal $Principal `
                                   -Description "Clichés instantanés du volume $Lettre (dossiers partagés Agrisky)" | Out-Null
            Write-Log "Tâche planifiée $NomTache créée ($($HeuresCliches -join ', '), lun-ven)" -Level SUCCESS

            # Premier cliché tout de suite, pour pouvoir tester « Versions précédentes »
            $Res = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = "$Lettre\" }
            if ($Res.ReturnValue -eq 0) { Write-Log "Premier cliché instantané de $Lettre créé" -Level SUCCESS }
            else { Write-Log "Premier cliché de $Lettre en échec (code $($Res.ReturnValue))" -Level WARN }
        }
    }
}
#endregion

$Bilan = "Bilan - $($Stats.Crees) dossier(s) créé(s), $($Stats.AclPosees) jeu(x) de droits posé(s), " +
         "$($Stats.Ignores) déjà présent(s), $($Stats.Erreurs) erreur(s)"
Write-Log $Bilan -Level INFO
Write-Host $Bilan
Write-Host "Etape suivante : espace de noms DFS \\agrisky.lan\partages -> \\$env:COMPUTERNAME\Partages et \\agrisky.lan\perso -> \\$env:COMPUTERNAME\Perso$"
