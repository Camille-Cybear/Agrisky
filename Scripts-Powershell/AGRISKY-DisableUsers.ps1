#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Désactivation des comptes des salariés partis, à partir de l'export « Export AD - Departs »
    du registre des matricules (lignes au statut « Désactivé »).

.DESCRIPTION
    Pour chaque matricule de l'export, le compte standard ET ses comptes d'administration
    (MATRICULE-A0/A1/A2) sont traités :
      - date de départ dans le futur : expiration du compte posée à cette date, rien d'autre
        (relancer le script après le départ pour finir le traitement) ;
      - date de départ passée ou vide : compte désactivé, mot de passe remplacé par une valeur
        aléatoire, retrait de tous les groupes (liste journalisée pour pouvoir restaurer),
        description horodatée, déplacement dans l'OU Desactives, ManagedBy vidé sur ses postes.
    Rien n'est supprimé : la suppression se fait plus tard, après la durée de conservation.
    Le matricule reste dans EmployeeID et n'est jamais réattribué (naming-agrisky.md).

    Le script est idempotent : un compte déjà désactivé et rangé dans Desactives est ignoré.

    Deux modes :
      - normal (par défaut) : lecture de Export-AD-Departs.csv, exporté du registre ;
      - urgence (-Matricule) : désactivation immédiate des matricules donnés, sans attendre la mise
        à jour du registre (compte compromis, départ immédiat). Le registre doit être mis à jour ensuite.

.EXAMPLE
    .\AGRISKY-DisableUsers.ps1 -WhatIf -Verbose                         # simulation depuis le registre
    .\AGRISKY-DisableUsers.ps1 -Verbose                                  # exécution réelle depuis le registre
    .\AGRISKY-DisableUsers.ps1 -Matricule JD0006I -Ticket 42 -Verbose    # urgence, un ou plusieurs matricules
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Registre')]
param(
    [Parameter(ParameterSetName = 'Registre')]
    [string]$FichierDeparts = (Join-Path $PSScriptRoot 'Export-AD-Departs.csv'),

    [Parameter(ParameterSetName = 'Urgence', Mandatory)]
    [ValidatePattern('^[A-Za-z]{2}\d{4}[IEie]$')]
    [string[]]$Matricule,

    [Parameter(ParameterSetName = 'Urgence')]
    [string]$Ticket = '',

    [string]$OuDesactives = 'AGRISKY/Desactives'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

#region --- Journalisation ---------------------------------------------------------------------
$LogFolder = Join-Path $PSScriptRoot 'Les Logs Scripts'
$LogFile   = Join-Path $LogFolder "LogsduScript-Agrisky-DisableUsers_$(Get-Date -Format 'yyyy-MM-dd').log"
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
if ($PSCmdlet.ParameterSetName -eq 'Urgence') {
    # Mode urgence : désactivation immédiate (date de départ vide = aujourd'hui)
    $Departs = @($Matricule | ForEach-Object {
        [PSCustomObject]@{ Matricule = $_; DateDepart = ''; TicketGLPI = $Ticket } })
    Write-Log "Mode urgence : $($Matricule -join ', '). Penser à passer ces lignes en « Désactivé » dans le registre." -Level WARN
}
else {
    if (-not (Test-Path $FichierDeparts)) { throw "Fichier introuvable : $FichierDeparts" }
    $Departs = @(Import-Csv -Path $FichierDeparts -Delimiter ',' -Encoding UTF8 |
                 Where-Object { "$($_.Matricule)".Trim() })      # l'onglet vide exporte une ligne blanche
}

$DomainDN = (Get-ADDomain).DistinguishedName
$Parties  = $OuDesactives.Trim('/').Split('/'); [array]::Reverse($Parties)
$DnDesactives = (($Parties | ForEach-Object { "OU=$_" }) -join ',') + ",$DomainDN"
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$DnDesactives'" -ErrorAction SilentlyContinue)) {
    throw "OU $DnDesactives absente : lancer d'abord le script de structure AD."
}

$Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function New-MotDePasseJetable {
    # 32 octets aléatoires en Base64 : personne ne le connaît, il invalide l'ancien mot de passe
    $Octets = [byte[]]::new(32); $Rng.GetBytes($Octets)
    'Aa1!' + [Convert]::ToBase64String($Octets)
}

$Aujourdhui = (Get-Date).Date
$Stats = @{ Desactives = 0; Programmes = 0; Ignores = 0; Erreurs = 0 }
Write-Log "Début du traitement : $($Departs.Count) départ(s) dans l'export" -Level INFO
#endregion

foreach ($D in $Departs) {
    $Mat       = "$($D.Matricule)".Trim().ToUpper()
    $NumTicket = "$($D.TicketGLPI)".Trim()
    $DateDepart = $null
    if ($D.DateDepart) { $DateDepart = [datetime]::ParseExact($D.DateDepart.Trim(), 'yyyy-MM-dd', $null) }

    if ($Mat -notmatch '^[A-Z]{2}\d{4}[IE]$') {
        Write-Log "Ligne ignorée : matricule invalide « $Mat »" -Level ERROR; $Stats.Erreurs++; continue
    }

    # Compte standard + comptes d'administration rattachés
    $Comptes = @(Get-ADUser -Filter "SamAccountName -eq '$Mat' -or SamAccountName -like '$Mat-A*'" `
                            -Properties MemberOf, Description, Enabled, ProtectedFromAccidentalDeletion)
    if ($Comptes.Count -eq 0) {
        Write-Log "$Mat : aucun compte dans l'AD, rien à faire" -Level WARN; $Stats.Ignores++; continue
    }

    foreach ($C in $Comptes) {
        $Sam = $C.SamAccountName

        # --- Départ futur : on programme l'expiration et on s'arrête là
        if ($DateDepart -and $DateDepart -gt $Aujourdhui) {
            if ($PSCmdlet.ShouldProcess($Sam, "Programmer l'expiration au $($DateDepart.ToString('dd/MM/yyyy'))")) {
                try {
                    Set-ADUser $C -AccountExpirationDate $DateDepart.AddDays(1)
                    Write-Log "$Sam : départ le $($DateDepart.ToString('dd/MM/yyyy')), expiration programmée. Relancer après cette date." -Level INFO
                    $Stats.Programmes++
                }
                catch { Write-Log "ECHEC $Sam : $($_.Exception.Message)" -Level ERROR; $Stats.Erreurs++ }
            }
            continue
        }

        # --- Déjà traité
        if (-not $C.Enabled -and $C.DistinguishedName -like "*,$DnDesactives") {
            Write-Log "$Sam déjà désactivé et rangé dans Desactives, ignoré" -Level WARN; $Stats.Ignores++; continue
        }

        if ($PSCmdlet.ShouldProcess($Sam, 'Désactiver, retirer des groupes et déplacer dans Desactives')) {
            try {
                # 1. Désactivation et mot de passe jetable
                Disable-ADAccount $C
                Set-ADAccountPassword $C -Reset -NewPassword (ConvertTo-SecureString (New-MotDePasseJetable) -AsPlainText -Force)

                # 2. Retrait des groupes, liste conservée dans le journal (restauration possible)
                $Groupes = @($C.MemberOf)
                if ($Groupes.Count) {
                    $Noms = $Groupes | ForEach-Object { (Get-ADGroup $_).SamAccountName }
                    Write-Log "$Sam : groupes avant retrait = $($Noms -join ', ')" -Level INFO
                    foreach ($G in $Groupes) { Remove-ADGroupMember -Identity $G -Members $C -Confirm:$false }
                }

                # 3. Description horodatée (l'ancienne est conservée à la suite)
                $Mention = "Désactivé le $($Aujourdhui.ToString('dd/MM/yyyy'))"
                if ($NumTicket) { $Mention += " (ticket GLPI $NumTicket)" }
                Set-ADUser $C -Description "$Mention – $($C.Description)"

                # 4. Postes dont il était le propriétaire : ManagedBy vidé
                Get-ADComputer -Filter "ManagedBy -eq '$($C.DistinguishedName)'" | ForEach-Object {
                    Set-ADComputer $_ -Clear ManagedBy
                    Write-Log "  Poste $($_.Name) : ManagedBy vidé (ancien titulaire $Sam)" -Level INFO
                }

                # 5. Déplacement dans Desactives (la protection anti-suppression bloque aussi le déplacement)
                $Protege = $C.ProtectedFromAccidentalDeletion
                if ($Protege) { Set-ADObject $C -ProtectedFromAccidentalDeletion $false }
                $Deplace = Move-ADObject $C -TargetPath $DnDesactives -PassThru
                if ($Protege) { Set-ADObject $Deplace -ProtectedFromAccidentalDeletion $true }

                Write-Log "$Sam désactivé et déplacé dans Desactives" -Level SUCCESS
                $Stats.Desactives++
            }
            catch {
                Write-Log "ECHEC désactivation $Sam : $($_.Exception.Message)" -Level ERROR
                $Stats.Erreurs++
            }
        }
    }
}
$Rng.Dispose()

$Bilan = "Bilan - $($Stats.Desactives) désactivé(s), $($Stats.Programmes) expiration(s) programmée(s), " +
         "$($Stats.Ignores) ignoré(s), $($Stats.Erreurs) erreur(s)"
Write-Log $Bilan -Level INFO
Write-Host $Bilan
Write-Host "Rappel : une session déjà ouverte reste active jusqu'à sa fermeture (ticket Kerberos valide jusqu'à 10 h)."
