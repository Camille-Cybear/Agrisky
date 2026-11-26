#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Création de la structure AD Agrisky (OU, groupes, imbrications) à partir de l'onglet
    « Structure AD » du registre des matricules.

.DESCRIPTION
    Entrée : Export-AD-Structure.csv (Fichier > Télécharger > CSV sur l'onglet « Structure AD »)
      Colonnes : Type, Nom, Emplacement, Description, Remarques, MembreDe
        - Type        : OU, GG (global), DL (domaine local), GU (universel)
        - Emplacement : chemin de l'OU parente (ex. AGRISKY/Groupes/Roles) ; vide = racine du domaine
        - MembreDe    : groupes dont l'objet doit être membre, séparés par des virgules (AGDLP)

    Trois passes, dans cet ordre :
      1. OU, des moins profondes aux plus profondes (la parente existe toujours avant l'enfant)
      2. Groupes de sécurité
      3. Imbrications (MembreDe), une fois tous les groupes créés

    Idempotent : ce qui existe déjà est ignoré, le script peut être relancé après chaque ajout
    de ligne dans l'onglet. Il ne supprime ni ne déplace jamais rien.

    Les OU sont protégées contre la suppression accidentelle (comportement par défaut de l'AD).
    -SansProtection les crée sans protection, pratique en maquette pour pouvoir tout recommencer.

.EXAMPLE
    .\AGRISKY-CreateADStructure.ps1 -WhatIf -Verbose     # simulation
    .\AGRISKY-CreateADStructure.ps1 -Verbose              # création réelle
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FichierStructure = (Join-Path $PSScriptRoot 'Export-AD-Structure.csv'),
    [switch]$SansProtection
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

#region --- Journalisation ---------------------------------------------------------------------
$LogFolder = Join-Path $PSScriptRoot 'Les Logs Scripts'
$LogFile   = Join-Path $LogFolder "LogsduScript-Agrisky-CreateADStructure_$(Get-Date -Format 'yyyy-MM-dd').log"
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

#region --- Préparation -------------------------------------------------------------------------
if (-not (Test-Path $FichierStructure)) { throw "Fichier introuvable : $FichierStructure" }
$Lignes = @(Import-Csv -Path $FichierStructure -Delimiter ',' -Encoding UTF8 |
            Where-Object { "$($_.Type)".Trim() -and "$($_.Nom)".Trim() })

$Domaine    = Get-ADDomain
$DomainDN   = $Domaine.DistinguishedName
$DomainSID  = $Domaine.DomainSID.Value

# "AGRISKY/Groupes/Roles" -> "OU=Roles,OU=Groupes,OU=AGRISKY,DC=agrisky,DC=lan" ; vide -> racine du domaine
function ConvertTo-OuDN {
    param([string]$Chemin)
    $Chemin = "$Chemin".Trim().Trim('/')
    if (-not $Chemin) { return $DomainDN }
    $Parties = $Chemin.Split('/'); [array]::Reverse($Parties)
    (($Parties | ForEach-Object { "OU=$_" }) -join ',') + ",$DomainDN"
}

function Test-OuExiste {
    param([string]$DN)
    [bool](Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$DN'" -ErrorAction SilentlyContinue)
}

# Groupes intégrés : leur nom dépend de la langue du DC, on les retrouve par leur SID
$GroupesIntegres = @{
    'Admins du domaine'           = "$DomainSID-512"; 'Domain Admins'     = "$DomainSID-512"
    'Administrateurs de l''entreprise' = "$DomainSID-519"; 'Enterprise Admins' = "$DomainSID-519"
    'Administrateurs du schéma'   = "$DomainSID-518"; 'Schema Admins'     = "$DomainSID-518"
    'Protected Users'             = "$DomainSID-525"
}
function Resolve-Groupe {
    param([string]$Nom)
    $Cible = if ($GroupesIntegres.ContainsKey($Nom)) { $GroupesIntegres[$Nom] } else { $Nom }
    try { Get-ADGroup -Identity $Cible -Properties Members } catch { $null }
}

$Portees = @{ GG = 'Global'; DL = 'DomainLocal'; GU = 'Universal' }
$Stats = @{ OuCrees = 0; GroupesCrees = 0; Imbrications = 0; Ignores = 0; Erreurs = 0 }
Write-Log "Début du traitement : $($Lignes.Count) lignes dans $FichierStructure" -Level INFO
#endregion

#region --- Passe 1 : OU -------------------------------------------------------------------------
# Tri par profondeur : AGRISKY, puis AGRISKY/Postes, puis AGRISKY/Postes/ORL...
$OUs = $Lignes | Where-Object { $_.Type.Trim() -eq 'OU' } |
       Sort-Object { if ("$($_.Emplacement)".Trim()) { "$($_.Emplacement)".Trim('/').Split('/').Count } else { 0 } }

foreach ($L in $OUs) {
    $Nom    = $L.Nom.Trim()
    $Parent = ConvertTo-OuDN $L.Emplacement
    $DN     = "OU=$Nom,$Parent"

    if ($Nom -notmatch '^[A-Za-z0-9_-]+$') {
        Write-Log "OU « $Nom » ignorée : caractères non autorisés (naming : lettres, chiffres, - et _)" -Level ERROR; $Stats.Erreurs++; continue
    }
    if (Test-OuExiste $DN) { Write-Log "OU $DN existe déjà" -Level INFO; $Stats.Ignores++; continue }
    if ($Parent -ne $DomainDN -and -not (Test-OuExiste $Parent) -and -not $WhatIfPreference) {
        Write-Log "OU $Nom ignorée : parente absente ($Parent)" -Level ERROR; $Stats.Erreurs++; continue
    }

    if ($PSCmdlet.ShouldProcess($DN, 'Créer l''OU')) {
        try {
            New-ADOrganizationalUnit -Name $Nom -Path $Parent -Description $L.Description `
                                     -ProtectedFromAccidentalDeletion (-not $SansProtection)
            Write-Log "OU $DN créée" -Level SUCCESS; $Stats.OuCrees++
        }
        catch { Write-Log "ECHEC création OU $DN : $($_.Exception.Message)" -Level ERROR; $Stats.Erreurs++ }
    }
}
#endregion

#region --- Passe 2 : groupes --------------------------------------------------------------------
$Groupes = $Lignes | Where-Object { $_.Type.Trim() -in $Portees.Keys }

foreach ($L in $Groupes) {
    $Type = $L.Type.Trim()
    $Nom  = $L.Nom.Trim()
    $Path = ConvertTo-OuDN $L.Emplacement

    if ($Nom -notmatch '^[A-Za-z0-9_-]+$') {
        Write-Log "Groupe « $Nom » ignoré : caractères non autorisés" -Level ERROR; $Stats.Erreurs++; continue
    }
    if (-not $Nom.StartsWith("${Type}_")) {
        Write-Log "Groupe $Nom : le nom ne commence pas par ${Type}_ (naming section 5), créé quand même" -Level WARN
    }
    if (Get-ADGroup -Filter "SamAccountName -eq '$Nom'" -ErrorAction SilentlyContinue) {
        Write-Log "Groupe $Nom existe déjà" -Level INFO; $Stats.Ignores++; continue
    }
    if (-not (Test-OuExiste $Path) -and -not $WhatIfPreference) {
        Write-Log "Groupe $Nom ignoré : OU absente ($Path)" -Level ERROR; $Stats.Erreurs++; continue
    }

    if ($PSCmdlet.ShouldProcess("$Nom ($($Portees[$Type])) dans $Path", 'Créer le groupe')) {
        try {
            New-ADGroup -Name $Nom -SamAccountName $Nom -GroupCategory Security -GroupScope $Portees[$Type] `
                        -Path $Path -Description $L.Description
            Write-Log "Groupe $Nom ($($Portees[$Type])) créé" -Level SUCCESS; $Stats.GroupesCrees++
        }
        catch { Write-Log "ECHEC création groupe $Nom : $($_.Exception.Message)" -Level ERROR; $Stats.Erreurs++ }
    }
}
#endregion

#region --- Passe 3 : imbrications (MembreDe) ----------------------------------------------------
foreach ($L in ($Groupes | Where-Object { "$($_.MembreDe)".Trim() })) {
    $Nom    = $L.Nom.Trim()
    $Membre = try { Get-ADGroup -Identity $Nom } catch { $null }
    if (-not $Membre) {
        if (-not $WhatIfPreference) { Write-Log "Imbrication ignorée : groupe $Nom introuvable" -Level ERROR; $Stats.Erreurs++ }
        continue
    }

    foreach ($NomParent in ($L.MembreDe.Split(',') | ForEach-Object Trim | Where-Object { $_ })) {
        $Parent = Resolve-Groupe $NomParent
        if (-not $Parent) {
            Write-Log "Imbrication $Nom -> $NomParent ignorée : groupe cible introuvable" -Level ERROR; $Stats.Erreurs++; continue
        }
        if ($Parent.Members -contains $Membre.DistinguishedName) {
            Write-Log "$Nom est déjà membre de $($Parent.Name)" -Level INFO; continue
        }
        if ($PSCmdlet.ShouldProcess("$Nom -> $($Parent.Name)", 'Ajouter au groupe')) {
            try {
                Add-ADGroupMember -Identity $Parent -Members $Membre
                $Niveau = if ($Parent.SID.Value -in "$DomainSID-512", "$DomainSID-519", "$DomainSID-518") { 'WARN' } else { 'SUCCESS' }
                Write-Log "$Nom ajouté à $($Parent.Name)" -Level $Niveau      # WARN = groupe à privilèges, visible dans le journal
                $Stats.Imbrications++
            }
            catch { Write-Log "ECHEC imbrication $Nom -> $($Parent.Name) : $($_.Exception.Message)" -Level ERROR; $Stats.Erreurs++ }
        }
    }
}
#endregion

$Bilan = "Bilan - $($Stats.OuCrees) OU créée(s), $($Stats.GroupesCrees) groupe(s) créé(s), " +
         "$($Stats.Imbrications) imbrication(s), $($Stats.Ignores) déjà présent(s), $($Stats.Erreurs) erreur(s)"
Write-Log $Bilan -Level INFO
Write-Host $Bilan
