# hostpath volume

Now that the OpenShift node is running autofs thanks to a [layered image](../layering), we can mount a hostpath volume into a pod.

This deployment runs as UID/GUID 1001 and mounts the hostpath `/home/dale` at `/data`.

```
oc apply -k hostpath-volume
```

Lo

```bash
oc rsh -n demo-hostpath-volume demo-hostpath-volume-59c5bb5ccd-gjdps
~ $ cd /data
/data $ ls -al
total 16
drwx------    3 1001     1001            95 May 24 18:47 .
dr-xr-xr-x    1 root     root            40 May 28 04:35 ..
-rw-------    1 1001     1001           552 May 25 09:29 .bash_history
-rw-r--r--    1 1001     1001            18 Feb 15  2024 .bash_logout
-rw-r--r--    1 1001     1001           141 Feb 15  2024 .bash_profile
-rw-r--r--    1 1001     1001           492 Feb 15  2024 .bashrc
drwx------    2 1001     1001            48 May 24 18:48 .ssh
/data $ id
uid=1001(1001) gid=1001(1001) groups=1001(1001)
/data $ touch foo
/data $ ls -al
total 16
drwx------    3 1001     1001           106 May 28 04:37 .
dr-xr-xr-x    1 root     root            40 May 28 04:35 ..
-rw-------    1 1001     1001           552 May 25 09:29 .bash_history
-rw-r--r--    1 1001     1001            18 Feb 15  2024 .bash_logout
-rw-r--r--    1 1001     1001           141 Feb 15  2024 .bash_profile
-rw-r--r--    1 1001     1001           492 Feb 15  2024 .bashrc
drwx------    2 1001     1001            48 May 24 18:48 .ssh
-rw-r--r--    1 1001     1001             0 May 28 04:37 foo
/data $
/data $ df -h /data
Filesystem                Size      Used Available Use% Mounted on
nfs:/exports/home/dale
                         28.7G      1.9G     26.8G   7% /data
```