param (
    $in_xml = ".\win_dhcp.xml",               # Windows DHCP backup xml file
    $in_template = "kea-dhcp4.template.json", # Например /etc/kea-dhcp4.conf
    $out_confdir = ".\kea",                   # куда сохранить конвертированный конфиг /etc/kea
    $split  = "none",                          # поместить в отдельный файл конфигурации subnets, options, reservations в папку /etc/kea/conf.d
    $out_dhcp4_conf = "$($out_confdir)\kea-dhcp4.conf.json",
    $out_confd = "$($out_confdir)\conf.d"
)
# значение для путей в файле конфигурации
$kea_confd = "/etc/kea/conf.d"

switch ($split) {
    "subnets"      { $split_subnets = $true;  $split_reservations = $false; $split_options = $false; break }
    "reservations" { $split_subnets = $false; $split_reservations = $true;  $split_options = $false; break }
    "options"      { $split_subnets = $false; $split_reservations = $false; $split_options = $true;  break }
    "all"          { $split_subnets = $true;  $split_reservations = $true;  $split_options = $true;  break }
    "none"         { $split_subnets = $false; $split_reservations = $false; $split_options = $false; break }
    default        { $split_subnets = $false; $split_reservations = $false; $split_options = $false; write-host "Unknown option: $split, use default option - none"; }
}
# write-host "split: $split scopes: `$$plit_subnets reservations: `$$split_reservations"
function Convert-Subnetmask {
# конвертит маску подсети из 255.255.255.0 в /24
    [CmdLetBinding(DefaultParameterSetName='CIDR')]
    param( 
        [Parameter(ParameterSetName='CIDR',Position=0,Mandatory=$true,
            HelpMessage='CIDR like /24 without "/"')]
        [ValidateRange(0,32)][Int32]$CIDR,
        [Parameter(ParameterSetName='Mask',Position=0,Mandatory=$true,
            HelpMessage='Subnetmask like 255.255.255.0')]
        [ValidateScript({
            if($_ -match "^(254|252|248|240|224|192|128).0.0.0$|^255.(254|252|248|240|224|192|128|0).0.0$|^255.255.(254|252|248|240|224|192|128|0).0$|^255.255.255.(255|254|252|248|240|224|192|128|0)$") {
                return $true
            } else {
                throw "Enter a valid subnetmask (like 255.255.255.0)!"    
            }
        })][String]$Mask
    )
    Begin {}
    Process {
        switch($PSCmdlet.ParameterSetName) {
            "CIDR" {                          
                # Make a string of bits (24 to 11111111111111111111111100000000)
                $CIDR_Bits = ('1' * $CIDR).PadRight(32, "0")
                
                # Split into groups of 8 bits, convert to Ints, join up into a string
                $Octets = $CIDR_Bits -split '(.{8})' -ne ''
                $Mask = ($Octets | ForEach-Object -Process {[Convert]::ToInt32($_, 2) }) -join '.'
                Return $Mask
            }

            "Mask" {
                # Convert the numbers into 8 bit blocks, join them all together, count the 1
                $Octets = $Mask.ToString().Split(".") | ForEach-Object -Process {[Convert]::ToString($_, 2)}
                $CIDR_Bits = ($Octets -join "").TrimEnd("0")

                # Count the "1" (111111111111111111111111 --> /24)                     
                $CIDR = $CIDR_Bits.Length
                Return $CIDR
            }               
        }
    }
    End {}
}
function IncreaseIP {
# изменяет адрес на значение в inc
# ip=192.168.126.134 inc=-1 result=192.168.126.133
# ip=192.168.126.170 inc=1 result=192.168.126.171
    Param
    (
         [Parameter(Mandatory=$true, Position=0)]
         [string] $ip,
         [Parameter(Mandatory=$false, Position=1)]
         [int] $inc
    )
    $tmpIP = ([IPAddress]$ip).GetAddressBytes()
    [Array]::Reverse($tmpIP)
    $tmpIP = ([IPAddress](([IPAddress]$tmpIP).Address + $inc)).GetAddressBytes()
    [Array]::Reverse($tmpIP)
    $tmpIP = $tmpIP -join(".")
    Return $tmpIP
}
function Convert-Pools {
# конвертирует диапазоны исключений в пулы без адресов из диапазонов
    Param (
        [Parameter(Mandatory=$true, Position=0)][string]$ScopeStartRange,
        [Parameter(Mandatory=$true, Position=1)][string]$ScopeEndRange,
        [Parameter(Mandatory=$false, Position=2)][array]$ScopeExclusionRanges
    )
    [Collections.ArrayList]$pools_list = @()
    if ($ScopeExclusionRanges) {
        $sorted = $ScopeExclusionRanges | Sort-Object { 
            $octets = $_.StartRange -split '\.'
            [int]$octets[3]
        }
        $PoolStartIP = $ScopeStartRange
        foreach ($Range in $sorted) {
            $PoolEndIP = IncreaseIP -ip $Range.StartRange -inc -1
            if ([int]($PoolEndIP -split '\.')[3] -gt [int]($ScopeEndRange -split '\.')[3]) { $PoolEndIP = $ScopeEndRange}
            #[void] или | Out-Null  нужно добавить чтобы в массиве не появлялись индексы элементов
            $pools_list.add(@{"pool"="$PoolStartIP - $PoolEndIP";}) | Out-Null
            $PoolStartIP = IncreaseIP -ip $Range.EndRange -inc +1
        }
        [void]$pools_list.add(@{"pool"="$PoolStartIP - $ScopeEndRange";})
    } else {
        [void]$pools_list.add(@{"pool"="$ScopeStartRange - $ScopeEndRange";})
    }
    Return $pools_list
}
function Convert-LeaseDuration {
    param( 
        [string]$leaseDuration
    )

    $textReformat = $leaseDuration.Replace( ",", ".")
    $seconds = ([TimeSpan]::Parse($textReformat)).TotalSeconds
    $days = [int]($seconds / 86400)
    $hours = [int]($seconds / 3600) % 24
    $minutes = [int]($seconds / 60) % 60
    $result = "lease " + [string]$days + " " + [string]$hours + " " + [string]$minutes
    return  $result
}
function Convert-Options {
# конвертирует опции по списку
    param(
        [Parameter(Mandatory=$true, Position=0)][array]$Options
    )
    [Collections.ArrayList]$options_list = @()

    foreach ($option in $Options) {
        switch ($option.OptionId) {
            3 { $options_list.add(@{code=3;data=$option.Value;name="routers";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break }
            # 4 { $options_list.add(@{code=4;data=($option.Value -join ",");name="";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } #Time Server, dont use
            5 { $options_list.add(@{code=5;data=($option.Value -join ",");name="name-servers";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break }
            6 { $options_list.add(@{code=6;data=($option.Value -join ",");name="domain-name-servers";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break }
            15 { $options_list.add(@{code=15;data=$option.Value;name="domain-name";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break }
            42 { $options_list.add(@{code=42;data=($option.Value -join ",");name="ntp-servers";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } # NTP Servers
            # 44 { $options_list.add(@{code=44;data=($option.Value -join ",");name="netbios-name-servers";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } # NETBIOS Name Servers
            # 46 { $options_list.add(@{code=46;data=($option.Value -join ",");name="netbios-node-type	";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } # NETBIOS Node Type
            51 { $options_list.add(@{code=51;data=$option.Value;name="dhcp-lease-time";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } #Lease time in seconds. Not Required
            66 { $options_list.add(@{code=66;data=$option.Value;name="tftp-server-name";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } #DAP TFTP Server to load boot config
            67 { $options_list.add(@{code=67;data=$option.Value;name="boot-file-name";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } #DAP Bootfile name see option 66                                          
            # 81 { $options_list.add(@{code=81;data=$option.Value;name="fqdn";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } #Client FQDN. Not Required
            119 { $options_list.add(@{code=119;data=($option.Value -join ",");name="domain-search";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break }
            # 161 { $options_list.add(@{code=161;data=$option.Value;name="";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } # OPTION_MUD_URL_V4
            # 162 { $options_list.add(@{code=162;data=$option.Value;name="";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break } # OPTION_V4_DNR
            # 242 { $options_list.add(@{code=242;data=$option.Value;name="";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break }
            # 252 { $options_list.add(@{code=252;data=$option.Value;name="";"always-send"=$true;"csv-format"=$true;"space"="dhcp4"}) | Out-Null; break }
            # default { Write-Host ($option.OptionId + ":`t " + $option.Value + "`t unknown option") }
            default {  }
        }
    }
    return  $options_list
}
function Convert-Reservations {
    param(
        [Parameter(Mandatory=$true, Position=0)]$reservations
    )
    [Collections.ArrayList]$reservations_list = @()
    foreach ($reservation in $reservations) {
        $mac = ($reservation.ClientId).Replace("-", ":")
        # | Out-Null т.к. если я тут использую [void] то вместо значений в массив попадают System.Xml.XmlElement.
        # если МАК слишком длинный, считаем что это client-id
        if ($mac.length -gt 17) {
            $hostid = "client-id"
        } else {
            $hostid = "hw-address"
        }
        $reservation_optiondata = @()
        if ($reservation.OptionValues.OptionValue) {
            $reservation_optiondata += (Convert-Options -Options $reservation.OptionValues.OptionValue)
            $reservations_list.add(@{
                "option-data"=$reservation_optiondata;
                "$hostid"=$mac;
                "ip-address"=$reservation.IPAddress;
                "hostname"=$reservation.Name;}) | Out-Null
        } else {
            $reservations_list.add(@{
                "$hostid"=$mac;
                "ip-address"=$reservation.IPAddress;
                "hostname"=$reservation.Name;}) | Out-Null
        }
    }
    return  $reservations_list
}
function Convert-Scope {
# конвертирует scope в subnet4
    param(
        [Parameter(Mandatory=$true, Position=0)]$scope
    )
    [Collections.ArrayList]$subnet = @()
    #  id: # формируем ID как 3 и 4 октеты адреса сети 
    $subnet_id=[int](($scope.ScopeId.split(".")[2,3]) -join '')
    #  subnet: # адрес подсети в CIDR формате
    $subnet_address=$scope.ScopeId + "/" + (Convert-Subnetmask -Mask $scope.SubnetMask)
    #  option-data: # опции
    $subnet_optiondata = @()
    if ($scope.OptionValues.OptionValue) {
        $subnet_optiondata += (Convert-Options -Options $scope.OptionValues.OptionValue)
    }
    #  pools: # конвертим диапазоны исключения в несколько пулов
    $subnet_pools = @()
    if ($scope.ExclusionRanges.IPRange) {
        $subnet_pools += (Convert-Pools -ScopeStartRange $scope.StartRange -ScopeEndRange $scope.EndRange -ScopeExclusionRanges $scope.ExclusionRanges.IPRange)
    } else {
        $subnet_pools += (Convert-Pools -ScopeStartRange $scope.StartRange -ScopeEndRange $scope.EndRange)
    }
    #  user-context:
    $subnet_usercontext = @{"description"=$scope.Name;"name"=$scope.Name;}

    #  reservations: # конвертим резервирования
    $subnet_reservations = @()
    if ($scope.Reservations.Reservation) {
        if ($script:split_reservations) {
            $reservations_file = "subnet4.$($scope.ScopeId).reservations.conf.json"
            $subnet_reservations += (Convert-Reservations -Reservations $scope.Reservations.Reservation)
            ConvertTo-Json -InputObject $subnet_reservations -Depth 10 | Foreach-Object {$_ -replace '"<','<'} | Foreach-Object {$_ -replace '>"','>'} | %{ $_.Replace("`r`n","`n") } | Out-File -Encoding ascii "$($out_confd)\$($reservations_file)"
            $subnet_reservations = "<?include `"/etc/kea/conf.d/$reservations_file`"?>"
        } else {
            $subnet_reservations = (Convert-Reservations -Reservations $scope.Reservations.Reservation)
        }
    }

    # $subnet | Add-Member -MemberType NoteProperty -Name "reservations" -Value $subnet_reservations
    # добавляем информацию о подсети в список
    # [void] или | Out-Null нужен чтобы в массив не попал вывод команды add
    $subnet.add(@{
        "id"=$subnet_id;
        "subnet"=$subnet_address;
        "pools"=$subnet_pools;
        "option-data"=$subnet_optiondata;
        "user-context"=$subnet_usercontext;
        "reservations"=$subnet_reservations;
    }) | Out-Null

    return $subnet
}
function Convert-Scopes {
    param(
        [Parameter(Mandatory=$true, Position=0)]$scopes
    )
    [Collections.ArrayList]$subnets_list = @()
    foreach ($scope in $scopes) {
        $subnets_list.add((Convert-Scope($scope))) | Out-Null
    }
    return $subnets_list
}

New-Item -ItemType Directory -Force -Path $out_confdir -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Force -Path $out_confd -ErrorAction SilentlyContinue | Out-Null

[XML]$win_dhcpconfig = Get-Content $in_xml

if ($in_template -eq "") {
    $keadhcp4 = "{`"Dhcp4`":{}}" | ConvertFrom-Json
} else {
    $keadhcp4 = Get-Content -Path $in_template -Raw | ConvertFrom-Json
}

# глобальные опции dhcp4.option-data:
$dhcp4_optiondata = (Convert-Options -Options $win_dhcpconfig.DHCPServer.IPv4.OptionValues.OptionValue)
if ($keadhcp4.Dhcp4.'option-data') {
    $keadhcp4.Dhcp4.'option-data' += $dhcp4_optiondata
} else {
    $keadhcp4.Dhcp4 | Add-Member -MemberType NoteProperty -Name "option-data" -Value $dhcp4_optiondata
}
# подсети dhcp4.subnet4
$dhcp4_subnet4 = (Convert-Scopes -Scopes $win_dhcpconfig.DHCPServer.IPv4.Scopes.Scope)
if ($keadhcp4.Dhcp4.Subnet4) {
    $keadhcp4.Dhcp4.Subnet4 += $dhcp4_subnet4
} else {
    $keadhcp4.Dhcp4 | Add-Member -MemberType NoteProperty -Name "Subnet4" -Value $dhcp4_subnet4
}
# сохраним dhcp4.option-data в отдельный файл
if ($split_options) {
    # $dhcp4_optiondata = @()
    # $dhcp4_optiondata += (Convert-Options -Options $win_dhcpconfig.DHCPServer.IPv4.OptionValues.OptionValue)
    $options_file = "option-data.conf.json"
    ConvertTo-Json -InputObject $keadhcp4.Dhcp4.'option-data' -Depth 10 | ForEach-Object { [regex]::Unescape($_) } | Foreach-Object {$_ -replace '"<','<'} | Foreach-Object {$_ -replace '>"','>'} | %{ $_.Replace("`r`n","`n") } | Out-File -Encoding ascii "$($out_confd)\$($options_file)"
    $keadhcp4.Dhcp4.'option-data' = "<?include `"$($kea_confd)/$($options_file)`"?>"
}
# сохраним каждую подсеть в отдельный файл
# dhcp4.subnet4
if ($split_subnets) {
    [Collections.ArrayList]$dhcp4_subnet4 = @()
    # каждую подсеть в свой файл
    foreach ($subnet in $keadhcp4.Dhcp4.Subnet4) {
        $subnet_file = "subnet4.$(($subnet.subnet -split '/')[0]).conf.json"
        ConvertTo-Json -InputObject $subnet -Depth 10 | ForEach-Object { [regex]::Unescape($_) } | Foreach-Object {$_ -replace '"<','<'} | Foreach-Object {$_ -replace '>"','>'} | %{ $_.Replace("`r`n","`n") } | Out-File -Encoding ascii "$($out_confd)\$($subnet_file)"
        $dhcp4_subnet4.add("<?include `"$($kea_confd)/$($subnet_file)`"?>") | Out-Null
    }
    $keadhcp4.Dhcp4.Subnet4 = $dhcp4_subnet4
}

# записываем конфиг в файл
ConvertTo-Json -InputObject $keadhcp4 -Depth 10 | ForEach-Object { [regex]::Unescape($_) } | Foreach-Object {$_ -replace '"<','<'} | Foreach-Object {$_ -replace '>"','>'} | %{ $_.Replace("`r`n","`n") } | Out-File -Encoding ascii $out_dhcp4_conf
