$Global:CredsRepo = @()

<## This function receives the path to a DSC module, and a parameter name. It then returns the type associated with the parameter (int, string, etc.). #>
function Get-DSCParamType
{
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [System.String] $ModulePath,
        [parameter(Mandatory = $true)] [System.String] $ParamName
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref] $tokens, [ref] $errors)
    $functions = $ast.FindAll( {$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true)

    $functions | ForEach-Object{
        if ($_.Name -eq "Set-TargetResource")
        {
            $functionAst = [System.Management.Automation.Language.Parser]::ParseInput($_.Body, [ref] $tokens, [ref] $errors)

            $parameters = $functionAst.FindAll( {$args[0] -is [System.Management.Automation.Language.ParameterAst]}, $true)
            $parameters | ForEach-Object{
                if ($_.Name.Extent.Text -eq $ParamName)
                {
                    $attributes = $_.Attributes
                    $attributes | ForEach-Object{
                        if ($_.TypeName.FullName -like "System.*")
                        {
                            return $_.TypeName.FullName
                        }
                        elseif ($_.TypeName.FullName.ToLower() -eq "microsoft.management.infrastructure.ciminstance")
                        {
                            return "System.Collections.Hashtable"
                        }
                        elseif ($_.TypeName.FullName.ToLower() -eq "string")
                        {
                            return "System.String"
                        }
                        elseif ($_.TypeName.FullName.ToLower() -eq "boolean")
                        {
                            return "System.Boolean"
                        }
                        elseif ($_.TypeName.FullName.ToLower() -eq "bool")
                        {
                            return "System.Boolean"
                        }
                        elseif ($_.TypeName.FullName.ToLower() -eq "string[]")
                        {
                            return "System.String[]"
                        }
                        elseif ($_.TypeName.FullName.ToLower() -eq "microsoft.management.infrastructure.ciminstance[]")
                        {
                            return "Microsoft.Management.Infrastructure.CimInstance[]"
                        }
                    }
                }
            }
        }
     }
     return $null
 }


<## This function loops through a HashTable and returns a string that combines all the Key/Value pairs into a DSC param block. #>
function Get-DSCBlock
{
    [CmdletBinding()]
    param(
        [System.String] $ModulePath,
        [System.Collections.Hashtable] $Params,
        [switch] $UseGetTargetResource = $false
    )

    $Sorted = $Params.GetEnumerator() | Sort-Object -Property Name
    $NewParams = [Ordered]@{}

    foreach($entry in $Sorted)
    {
        $NewParams.Add($entry.Key, $entry.Value)
    }

    # Figure out what parameter has the longuest name, and get its Length;
    $maxParamNameLength = 0
    foreach ($param in $NewParams.Keys)
    {
        if ($param.Length -gt $maxParamNameLength)
        {
            $maxParamNameLength = $param.Length
        }
    }

    # PSDscRunAsCredential is 20 characters and in most case the longuest.
    if ($maxParamNameLength -lt 20)
    {
        $maxParamNameLength = 20
    }

    $dscBlock = ""
    $NewParams.Keys | ForEach-Object {
        if ($UseGetTargetResource)
        {
            $paramType = Get-DSCParamType -ModulePath $ModulePath -ParamName "`$$_"
        }
        else
        {
            if ($null -ne $NewParams[$_])
            {
                $paramType = $NewParams[$_].GetType().Name
            }
            else
            {
                $paramType = Get-DSCParamType -ModulePath $ModulePath -ParamName "`$$_"
            }
        }

        $value = $null
        if ($paramType -eq "System.String" -or $paramType -eq "String" -or $paramType -eq "Guid" -or $paramType -eq 'TimeSpan')
        {
            if (!$null -eq $NewParams.Item($_))
            {
                $value = "`"" + $NewParams.Item($_).ToString().Replace("`"", "```"") + "`""
            }
            else
            {
                $value = "`"" + $NewParams.Item($_) + "`""
            }
        }
        elseif ($paramType -eq "System.Boolean" -or $paramType -eq "Boolean")
        {
            $value = "`$" + $NewParams.Item($_)
        }
        elseif ($paramType -eq "System.Management.Automation.PSCredential")
        {
            if ($null -ne $NewParams.Item($_))
            {
                if ($NewParams.Item($_).ToString() -like "`$Creds*")
                {
                    $value = $NewParams.Item($_).Replace("-", "_").Replace(".", "_")
                }
                else
                {
                    if ($null -eq $NewParams.Item($_).UserName)
                    {
                        $value = "`$Creds" + ($NewParams.Item($_).Split('\'))[1].Replace("-", "_").Replace(".", "_")
                    }
                    else
                    {
                        if ($NewParams.Item($_).UserName.Contains("@") -and !$NewParams.Item($_).UserName.COntains("\"))
                        {
                            $value = "`$Creds" + ($NewParams.Item($_).UserName.Split('@'))[0]
                        }
                        else
                        {
                            $value = "`$Creds" + ($NewParams.Item($_).UserName.Split('\'))[1].Replace("-", "_").Replace(".", "_")
                        }
                    }
                }
            }
            else
            {
                $value = "Get-Credential -Message " + $_
            }
        }
        elseif ($paramType -eq "System.Collections.Hashtable" -or $paramType -eq "Hashtable")
        {
            $value = "@{"
            $hash = $NewParams.Item($_)
            $hash.Keys | foreach-object {
                try
                {
                    $value += $_ + " = `"" + $hash.Item($_) + "`"; "
                }
                catch
                {
                    $value = $hash
                }
            }
            $value += "}"
        }
        elseif ($paramType -eq "System.String[]" -or $paramType -eq "String[]" -or $paramType -eq "ArrayList" -or $paramType -eq "List``1")
        {
            $hash = $NewParams.Item($_)
            if ($hash -and !$hash.ToString().StartsWith("`$ConfigurationData."))
            {
                $value = "@("
                $hash| ForEach-Object {
                    $value += "`"" + $_ + "`","
                }
                if($value.Length -gt 2)
                {
                    $value = $value.Substring(0,$value.Length -1)
                }
                $value += ")"
            }
            else
            {
                if ($hash)
                {
                    $value = $hash
                }
                else
                {
                    $value = "@()"
                }
            }
        }
        elseif ($paramType -eq "System.UInt32[]")
        {
            $hash = $NewParams.Item($_)
            if ($hash)
            {
                $value = "@("
                $hash| ForEach-Object {
                    $value += $_.ToString() + ","
                }
                if($value.Length -gt 2)
                {
                    $value = $value.Substring(0,$value.Length -1)
                }
                $value += ")"
            }
            else
            {
                if ($hash)
                {
                    $value = $hash
                }
                else
                {
                    $value = "@()"
                }
            }
        }
        elseif ($paramType -eq "Object[]" -or $paramType -eq "Microsoft.Management.Infrastructure.CimInstance[]")
        {
            $array = $hash = $NewParams.Item($_)

            if ($array.Length -gt 0 -and ($array[0].GetType().Name -eq "String" -and $paramType -ne "Microsoft.Management.Infrastructure.CimInstance[]"))
            {
                $value = "@("
                $hash| ForEach-Object {
                    $value += "`"" + $_ + "`","
                }
                if($value.Length -gt 2)
                {
                    $value = $value.Substring(0,$value.Length -1)
                }
                $value += ")"
            }
            else
            {
                $value = "@("
                $array | ForEach-Object{
                    $value += $_
                }
                $value += ")"
            }
        }
        elseif ($paramType -eq "CimInstance")
        {
            $value = $NewParams[$_]
        }
        else
        {
            if ($null -eq $NewParams[$_])
            {
                $value = "`$null"
            }
            else
            {
                if($NewParams[$_].GetType().BaseType.Name -eq "Enum")
                {
                    $value = "`"" + $NewParams.Item($_) + "`""
                }
                else
                {
                    $value = $NewParams.Item($_)
                }
            }
        }

        # Determine the number of additional spaces we need to add before the '=' to make sure the values are all aligned. This number
        # is obtained by substracting the length of the current parameter's name to the maximum length found.
        $numberOfAdditionalSpaces = $maxParamNameLength - $_.Length
        $additionalSpaces = ""
        for ($i = 0; $i -lt $numberOfAdditionalSpaces; $i++)
        {
            $additionalSpaces += " "
        }
        $dscBlock += "            " + $_  + $additionalSpaces + " = " + $value + ";`r`n"
    }

    return $dscBlock
}

<## This function generates an empty hash containing fakes values for all input parameters of a Get-TargetResource function. #>
function Get-DSCFakeParameters{
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [System.String] $ModulePath
    )

    $params = @{}

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref] $tokens, [ref] $errors)
    $functions = $ast.FindAll( {$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true)

    $functions | ForEach-Object{

        if ($_.Name -eq "Get-TargetResource")
        {
            $functionAst = [System.Management.Automation.Language.Parser]::ParseInput($_.Body, [ref] $tokens, [ref] $errors)

            $parameters = $functionAst.FindAll( {$args[0] -is [System.Management.Automation.Language.ParameterAst]}, $true)
            $parameters | ForEach-Object{
                $paramName = $_.Name.Extent.Text
                $attributes = $_.Attributes
                $found = $false

                <# Loop once to figure out if there is a validate Set to use. #>
                $attributes | ForEach-Object{
                    if ($_.TypeName.FullName -eq "ValidateSet")
                    {
                        $params.Add($paramName.Replace("`$", ""), $_.PositionalArguments[0].ToString().Replace("`"", "").Replace("'",""))
                        $found = $true
                    }
                    elseif ($_.TypeName.FullName -eq "ValidateRange") {
                        $params.Add($paramName.Replace("`$", ""), $_.PositionalArguments[0].ToString())
                        $found = $true
                    }
                }
                $attributes | ForEach-Object{
                    if (!$found)
                    {
                        if ($_.TypeName.FullName -eq "System.String" -or $_.TypeName.FullName -eq "String")
                        {
                            $params.Add($paramName.Replace("`$", ""), "*")
                            $found = $true
                        }
                        elseif ($_.TypeName.FullName -eq "System.UInt32" -or $_.TypeName.FullName -eq "Int32")
                        {
                            $params.Add($paramName.Replace("`$", ""), 0)
                            $found = $true
                        }
                        elseif ($_.TypeName.FullName -eq "System.Management.Automation.PSCredential")
                        {
                            $params.Add($paramName.Replace("`$", ""), $null)
                            $found = $true
                        }
                        elseif ($_.TypeName.FullName -eq "System.Management.Automation.Boolean" -or $_.TypeName.FullName -eq "System.Boolean" -or $_.TypeName.FullName -eq "Boolean")
                        {
                            $params.Add($paramName.Replace("`$", ""), $true)
                            $found = $true
                        }
                        elseif ($_.TypeName.FullName -eq "System.String[]" -or $_.TypeName.FullName -eq "String[]")
                        {
                            $params.Add($paramName.Replace("`$", ""),[string]@("1","2"))
                            $found = $true
                        }
                    }
                }
            }
        }
     }
     return $params
}

function Get-DSCDependsOnBlock($dependsOnItems)
{
    $dependsOnClause = "@("
    foreach ($clause in $dependsOnItems)
    {
        $dependsOnClause += "`"" + $clause + "`","
    }
    $dependsOnClause = $dependsOnClause.Substring(0, $dependsOnClause.Length -1)
    $dependsOnClause += ");"
    return $dependsOnClause
}

function Export-TargetResource()
{
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [System.String] $ResourceName,
        [parameter(Mandatory = $true)] [System.Collections.Hashtable] $MandatoryParameters,
        [parameter(Mandatory = $false)] [System.String] $DependsOnClause
    )
    $ModulePath = (Get-DscResource $ResourceName | select-object Path).Path.ToString()
    $friendlyName = Get-ResourceFriendlyName -ModulePath $ModulePath
    $fakeParameters = Get-DSCFakeParameters -ModulePath $ModulePath

    <# Nik20170109 - Replace each Fake Parameter by the ones received as function arguments #>
    $finalParams = @{}
    foreach ($fakeParameter in $fakeParameters.Keys)
    {
        if ($MandatoryParameters.ContainsKey($fakeParameter))
        {
            $finalParams.Add($fakeParameter,$MandatoryParameters.Get_Item($fakeParameter))
        }
    }

    Import-Module $ModulePath
    $results = Get-TargetResource @finalParams

    $DSCBlockParams = @{}
    foreach ($fakeParameter in $fakeParameters.Keys)
    {
        if ($results[$fakeParameter])
        {
            $DSCBlockParams.Add($fakeParameter,$results.Get_Item($fakeParameter))
        }
        else
        {
            $DSCBlockParams.Add($fakeParameter,"")
        }
    }

    $exportContent = "        " + $ResourceName + " " + [System.Guid]::NewGuid().ToString() + "`r`n"
    $exportContent += "        {`r`n"
    $exportContent += Get-DSCBlock -ModulePath $ModulePath -Params $DSCBlockParams
    if ($null -ne $DependsOnClause)
    {
        $exportContent += $DependsOnClause
    }
    $exportContent += "        }`r`n"
    return $exportContent
}

function Get-ResourceFriendlyName
{
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [System.String] $ModulePath
    )

    $tokens = $null
    $errors = $null
    $schemaPath = $ModulePath.Replace(".psm1", ".schema.mof")
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($schemaPath, [ref] $tokens, [ref] $errors)

    for ($i = 0; $i -lt $tokens.Length; $i++)
    {
        if ($tokens[$i].Text.ToLower() -eq "friendlyname" -and ($i+2) -le $tokens.Length)
        {
            return $tokens[$i+2].Text.Replace("`"", "")
        }
    }
    return $null
}

<# Region Helper Methods #>
function Get-Credentials([string] $UserName)
{
    if ($Global:CredsRepo.Contains($UserName.ToLower()))
    {
        return $UserName.ToLower()
    }
    return $null
}

function Resolve-Credentials([string] $UserName)
{
    $userNameParts = $UserName.ToLower().Split('\')
    if ($userNameParts.Length -gt 1)
    {
        return "`$Creds" + $userNameParts[1].Replace("-","_").Replace(".", "_").Replace(" ", "").Replace("@","")
    }
    return "`$Creds" + $UserName.Replace("-","_").Replace(".", "_").Replace(" ", "").Replace("@","")
}

function Save-Credentials([string] $UserName)
{
    if (!$Global:CredsRepo.Contains($UserName.ToLower()))
    {
        $Global:CredsRepo += $UserName.ToLower()
    }
}

function Test-Credentials([string] $UserName)
{
    if ($Global:CredsRepo.Contains($UserName.ToLower()))
    {
        return $true
    }
    return $false
}

function Convert-DSCStringParamToVariable([string]$DSCBlock, [string]$ParameterName, [boolean]$ISCIMArray)
{
    # There is a possibility that a parameter's value will contain the name of the property
# or that another property will contain a subset of it.
$startPosition = $DSCBlock.IndexOf("$ParameterName")

# If quotes appear before an equal sign, when starting from the assumed start position,
# then the start position is invalid, searhc for another instance of the Parameter;
$startPosition = -1
do
{
    $startPosition = $DSCBlock.IndexOf("$ParameterName", $startPosition + 1)
    $testValidStartPositionEqual = $DSCBlock.IndexOf("=", $startPosition)
    $testValidStartPositionQuotes = $DSCBlock.IndexOf("`"", $startPosition)
} while ($testValidStartPositionEqual -gt $testValidStartPositionQuotes -and 
         $startPosition -ne -1)

    $endOfLinePosition = $DSCBlock.IndexOf(";`r`n", $startPosition)

    if ($endOfLinePosition -eq -1)
    {
        $endOfLinePosition = $DSCBlock.Length
    }
    $startPosition = $DSCBlock.IndexOf("`"", $startPosition)

    while ($startPosition -ge 0 -and $startPosition -lt $endOfLinePosition)
    {
        if ($endOfLinePosition -gt $startPosition)
        {
            if ($startPosition -ge 0)
            {
                $endPosition = $DSCBlock.IndexOf("`"", $startPosition + 1)
                if ($endPosition -lt 0)
                {
                    $endPosition = $DSCBlock.IndexOf("'", $startPosition + 1)
                }

                if ($endPosition -ge 0 -and $endPosition -le $endofLinePosition)
                {
                    $DSCBlock = $DSCBlock.Remove($startPosition, 1)
                    $DSCBlock = $DSCBlock.Remove($endPosition-1, 1)
                }
                else
                {
                    $startPosition = -1
                }
            }
        }
        $startPosition = $DSCBlock.IndexOf("`"", $startPosition)
    }

    if($IsCIMArray)
    {
        $DSCBlock = $DSCBlock.Replace("}`r`n,", "`}`r`n")
    }
    return $DSCBlock
}

<# Region ConfigurationData Methods #>
$ConfigurationDataContent = @{}

function Add-ConfigurationDataEntry($Node, $Key, $Value, $Description)
{
    if ($null -eq $ConfigurationDataContent[$Node])
    {
        $ConfigurationDataContent.Add($Node, @{})
        $ConfigurationDataContent[$Node].Add("Entries", @{})
    }
    if (!$ConfigurationDataContent[$Node].Entries.ContainsKey($Key))
    {
        $ConfigurationDataContent[$Node].Entries.Add($Key, @{Value = $Value; Description = $Description})
    }
}

function Get-ConfigurationDataEntry($Node, $Key)
{
    <# If node is null, then search in all nodes and return first result found. #>
    if ($null -eq $Node)
    {
        foreach ($Node in $ConfigurationDataContent.Keys)
        {
            if ($ConfigurationDataContent[$Node].Entries.ContainsKey($Key))
            {
                return $ConfigurationDataContent[$Node].Entries[$Key]
            }
        }
    }
    else
    {
        if ($ConfigurationDataContent[$Node].Entries.ContainsKey($Key))
        {
            return $ConfigurationDataContent[$Node].Entries[$Key]
        }
    }
}

function Get-$ConfigurationDataContent
{
    $psd1Content = "@{`r`n"
    $psd1Content += "    AllNodes = @(`r`n"
    foreach ($node in $ConfigurationDataContent.Keys.Where{$_.ToLower() -ne "nonnodedata"})
    {
        $psd1Content += "        @{`r`n"
        $psd1Content += "            NodeName                    = `"" + $node + "`"`r`n"
        $psd1Content += "            PSDscAllowPlainTextPassword = `$true;`r`n"
        $psd1Content += "            PSDscAllowDomainUser        = `$true;`r`n"
        $psd1Content += "            # CertificateFile           = `"\\<location>\<file>.cer`";`r`n"
        $psd1Content += "            # Thumbprint                = `xxxxxxxxxxxxxxxxxxxxxxx`r`n`r`n"
        $psd1Content += "            #region Parameters`r`n"
        $keyValuePair = $ConfigurationDataContent[$node].Entries
        foreach ($key in $keyValuePair.Keys)
        {
            if ($null -ne $keyValuePair[$key].Description)
            {
                $psd1Content += "            # " + $keyValuePair[$key].Description +  "`r`n"
            }
            if ($keyValuePair[$key].Value.ToString().StartsWith("@(") -or $keyValuePair[$key].Value.ToString().StartsWith("`$"))
            {
                $psd1Content += "            " + $key + " = " + $keyValuePair[$key].Value + "`r`n`r`n"
            }
            elseif ($keyValuePair[$key].Value.GetType().FullName -eq "System.Object[]")
            {
                $psd1Content += "            " + $key + " = " + (ConvertTo-ConfigurationDataString $keyValuePair[$key].Value)
            }
            else
            {
                $psd1Content += "            " + $key + " = `"" + $keyValuePair[$key].Value + "`"`r`n`r`n"
            }
        }

        $psd1Content += "        },`r`n"
    }

    if ($psd1Content.EndsWith(",`r`n"))
    {
        $psd1Content = $psd1Content.Remove($psd1Content.Length-3, 1)
    }

    $psd1Content += "    )`r`n"
    $psd1Content += "    NonNodeData = @(`r`n"
    foreach ($node in $ConfigurationDataContent.Keys.Where{$_.ToLower() -eq "nonnodedata"})
    {
        $psd1Content += "        @{`r`n"
        $keyValuePair = $ConfigurationDataContent[$node].Entries
        foreach ($key in $keyValuePair.Keys)
        {
            try
            {
                $value = $keyValuePair[$key].Value
                $valType = $value.GetType().FullName

                if ($valType -eq "System.Object[]")
                {
                    $newValue = "@("
                    foreach ($item in $value)
                    {
                        $newValue += "`"" + $item + "`","
                    }
                    $newValue = $newValue.Substring(0,$newValue.Length -1)
                    $newValue += ")"
                    $value = $newValue
                }
            
                if ($null -ne $keyValuePair[$key].Description)
                {
                    $psd1Content += "            # " + $keyValuePair[$key].Description +  "`r`n"
                }
                if ($value.StartsWith("@(") -or $value.StartsWith("`$"))
                {
                    $psd1Content += "            " + $key + " = " + $value + "`r`n`r`n"
                }
                else
                {
                    $psd1Content += "            " + $key + " = `"" + $value + "`"`r`n`r`n"
                }
            }
            catch {
                Write-Host "Warning: Could not obtain value for key $key" -ForegroundColor Yellow
            }
        }
        $psd1Content += "        }`r`n"
    }
    if($psd1Content.EndsWith(",`r`n"))
    {
        $psd1Content = $psd1Content.Remove($psd1Content.Length-3, 1)
    }
    $psd1Content += "    )`r`n"
    $psd1Content += "}"
    return $psd1Content
}

function New-ConfigurationDataDocument($Path)
{
    Get-$ConfigurationDataContent | Out-File -FilePath $Path
}

function ConvertTo-ConfigurationDataString($PSObject)
{
    $configDataContent = ""
    $objectType = $PSObject.GetType().FullName
    switch ($objectType)
    {
        "System.String"
        {
            $configDataContent += "`"" + $PSObject + "`";`r`n"
        }
        "System.Object[]"
        {
            $configDataContent += "            @(`r`n"
            foreach ($entry in $PSObject)
            {
                $configDataContent += ConvertTo-ConfigurationDataString $entry
            }
            if ($configDataContent.EndsWith(",`r`n"))
            {
                $configDataContent = $configDataContent.Remove($configDataContent.Length-3, 1)
            }
            $configDataContent += "            )`r`n"
        }

        "System.Collections.Hashtable"
        {
            $configDataContent += "            @{`r`n"
            foreach ($key in $PSObject.Keys)
            {
                $configDataContent += "                " + $key + " = "
                $configDataContent += ConvertTo-ConfigurationDataString $PSObject[$key]
            }
            $configDataContent += "            },`r`n"
        }
    }
    return $configDataContent
}

<# Region User based Methods #>
$Global:AllUsers = @()

function Add-ReverseDSCUserName($UserName)
{
    if (!$Global:AllUsers.Contains($UserName))
    {
        $Global:AllUsers += $UserName
    }
}
