# Configure an OpenShift node to use automount

MachineConfig sets up sssd with LDAP knowledge.

Daemonset with a Node Selector (`demo: automount`) runs automount:

`oc label node worker-5 demo=automount`

> [!NOTE] 
> These RPMs are already installed on a OCP 4.18 node:
>
> - nfs-utils-2.5.4-26.el9_4.1.x86_64
> - openldap-2.6.6-3.el9.x86_64
> - sssd-2.9.4-6.el9_4.3.x86_64
> - sssd-ldap-2.9.4-6.el9_4.3.x86_64

RPMs needed:

- autofs
- openldap-clients

# Image Building

Copy $PULL_SECRET to ~/.config/containers/auth.json

Non root build fails with glibc.so.6 (rhel9)

```bash
$ podman build -t quay.io/dbewley/autofs/automount:v4.18 .
...
STEP 8/9: RUN dnf install         --disablerepo=*         --enablerepo=rhel-9-for-x86_64-baseos-rpms         -y         autofs         openldap-clients         && dnf clean all                                                   /bin/sh: error while loading shared libraries: /lib64/libc.so.6: cannot apply additional memory protection after relocation: Permission denied                                                                                     Error: building at STEP "RUN dnf install         --disablerepo=*         --enablerepo=rhel-9-for-x86_64-baseos-rpms         -y         autofs         openldap-clients         && dnf clean all": while running runtime: exit statu
s 127
```

Should use `buildah unshare; buildah bud` but going to use sudo instead.
Copy $PULL_SECRET to /root/.config/containers/auth.json

```bash
$ sudo podman build -t quay.io/dbewley/autofs:v4.18 .
```

Podman login to repository

```bash
$ sudo podman login -u dbewley quay.io/dbewley/autofs
$ sudo podman push quay.io/dbewley/autofs:v4.18
```

# Deploy

## Enable sssd

sssd is installed and enabled but does not start until a sssd.conf exists.

* Enable sssd

```bash
oc create -f machineconfig.yaml
```

* Confirm after MCO reboot

```bash
[core@worker-4 ~]$ sudo -i
[root@worker-4 ~]# systemctl status sssd
● sssd.service - System Security Services Daemon
     Loaded: loaded (/usr/lib/systemd/system/sssd.service; enabled; preset: enabled)
     Active: active (running) since Sun 2025-05-11 16:35:37 UTC; 1min 43s ago
   Main PID: 1264 (sssd)
      Tasks: 5 (limit: 307510)
     Memory: 50.8M
        CPU: 508ms
     CGroup: /system.slice/sssd.service
             ├─1264 /usr/sbin/sssd -i --logger=files
             ├─1332 /usr/libexec/sssd/sssd_be --domain LDAP --uid 0 --gid 0 --logger=files
             ├─1340 /usr/libexec/sssd/sssd_nss --uid 0 --gid 0 --logger=files
             ├─1341 /usr/libexec/sssd/sssd_pam --uid 0 --gid 0 --logger=files
             └─1342 /usr/libexec/sssd/sssd_autofs --uid 0 --gid 0 --logger=files

May 11 16:35:37 worker-4 systemd[1]: Starting System Security Services Daemon...
May 11 16:35:37 worker-4 sssd[1264]: Starting up
May 11 16:35:37 worker-4 sssd_be[1332]: Starting up
May 11 16:35:37 worker-4 sssd_nss[1340]: Starting up
May 11 16:35:37 worker-4 sssd_autofs[1342]: Starting up
May 11 16:35:37 worker-4 sssd_pam[1341]: Starting up
May 11 16:35:37 worker-4 systemd[1]: Started System Security Services Daemon.
May 11 16:35:38 worker-4 sssd_be[1332]: Backend is offline
May 11 16:35:40 worker-4 sssd_be[1332]: Backend is online
```

* Confirm sssd is consulted by getent

```bash
[root@worker-4 ~]# getent passwd dale
dale:*:1001:1001:Dale:/home/dale:/bin/bash
```

```bash
[root@worker-4 ~]# cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
core:x:1000:1000:CoreOS Admin:/var/home/core:/bin/bash

[root@worker-4 ~]# grep -E '^(passwd|shadow|group|automount)' /etc/nsswitch.conf
passwd:     files sss systemd altfiles
group:      files sss systemd altfiles
automount:  sss files
shadow:     files
```

# Watch out fors

* /home is a symlink to /var/home
