#!/bin/sh
virtctl stop -n demo-client client
virtctl stop -n demo-nfs nfs
virtctl stop -n demo-ldap ldap

oc delete -k client/base
oc delete -k nfs/base
oc delete -k ldap/base
