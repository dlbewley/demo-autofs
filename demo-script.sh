#!/bin/bash

# git clone https://github.com/paxtonhare/demo-magic.git
source ~/src/demos/demo-magic/demo-magic.sh
TYPE_SPEED=100
PROMPT_TIMEOUT=2
#DEMO_PROMPT="${CYAN}\W${GREEN}➜ ${COLOR_RESET}"
DEMO_PROMPT="${CYAN}\W ${GREEN}$ ${COLOR_RESET}"
DEMO_COMMENT_COLOR=$GREEN
GIT_ROOT=$(git rev-parse --show-toplevel)
DEMO_ROOT=$GIT_ROOT

# https://archive.zhimingwang.org/blog/2015-09-21-zsh-51-and-bracketed-paste.html
#unset zle_bracketed_paste
clear

p "# all the things"
pei tree -L 3 $DEMO_ROOT
p

p "# 🔧 build ldap server 🗄️"
pei "oc apply -k $DEMO_ROOT/ldap/base"
pei "virtctl start ldap -n demo-ldap"
p

p "# 🔧 build nfs server 📂"
pei "oc apply -k $DEMO_ROOT/nfs/base"
pei "virtctl start nfs -n demo-nfs"
p


p "# 🔧 build nfs client 🙋‍♀️"
pei "oc apply -k $DEMO_ROOT/client/base"
pei "virtctl start client -n demo-client"
p

p "# ⌛ wait for the VMs to come up..."
sleep 180

p "# 🔍 check status of all the VMs"
pei "oc get vmi -o wide -n demo-ldap"
pei "oc get vmi -o wide -n demo-nfs"
pei "oc get vmi -o wide -n demo-client"
p

p "# 🪏 look up the nfs server IP address"
NFS_IP=$(dig a +short nfs.lab.bewley.net)
pei "dig a +short nfs.lab.bewley.net"
pei "ssh-keygen -R $NFS_IP"
p

p "# 🪏 look up the ldap server IP address"
LDAP_IP=$(dig a +short ldap.lab.bewley.net)
pei "dig a +short ldap.lab.bewley.net"
pei "ssh-keygen -R $LDAP_IP"
p

p "# 🪏 look up the client VM IP address"
CLIENT_IP=$(dig a +short client.lab.bewley.net)
pei "dig a +short client.lab.bewley.net"
pei "ssh-keygen -R $CLIENT_IP"
p

p "# 💻 login to the client VM and take a look at the network interfaces"
pei "ssh cloud-user@client.lab.bewley.net"
p

p "# 🎉 SUCCESS!"
 
DEMO_COMMENT_COLOR=$BLUE
p "# 🚿 time to clean up"
DEMO_COMMENT_COLOR=$GREEN
