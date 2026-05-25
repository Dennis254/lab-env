<?xml version="1.0" encoding="utf-8"?>
<!--
  autounattend.xml — Aegis detection-lab unattended Windows install
  ===========================================================================
  Genereras per VM av Terraform (templatefile) och packas till en ISO som
  attachas som CDROM vid första boot. Windows-installern hittar
  autounattend.xml automatiskt på alla anslutna CD-enheter.

  Mall-variabler (fylls i av Terraform):
    hostname        — datornamn, max 15 tecken
    edition         — WIM image-namn, t.ex. "Windows 11 Enterprise"
    admin_password  — lokalt admin-lösenord (klartext; lab-användning)
    mgmt_mac        — MAC-adress för mgmt-NIC (matchas i FirstLogonCommands)
    mgmt_ip         — statisk IPv4 för mgmt
    mgmt_prefix     — prefixlängd, t.ex. 24
    mgmt_gateway    — default gateway på mgmt
    mgmt_dns        — DNS-server på mgmt

  Designval (minimal scope):
    - SATA för alla diskar/CDROMer. Slipper viostor/vioscsi i WinPE.
    - virtio-NIC (NetKVM) injektas i specialize-fasen via PnpCustomizationsNonWinPE.
    - Boot från första disken (DiskID 0), GPT/UEFI-partitionering.
    - OOBE skippas helt; auto-login som Administrator för FirstLogonCommands.
    - WinRM aktiveras (HTTP, NTLM/Basic) — räcker för att från värden köra
      promote-dc.ps1 / join-domain.ps1 över Enter-PSSession.
  ===========================================================================
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <!-- ================================================================== -->
  <!-- Pass 1: windowsPE — installern bootar, partitionerar, applicerar    -->
  <!-- ================================================================== -->
  <settings pass="windowsPE">

    <!-- Ladda viostor-drivern så WinPE ser virtio-boot-disken. Skannar    -->
    <!-- D:/E:/F: rekursivt — täcker alla möjliga drivletter-tilldelningar  -->
    <!-- för virtio-win-ISOn. Långsamt men robust.                         -->
    <component name="Microsoft-Windows-PnpCustomizationsWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:keyValue="1" wcm:action="add"><Path>D:\</Path></PathAndCredentials>
        <PathAndCredentials wcm:keyValue="2" wcm:action="add"><Path>E:\</Path></PathAndCredentials>
        <PathAndCredentials wcm:keyValue="3" wcm:action="add"><Path>F:\</Path></PathAndCredentials>
      </DriverPaths>
    </component>

    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">

      <!-- Disk 0 wipas och delas i 3 partitioner: EFI (260MB), MSR (16MB), C: (resten) -->
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>260</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>${edition}</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>

      <UserData>
        <ProductKey>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>Aegis Lab</FullName>
        <Organization>Aegis Lab</Organization>
      </UserData>
    </component>
  </settings>

  <!-- ================================================================== -->
  <!-- Pass 4: specialize — kör efter sysprep, innan första logon         -->
  <!-- ================================================================== -->
  <settings pass="specialize">

    <!-- Injecta virtio NetKVM-drivern så mgmt-NIC syns vid FirstLogon.    -->
    <!-- Sökvägarna skannas rekursivt; Windows hittar rätt .inf själv.    -->
    <component name="Microsoft-Windows-PnpCustomizationsNonWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:keyValue="1" wcm:action="add"><Path>D:\</Path></PathAndCredentials>
        <PathAndCredentials wcm:keyValue="2" wcm:action="add"><Path>E:\</Path></PathAndCredentials>
        <PathAndCredentials wcm:keyValue="3" wcm:action="add"><Path>F:\</Path></PathAndCredentials>
      </DriverPaths>
    </component>

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <ComputerName>${hostname}</ComputerName>
      <TimeZone>W. Europe Standard Time</TimeZone>
    </component>
  </settings>

  <!-- ================================================================== -->
  <!-- Pass 7: oobeSystem — sista fasen, OOBE-bypass och FirstLogon        -->
  <!-- ================================================================== -->
  <settings pass="oobeSystem">

    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">

      <!-- Hoppar över hela OOBE-trollkarlen. -->
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <UserAccounts>
        <AdministratorPassword>
          <Value>${admin_password}</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>

      <!-- Logga in en gång automatiskt så FirstLogonCommands hinner köra. -->
      <AutoLogon>
        <Password>
          <Value>${admin_password}</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>

      <!--
        Sätter statisk IP på mgmt-NIC (matchad via MAC, så det fungerar
        oavsett om Windows kallar den 'Ethernet' eller 'Ethernet 2') och
        aktiverar WinRM över HTTP. Detonation-NIC lämnas på DHCP (libvirt
        har DHCP på lab-detonation och VM:n får då en 10.30.0.x-adress).
      -->
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Static IP on mgmt NIC</Description>
          <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -Command "$m='${mgmt_mac}'.Replace(':','-').ToUpper(); $a=Get-NetAdapter | Where-Object MacAddress -eq $m; Rename-NetAdapter -Name $a.Name -NewName 'mgmt'; New-NetIPAddress -InterfaceAlias 'mgmt' -IPAddress ${mgmt_ip} -PrefixLength ${mgmt_prefix} -DefaultGateway ${mgmt_gateway}; Set-DnsClientServerAddress -InterfaceAlias 'mgmt' -ServerAddresses ${mgmt_dns}"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Enable WinRM</Description>
          <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck; Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -RemoteAddress Any -ErrorAction SilentlyContinue; Set-Item WSMan:\localhost\Service\Auth\Basic $true; Set-Item WSMan:\localhost\Service\AllowUnencrypted $true"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Disable AutoLogon after first run</Description>
          <CommandLine>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
