# Convert-WindowsDHCPToKea
Convert windows dhcp backup xml to kea-dhcp.conf
Пример использования

```bash
powershell Convert-WindowsDHCPToKea.ps1 \
    -in_xml "/var/tmp/win_dhcp.xml" \
    -in_template "/etc/kea/kea-dhcp4.conf" \
    -out_confdir "/etc/kea" \
    -split "all" \
    -out_dhcp4_conf "/etc/kea/kea-dhcp4.conf.json" \
    -out_confd "/etc/kea/conf.d"
```
