<?xml version="1.0" encoding="UTF-8"?>
<!--
  cdrom.xsl — XSLT-transform som körs på libvirt-providerns genererade
  domän-XML innan domänen definieras.

  Lägger till <readonly/> och <shareable/> på varje disk vars volume-namn
  slutar på .iso. <shareable/> krävs för att libvirt/sVirt ska tillåta att
  samma ISO (t.ex. virtio-win.iso) attachas till flera domäner samtidigt
  utan SELinux-label-konflikt. <readonly/> skyddar från oavsiktlig write.

  Notera: vi byter INTE device="disk"→"cdrom" eller bus="virtio"→"sata".
  dmacvicar/libvirt 0.8 har en känd panic-bug om dessa attribut ändras
  via XSLT (nil pointer dereference vid parse-back). Windows Setup kan
  läsa install-ISOn som virtio-disk utan problem.
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>

  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="disk[contains(source/@file, '.iso') or contains(source/@volume, '.iso')]">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
      <readonly/>
      <shareable/>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
