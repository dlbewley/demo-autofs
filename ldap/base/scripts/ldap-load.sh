#!/bin/bash

echo "(core.ldif) Adding OpenLDAP core schemas"

ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/core.ldif

echo "(cosine.ldif) Adding OpenLDAP cosine schema"
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/cosine.ldif

echo "(nis.ldif) Adding OpenLDAP nis schema"
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/nis.ldif

echo "(inetorgperson.ldif) Adding OpenLDAP inetorgperson schema"
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/inetorgperson.ldif

echo "(autofs.ldif) Adding OpenLDAP autofs schema"
ldapadd -Y EXTERNAL -H ldapi:/// -f /opt/autofs.ldif

echo "(modify-suffix.ldif) Updating OpenLDAP suffix to lab.bewley.net"
ldapadd -Y EXTERNAL -H ldapi:/// -f /opt/modify-suffix.ldif

echo "(set-rootdn.ldif) Creating admin root dn with password"
ldapadd -Y EXTERNAL -H ldapi:/// -f /opt/set-rootdn.ldif

echo "(base.ldif) Creating base.ldif with cn=admin,dc=lab,dc=bewley,dc=net as root dn"
ldapadd -x -D "cn=admin,dc=lab,dc=bewley,dc=net" -w ldap -H ldap:/// -f /opt/base.ldif

echo "(automount.ldif) Creating automount maps and entries"
ldapadd -x -D "cn=admin,dc=lab,dc=bewley,dc=net" -w ldap -H ldap:/// -f /opt/automount.ldif

echo "(users.ldif) Creating users"
ldapadd -x -D "cn=admin,dc=lab,dc=bewley,dc=net" -w ldap -H ldap:/// -f /opt/users.ldif

    