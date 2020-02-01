# AWS Create VPC Script
# Author:  Nicholas Moore (nicholasvmoore@gmail.com)
# Author:  John Fogarty (johnafogarty4@gmail.com)

# Quick Cleanup  rv * -ea SilentlyContinue; rmo *; $error.Clear(); cls

$Global:newVpcJson = "./vpc-layout.json"
$Global:newVpc = Get-Content -Raw -Path $Global:newVpcJson | ConvertFrom-Json

# Prompt user for MFA & create credential via Use-STSRole

if($Global:newVpc.accountId){
  $roleArn = "arn:aws:iam::" + $newVpc.accountId + ":role/Admin"
  $Global:Creds = (Use-STSRole -RoleArn $roleArn -RoleSessionName "CreateVPC" -Region $Global:newVpc.region -DurationInSeconds 3600).Credentials
}

# Creating VPCs
If ( $Global:newVpc.name -and $Global:Creds ) {
  
  # Create a VPC & add a key with the naming prefix + id and add the resulting vpcId as the value to the new key.
  #$Global:vpc = Get-EC2Vpc -VpcId vpc-01c198a245ecb8cde -ProfileName aws -Region $Global:newVpc.region
  $Global:vpc = New-EC2Vpc -CidrBlock $Global:newVpc.vpc.cidr -ProfileName aws -Region $Global:newVpc.region 
  While ($(Get-Ec2Vpc -VpcId $Global:vpc.VpcId -ProfileName aws -Region $Global:newVpc.region).State -eq "pending"){
    Start-Sleep -m 100
  }
  New-Ec2Tag -Resource $vpc.VpcId -Tag @{ key="Name"; value=$Global:newVpc.name } -ProfileName aws -Region $Global:newVpc.region

  # Create a filter to grab only objects from the newly created VPC
  $Global:vpcIdFilter = New-Object Amazon.EC2.Model.Filter -Property @{Name = "vpc-id"; Value = $vpc.VpcId}
  $Global:vpcNetworkAcls = @()
  $Global:vpcNetworkAcls += Get-EC2NetworkAcl -Filter $vpcIdFilter -ProfileName aws -Region $Global:newVpc.region

  # Enable DNS Support & Hostnames in VPC
  Edit-EC2VpcAttribute -VpcId $Global:vpc.VpcId -EnableDnsSupport $true -ProfileName aws -Region $Global:newVpc.region
  Edit-EC2VpcAttribute -VpcId $Global:vpc.VpcId -EnableDnsHostnames $true -ProfileName aws -Region $Global:newVpc.region

  # Create new Internet Gateway
  $igw = New-EC2InternetGateway -ProfileName aws -Region $Global:newVpc.region 
  Start-Sleep -m 200
  New-Ec2Tag -Resource $igw.InternetGatewayId -Tag @{ key="Name"; value=$Global:newVpc.name + "-igw" } -ProfileName aws -Region $Global:newVpc.region
  Add-EC2InternetGateway -InternetGatewayId $igw.InternetGatewayId -VpcId $Global:vpc.VpcId -ProfileName aws -Region $Global:newVpc.region
  
  # Peer the VPC with the MGMT Account's VPC
  $Global:vpcPeeringConnection = New-EC2VpcPeeringConnection -VpcId $Global:vpc.VpcId -PeerVpcId $Global:newVpc.management.vpcId -PeerOwnerId $Global:newVpc.management.accountId -ProfileName aws -Region $Global:newVpc.region 
  $Global:vpcPeeringConnection = Get-EC2VpcPeeringConnections -VpcPeeringConnectionId pcx-06c68fb2127274c81 -ProfileName aws -Region $Global:newVpc.region 
  Start-Sleep -m 100
  New-Ec2Tag -Resource $vpcPeeringConnection.VpcPeeringConnectionId -Tag @{ key="Name"; value=$Global:newVpcName + "-pcx" } -ProfileName aws -Region $Global:newVpc.region
  
  # Ceate a new DHCP Option Set for the newly created VPC
  If ( $Global:newVpc.vpc.dhcpDomain -and $Global:newVpc.vpc.dns1 -and $Global:newVpc.vpc.dns2 ) {
    $awsDhcpOptions = @(
      @{Key="domain-name"; Values=@($Global:newVpc.vpc.dhcpDomain)},
      @{Key="domain-name-servers"; Values=@($Global:newVpc.vpc.dns1,$Global:newVpc.vpc.dns2)}
      )
    $awsDhcpOption = New-EC2DhcpOption -DhcpConfiguration $awsDhcpOptions -ProfileName aws -Region $Global:newVpc.region
    New-Ec2Tag -Resource $awsDhcpOption.DhcpOptionsId -Tag @{ key="Name"; value=$Global:newVpc.name + "-dhcpOption" } -ProfileName aws -Region $Global:newVpc.region

    # Assign the newly created VPC this DhcpOption
    Register-EC2DhcpOption -VpcId $Global:vpc.VpcId -DhcpOptionsId $awsDhcpOption.DhcpOptionsId -PassThru -ProfileName aws -Region $Global:newVpc.region
  }
  Else {
      Write-Output "Cannot set DHCP options, there were none provided in the JSON"
  }

  # Create the Subnets for the current VPC within their respective AZs and Add them to the appropriate Route Table
  $count = 0
  ForEach ( $subnet in $Global:newVpc.vpc.subnets ) {
    $fullAzName = $Global:newVpc.region + $subnet.az.Substring($subnet.az.get_Length()-1)
    $subnetId = New-EC2Subnet -AvailabilityZone $fullAzName -CidrBlock $subnet.cidr -VpcId $Global:vpc.VpcId -ProfileName aws -Region $Global:newVpc.region 
    $Global:newVpc.vpc.subnets[$count] | Add-Member -NotePropertyName subnetId -NotePropertyValue $subnetId.SubnetId -Force
    New-EC2Tag -Resource $subnetId.SubnetId -Tag @{ key="Name"; value=$subnet.name } -ProfileName aws -Region $Global:newVpc.region
    $count++
  }

  # Count the number of AZs and create 1 extra Route Table
  $count = ($Global:newVpc.vpc.availabilityZones | Measure-Object).Count
  $rtNeeded = $count + 1
  $index = 0
  $Global:routeTables = @()
  While ($rtNeeded -gt 0) {
    If ($rtNeeded -gt $count){
      $Global:routeTables += New-EC2RouteTable -VpcId $Global:vpc.VpcId -ProfileName aws -Region $Global:newVpc.region
      $Global:routeTables[$index] | Add-Member -NotePropertyName external -NotePropertyValue $true -Force
      $rtNeeded--
      $index++
    }
    Else{
      ForEach ($az in $Global:newVpc.vpc.availabilityZones) {
        $Global:routeTables += New-EC2RouteTable -VpcId $Global:vpc.VpcId -ProfileName aws -Region $Global:newVpc.region
        $Global:routeTables[$index] | Add-Member -NotePropertyName external -NotePropertyValue $false -Force
        $Global:routeTables[$index] | Add-Member -NotePropertyName az -NotePropertyValue $az -Force
        $rtNeeded--
        $index++
      }
    }
  }
  
  ForEach ($routeTable in $Global:routeTables) {
    If ($routeTable.external -eq $true) {
      $s3ServiceName = "com.amazonaws." + $Global:newVpc.region + ".s3"
      New-EC2Tag -Resource $routeTable.RouteTableId -Tag @{ key="Name"; value="external_routeTable" } -ProfileName aws -Region $Global:newVpc.region
      New-EC2Route -RouteTableId $routeTable.RouteTableId -DestinationCidrBlock $Global:newVpc.management.vpcCidr -VpcPeeringConnectionId $Global:vpcPeeringConnection.VpcPeeringConnectionId -ProfileName aws -Region $Global:newVpc.region
      New-EC2Route -RouteTableId $routeTable.RouteTableId -GatewayId $igw.InternetGatewayId -DestinationCidrBlock "0.0.0.0/0" -ProfileName aws -Region $Global:newVpc.region
      # Create the VPC Endpoint for S3 access
      $Global:vpcEndpoint = New-EC2VpcEndpoint -VpcId $Global:vpc.VpcId -RouteTableId $routeTable.RouteTableId -ServiceName $s3ServiceName -ProfileName aws -Region $Global:newVpc.region
      ForEach ($subnet in $Global:newVpc.vpc.subnets) {
        If ( $subnet.external -eq $True) {
          Register-EC2RouteTable -RouteTableId $Global:routeTables[0].RouteTableId -SubnetId $subnet.SubnetId -Force -ProfileName aws -Region $Global:newVpc.region
        }
      }
    }
  }

  $count = 0
  ForEach ($routeTable in $Global:routeTables) {
    If ($routeTable.external -eq $false) {
      ForEach ($az in $Global:newVpc.vpc.availabilityZones ) {
        If ($az -eq $routeTable.az) {
          ForEach ($subnet in $Global:newVpc.vpc.subnets) {
            If ( $subnet.az -eq $routeTable.az -and $subnet.external -eq $False ) {
              Register-EC2RouteTable -RouteTableId $routeTable.RouteTableId -SubnetId $subnet.SubnetId -Force -ProfileName aws -Region $Global:newVpc.region
            }
          }
        }
      }
    }
    $count++
  }

  ForEach ($az in $Global:newVpc.vpc.availabilityZones) {
    ForEach ($routeTable in $Global:routeTables) {
      If ($az -eq $routeTable.az) {
        $rtAzTag = $az + "_internal_routeTable"
        New-EC2Tag -Resource $routeTable.RouteTableId -Tag @{ key="Name"; value=$rtAzTag } -ProfileName aws -Region $Global:newVpc.region
      }
    }
  }
  
  $Global:natGateways = @()
  $count = 0
  ForEach ($subnet in $Global:newVpc.vpc.subnets) {
    If ($subnet.external -eq $True) {
      $natGatewayEIP = New-EC2Address -Domain 'vpc' -ProfileName aws -Region $Global:newVpc.region
      $Global:natGateways += New-EC2NatGateway -SubnetId $subnet.subnetId -AllocationId $natGatewayEIP.AllocationId -ProfileName aws -Region $Global:newVpc.region
      Start-Sleep -S 2
      $Global:natGateways[$count].NatGateway | Add-Member -NotePropertyName az -NotePropertyValue $subnet.az -Force
      New-EC2Tag -Resource $Global:natGateways[$count].NatGateway.NatGatewayId -Tag @{ key="az"; value=$subnet.az } -ProfileName aws -Region $Global:newVpc.region
      New-EC2Tag -Resource $Global:natGateways[$count].NatGateway.NatGatewayId -Tag @{ key="subnet"; value=$subnet.subnetId } -ProfileName aws -Region $Global:newVpc.region
      $count++
    }
  }

  ForEach ($routeTable in $Global:routeTables) {
    If ($routeTable.external -eq $False) {
      ForEach ($natGateway in $Global:natGateways) {
        If ($natGateway.NatGateway.az -eq $routeTable.az) {
          Start-Sleep -S 2
          New-EC2Route -RouteTableId $routeTable.RouteTableId -DestinationCidrBlock "0.0.0.0/0" -NatGatewayId $natGateway.NatGateway.NatGatewayId -ProfileName aws -Region $Global:newVpc.region
          New-EC2Route -RouteTableId $routeTable.RouteTableId -DestinationCidrBlock $Global:newVpc.management.vpcCidr -VpcPeeringConnectionId $Global:vpcPeeringConnection.VpcPeeringConnectionId -ProfileName aws -Region $Global:newVpc.region
        }
      }
    }
  }

}
  
# Head over to the Management Account &  Approve the VPC Peering Request & set some moar variables
If ( $vpcPeeringConnection.VpcPeeringConnectionId ) {
  $awsMgmtVpcRouteTableFilter = New-Object Amazon.EC2.Model.Filter -Property @{ Name = "vpc-id"; Values = $Global:newVpc.management.vpcId }
  $awsMgmtVpcRouteTableIds = Get-EC2RouteTable -Filter $awsMgmtVpcRouteTableFilter -Region $Global:newVpc.region
  Approve-EC2VpcPeeringConnection -VpcPeeringConnectionId $Global:vpcPeeringConnection.VpcPeeringConnectionId -Region $Global:newVpc.region
  
  # Tag the VPC Peering Connection in the Mgmt accounts
  New-Ec2Tag -Resource $Global:vpcPeeringConnection.VpcPeeringConnectionId -Tag @{ key="Name"; value=$Global:newVpc.awsProfileName + '-pcx' } -Region $Global:newVpc.region

  ForEach ( $mgmtRouteTable in $awsMgmtVpcRouteTableIds ) {
    # Add a route to the New VPC in all Management Account Route Tables
    New-EC2Route -RouteTableId $mgmtRouteTable.RouteTableId -DestinationCidrBlock $Global:newVpc.vpc.cidr -VpcPeeringConnectionId $Global:vpcPeeringConnection.VpcPeeringConnectionId -Region $Global:newVpc.region
  }
}
