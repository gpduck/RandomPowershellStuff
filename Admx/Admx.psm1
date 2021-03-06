#Requires -Version 4
<#
Author: Chris Duck
Link: http://github.com/gpduck/RandomPowerShellStuff/tree/master/Admx

Copyright 2014 Chris Duck

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
#>


function Resolve-AdmxTemplatePath {
	param(
		[Parameter(ParameterSetName="Local")]
		[Switch]$Local,

		[Parameter(ParameterSetName="Domain")]
		[Switch]$Domain,

		[Parameter(ParameterSetName="Domain")]
		[String]$DomainName	
	)
	if($PsCmdlet.ParameterSetName -eq "Local") {
		$Folder = Join-Path -Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows)) -ChildPath "PolicyDefinitions"
	} else {
		if(!$DomainName) {
			Add-Type -AssemblyName System.DirectoryServices
			$DomainName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
		}
		$Folder = "\\$DomainName\sysvol\$DomainName\Policies\PolicyDefinitions"
	}
	$Folder
}

function Get-AdmxStrings {
	[CmdletBinding()]
	param(
		[IO.FileInfo]$AdmxFile
	)
	$Strings = @{}
	$AdmlFile = Join-Path -Path $AdmxFile.Directory -ChildPath ("{0}\{1}.adml" -f [System.threading.thread]::CurrentThread.CurrentUICulture, $AdmxFile.BaseName)
	$Adml = [xml](Get-Content -Path $AdmlFile -Raw)
	$Adml.PolicyDefinitionResources.Resources.StringTable.String | %{
		#$Text = [System.Web.HttpUtility]::HtmlEncode($_."#text")
		$Text = $_."#Text"
		$Strings.Add("string.$($_.id)", ({$Text}.GetNewClosure()))
	}
	$Adml.PolicyDefinitionResources.Resources.PresentationTable.Presentation | %{
		$Strings.Add("presentation.$($_.Id)", { "" })
	}

	$Strings
}

function WalkDisplayPath {
	param(
		$Start
	)
	if($Start.Parent) {
		"{0}\{1}" -f (WalkDisplayPath -Start $Start.Parent), $Start.DisplayName
	} else {
		$Start.DisplayName
	}
}

function Get-AdmxContext {
	param(
		[IO.FileInfo]$AdmxFile
	)
	$Admx = [Xml](Get-Content -Path $AdmxFile.Fullname -Raw)

	$Namespaces = @{}
	if($Admx.PolicyDefinitions.PolicyNamespaces.Using) {
		$Admx.PolicyDefinitions.PolicyNamespaces.Using | %{
			Write-Debug "Defining namespace $($_.Prefix) = $($_.Namespace)"
			$Namespaces[$_.prefix] = $_.Namespace
		}
	}

	[PsCustomObject]@{
		Namespaces = $Namespaces
		Xml = $Admx
		Strings = (Get-AdmxStrings -AdmxFile $AdmxFile)
		Namespace = $Admx.PolicyDefinitions.PolicyNamespaces.Target.Namespace
	}
}

<#
.DESCRIPTION
	Parses the ADMX files and returns the categories the policy templates are grouped into. Use this to find a string 

.PARAMETER Local
	Switch parameter that tells the cmdlet to operate on the ADMX files in the local store. This is the default option.

.PARAMETER Domain
	Switch parameter that tells the cmdlet to operate on the ADMX files in the domain's central store.
	
	If the DomainName parameter is not specified, the current computer's domain is assumed.

.PARAMETER DomainName
	The fully qualified domain name to use to build the path to the central store.

.EXAMPLE
	Get-AdmxCategory -Local
	
	Id                                                 DisplayName      Parent
	--                                                 -----------      ------
	Microsoft.Policies.Globalization.NlsManagementCat  Locale Services  Microsoft.Policies.Windows.System (System)
	Microsoft.Policies.WindowsDefender.ClientInterface Client Interface Microsoft.Policies.WindowsDefender.AntiSpy...
	Microsoft.Policies.Windows.Printers                Printers

	
	This lists all the categories defined in the ADMX templates on the local machine.  The DisplayName property is the localized name that is displayed in the Group Policy management GUI and can be used to filter policies using: Get-AdmxPolicyTemplate | ?{$_.Category.DisplayName -eq "Printers"}
#>
function Get-AdmxCategory {
	[CmdletBinding(DefaultParameterSetName="Local")]
	param(
		[Parameter(ParameterSetName="Local")]
		[Switch]$Local,

		[Parameter(ParameterSetName="Domain")]
		[Switch]$Domain,

		[Parameter(ParameterSetName="Domain")]
		[String]$DomainName
	)
	if($PsCmdlet.ParameterSetName -eq "Local") {
		$Folder = Resolve-AdmxTemplatePath -Local
	} else {
		$DomainParams = @{}
		if($DomainName) {
			$DomainParams.Add("DomainName", $DomainName)
		}
		$Folder = Resolve-AdmxTemplatePath -Domain @DomainParams
	}

	#Test the folder path and throw an error if it doesn't exist
	if(!(Test-Path -Path $Folder)) {
		throw "Cannot locate policy files at $Folder"
	}

	$Categories = @{}
	dir (Join-Path -Path $Folder -ChildPath "*.admx") | %{
		Write-Debug "Parsing file $($_.Fullname)"
		$Strings = Get-AdmxStrings -AdmxFile $_.Fullname
		$ExpandedXml = Get-Content -Path $_.Fullname -Raw
		try {
			$Admx = [xml]($ExpandedXml)
			$Target = $Admx.PolicyDefinitions.PolicyNamespaces.Target
			$Namespaces = @{}
			if($Admx.PolicyDefinitions.PolicyNamespaces.Using) {
				$Admx.PolicyDefinitions.PolicyNamespaces.Using | %{
					Write-Debug "Defining namespace $($_.Prefix) = $($_.Namespace)"
					$Namespaces[$_.prefix] = $_.Namespace
				}
			}

			if($Admx.PolicyDefinitions.Categories) {
				$Admx.PolicyDefinitions.Categories.Category | %{
					$ParentRef = $_.ParentCategory.Ref
					if($ParentRef) {
						$ParentRefSplit = $ParentRef.Split(":")
						if($ParentRefSplit.Length -eq 2) {
							$ParentRef = $Namespaces[$ParentRefSplit[0]] + "." + $ParentRefSplit[1]
						} else {
							$ParentRef = $Target.Namespace + "." + $ParentRefSplit[0]
						}
					}
					$QualifiedName = "$($Target.Namespace).$($_.Name)"
					$Categories[$QualifiedName] = [PSCustomObject]@{
						Id = $QualifiedName
						DisplayName = { $ExecutionContext.InvokeCommand.ExpandString($_.DisplayName)}.InvokeWithContext($Strings, $null, $null)[0]
						Parent = $ParentRef
					} | Add-Member -Name ToString -MemberType ScriptMethod -Value { "$($This.Id) ($($This.DisplayName))" } -PassThru -Force
				}
			}
		} catch {
			Write-Error -Message "Error parsing file" -TargetObject $ExpandedXml -Exception $_.Exception
		}
	}
	$Categories.Values | %{
		if($_.parent) {
			$_.Parent = $Categories[$_.Parent]
		}
	}
	$Categories.Values
}
Export-ModuleMember -Function Get-AdmxCategory

<#
.DESCRIPTION
	Parses the ADMX files and returns the registry information that each policy sets.  Use this to locate a policy using the display name as seen in the GUI and then discover the registry keys that are set by the policy for use with Get/Set-GPRegistryValue in the GroupPolicy module.

.PARAMETER Local
	Switch parameter that tells the cmdlet to operate on the ADMX files in the local store. This is the default option.

.PARAMETER Domain
	Switch parameter that tells the cmdlet to operate on the ADMX files in the domain's central store.
	
	If the DomainName parameter is not specified, the current computer's domain is assumed.

.PARAMETER DomainName
	The fully qualified domain name to use to build the path to the central store.

.PARAMETER Class
	The type of policies to return, either Machine, User, or Both.  If not specified all policies are returned.

.EXAMPLE
	Get-AdmxPolicyTemplate -Local -Class User
	
	SourceFile  : C:\Windows\PolicyDefinitions\AppCompat.admx
	Id          : AppCompatTurnOffProgramCompatibilityAssistant_1
	Class       : User
	Displayname : Turn off Program Compatibility Assistant
	Category    : Microsoft.Policies.ApplicationCompatibility.AppCompat (Application Compatibility)
	Path        : Windows Components\Application Compatibility
	Key         : Software\Policies\Microsoft\Windows\AppCompat
	ValueName   : DisablePCA
	
	This lists out all the User policies in the templates on the local machine.

.EXAMPLE
	Get-AdmxPolicyTemplate -Local | Where-Object { $_.DisplayName -eq "Enable client-side targeting" }
	
	SourceFile  : C:\Windows\PolicyDefinitions\WindowsUpdate.admx
	Id          : TargetGroup_Title
	Class       : Machine
	Displayname : Enable client-side targeting
	Category    : Microsoft.Policies.WindowsUpdate.WindowsUpdateCat (Windows Update)
	Path        : Windows Components\Windows Update
	Key         : Software\Policies\Microsoft\Windows\WindowsUpdate
	ValueName   : TargetGroup
	
	This finds the group policy template that is displayed in the GUI with a localized name of "Enable client-side targeting".

.EXAMPLE
	Get-AdmxPolicyTemplate | ?{$_.Category.DisplayName -eq "Windows Update"}
	
	SourceFile  : C:\Windows\PolicyDefinitions\WindowsUpdate.admx
	Id          : AUDontShowUasPolicy
	Class       : Both
	Displayname : Do not display 'Install Updates and Shut Down' option in Shut Down Windows dialog box
	Category    : Microsoft.Policies.WindowsUpdate.WindowsUpdateCat (Windows Update)
	Path        : Windows Components\Windows Update
	Key         : Software\Policies\Microsoft\Windows\WindowsUpdate\AU
	ValueName   : NoAUShutdownOption

	SourceFile  : C:\Windows\PolicyDefinitions\WindowsUpdate.admx
	Id          : AUNoUasDefaultPolicy_User
	Class       : User
	Displayname : Do not adjust default option to 'Install Updates and Shut Down' in Shut Down Windows dialog box
	Category    : Microsoft.Policies.WindowsUpdate.WindowsUpdateCat (Windows Update)
	Path        : Windows Components\Windows Update
	Key         : Software\Policies\Microsoft\Windows\WindowsUpdate\AU
	ValueName   : NoAUAsDefaultShutdownOption
	
	This will list all of the policy templates that are in the group with a localized name of "Windows Update"
#>
function Get-AdmxPolicyTemplate {
	[CmdletBinding(DefaultParameterSetName="Local")]
	param(
		[Parameter(ParameterSetName="Local")]
		[Switch]$Local,

		[Parameter(ParameterSetName="Domain")]
		[Switch]$Domain,

		[Parameter(ParameterSetName="Domain")]
		[String]$DomainName,

		[ValidateSet("Machine","User","Both")]
		[String]$Class
	)
	$CommonParameters = @{}
	if($PsCmdlet.ParameterSetName -eq "Local") {
		$CommonParameters.Add("Local", $true)
	} else {
		$CommonParameters.Add("Domain", $true)
		if($DomainName) {
			$CommonParameters.Add("DomainName", $DomainName)
		}
	}
	$Folder = Resolve-AdmxTemplatePath @CommonParameters

	#Test the folder path and throw an error if it doesn't exist
	if(!(Test-Path -Path $Folder)) {
		throw "Cannot locate policy files at $Folder"
	}
	$Categories = @{}
	Get-AdmxCategory @CommonParameters | %{
		$Categories.Add($_.ID, $_)
	}

	$PolicyAttributeFilters = @()
	if($Class) {
		$PolicyAttributeFilters += "@class='$Class'"
	}

	$XPath = "/{0}policyDefinitions/{0}policies/{0}policy"
	if($PolicyAttributeFilters) {
		$XPath += "[" + ($PolicyAttributeFilters -join " and ") + "]"
	}

	dir (Join-Path -Path $Folder -ChildPath "*.admx") | %{
		$File = $_
		$Ctx = Get-AdmxContext -AdmxFile $_
		$Admx = $Ctx.Xml
		$Strings = $Ctx.Strings
		#We need to splat the Namespace parameter because an empty namespace table is not allowed
		if($Admx.PolicyDefinitions.xmlns) {
			$Prefix = "gpo:"
			$Namespace = @{Namespace = @{ "gpo" = $Admx.PolicyDefinitions.xmlns }}
		} else {
			$Prefix = ""
			$Namespace = @{}
		}
		Select-Xml -XPath ($XPath -f $Prefix) @Namespace -Xml $Admx | %{ $_.Node} | %{
			if($_.ParentCategory.Ref) {
				$CategorySplit = $_.ParentCategory.Ref.Split(":")
				if($CategorySplit.Length -eq 2) {
					$CategoryId = $Ctx.Namespaces[$CategorySplit[0]] + "." + $CategorySplit[1]
				} else {
					$CategoryId = $Ctx.Namespace + "." + $CategorySplit[0]
				}
			}
			if($_.elements) {
				$ValueName = Select-Xml -XPath "*[@valueName]" -Xml $_.Elements | %{ $_.Node.ValueName}
			} else {
				$ValueName = $_.ValueName
			}
			[PSCustomObject]@{
				SourceFile = $File.Fullname
				Id = $_.Name
				Class = $_.Class
				Displayname = { $ExecutionContext.InvokeCommand.ExpandString($_.DisplayName) }.InvokeWithContext($Strings, $null, $null)[0]
				Category = $Categories[$CategoryId]
				Path = WalkDisplayPath -Start $Categories[$CategoryId]
				Key = $_.Key
				ValueName = $ValueName
			}
		}
	}
}
Export-ModuleMember -Function Get-AdmxPolicyTemplate