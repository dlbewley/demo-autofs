# Configure an OpenShift node to use automount

MachineConfig sets up sssd with LDAP knowledge and a daemonset runs automountd on the selected nodes.

## Configure and Enable sssd on OpenShift Nodes Using MCO

The sssda service is already installed and enabled on nodes, does not start until a sssd.conf exists.

* Enable sssd

> [!IMPORTANT]
> Use [machineconfig.bu](machineconfig.bu) to generate the [machineconfig.yaml](machineconfig.yaml). The [sssd.conf](scripts/sssd.conf) file will be included by the butane file.
> `butane -d scripts < machineconfig.bu > machineconfig.yaml`

```bash
$ oc create -f machineconfig.yaml
```

* Wait for worker pool to update and reboot
* Confirm sssd is running after MCO reboot

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

* Confirm sssd is consulted by getent and results are returned from LDAP

```bash
# unmodified defaults
[root@worker-4 ~]# grep -E '^(passwd|shadow|group|automount)' /etc/nsswitch.conf
passwd:     files sss systemd altfiles
group:      files sss systemd altfiles
automount:  sss files
shadow:     files

[root@worker-4 ~]# getent passwd dale
dale:*:1001:1001:Dale:/home/dale:/bin/bash
```

```bash
[root@worker-4 ~]# cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
core:x:1000:1000:CoreOS Admin:/var/home/core:/bin/bash
```


# Autofs Image Building

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

These had to be added even though in the host OS:




* Copy $PULL_SECRET to ~/.config/containers/auth.json

* Build the [automount container](Containerfile)

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

```
[root@client etc]# automount --help
Usage: automount [options] [master_map_name]
        -h --help       this text
        -p --pid-file f write process id to file f
        -t --timeout n  auto-unmount in n seconds (0-disable)
        -M --master-wait n
                        maximum wait time (seconds) for master
                        map to become available
        -v --verbose    be verbose
        -d --debug      log debuging info
        -Dvariable=value, --define variable=value
                        define global macro variable
        -S --systemd-service
                        run automounter as a systemd service
        -f --foreground do not fork into background
        -r --random-multimount-selection
                        use random replicated server selection
        -m --dumpmaps [<map type> <map name>]
                        dump automounter maps and exit
        -n --negative-timeout n
                        set the timeout for failed key lookups.
        -O --global-options
                        specify global mount options
        -l --set-log-priority priority path [path,...]
                        set daemon log verbosity
        -C --dont-check-daemon
                        don't check if daemon is already running
        -F --force      forceably clean up known automounts at start
        -U --force-exit forceably clean up known automounts and exit
        -V --version    print version, build config and exit
```

# Deploy

Deploy the [automount daemonset](daemonset.yaml) with a Node Selector (`demo: automount`) runs automount:

`oc label node worker-5 demo=automount`

# Testing

Work towards automounting of home dirs.

## Host Test Plan

**Test 1 - getent passwd via LDAP**

* ✅ `getent passwd dale`

## Automount Pod Test Plan 

**Test 2 - getent passwd via LDAP**

* ✅ `getent passwd dale` 

* Required fixes so far:
   * Mount /var/lib/sss into pod
   * Adding `sssd-client` rpm provided the missing `/lib64/libnss_sss.so2` (this is already on the host)

> [!NOTE]
> It may be possible to obviate the redundant sssd-client rpm in the container by mounting the hostPath /usr/lib64/libnss_sss.so.2

**Test 3.1 - automount /home/dale in automount pod and automount=sss**


* ❌ `ls /home/dale`

Does not work with default auto.master, which should check LDAP.

**Test 3.2 - automount /home/dale in automount pod and automount=files**

* ✅ `ls /home/dale`

Does work with auto.master  pointing to auto.home with static mapping to home dirs.

_/etc/auto.master.d/extra.autofs_
```
/home /etc/auto.home
```

_/etc/auto.home_
```
* -rw,soft,intr nfs.lab.bewley.net:/exports/home/&
```

Required installation of nfs-utils to get `/sbin/mount.nfs` binary in automount pod.


**Test 4 - view /home/dale mount in host os**

* ❌ `ls /home/dale`

> [!IMPORTANT]
> Even though the pod is privileged and the volumemount is bidirection, the mount is not showing up at /var/home nor /home in the host OS.

```
[root@worker-5 sbin]# mount |grep nfs
nfs.lab.bewley.net:/exports/home/dale on /var/lib/kubelet/pods/7db5596b-8538-49f9-81d8-21a530af0b37/volumes/kubernetes.io~nfs/nfs-home-volume type nfs4 (ro,relatime,vers=4.2,rsize=262144,wsize=262144,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=sys,clientaddr=192.168.4.205,local_lock=none,addr=192.168.4.120)
```

**Test 5 - view /home/dale mount in user workload pod**

**Test 6 - access /home/dale mount in user workload pod as UID 1001 GID 1001**


# Potential Pitfalls?

* /home is a symlink to /var/home
* kerberos needed?
