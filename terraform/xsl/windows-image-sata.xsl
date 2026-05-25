<?xml version="1.0" encoding="UTF-8"?>
<!--
  windows-image-sata.xsl

  Packer bygger win-ep1 med SeaBIOS/MBR och IDE-disk för maximal
  installationsstabilitet. dmacvicar/libvirt exponerar inte disk-bus direkt
  i disk-blocket och väljer virtio som default, vilket ger
  INACCESSIBLE_BOOT_DEVICE på den här imagen.

  För Packer-kloner byter vi därför den enda bootdisken till SATA. Det ligger
  nära Packer-byggets IDE/AHCI-profil och kräver ingen bootkritisk virtio-
  storage-driver vid första start.
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>

  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="devices/disk[@device='disk'][1]/target">
    <target dev="sda" bus="sata"/>
  </xsl:template>

  <xsl:template match="devices/disk[@device='disk'][1]/address"/>
</xsl:stylesheet>
