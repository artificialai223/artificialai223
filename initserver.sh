#!/bin/bash

read -p '● Hostname: ' hstnm

sudo hostnamectl set-hostname hstnm
clear
echo "● Installing swap space"

# size of swapfile in megabytes
swapsize=4096

# does the swap file already exist?
grep -q "swapfile" /etc/fstab

# if not then create it
if [ $? -ne 0 ]; then
    clear
	echo '● Swapfile not found, Adding swapfile.'
	fallocate -l ${swapsize}M /swapfile
	chmod 600 /swapfile
	mkswap /swapfile
	swapon /swapfile
	echo '/swapfile none swap defaults 0 0' >> /etc/fstab
else
    clear
	echo '● Swapfile found, No changes made.'
fi
echo "● Swap space installed"
read -p "● Install portainer agent? (y/n) " answer
clear
case ${answer:0:1} in
    y|Y )
        echo "● Installing docker..."
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
        clear
        echo "● Docker installed"
        echo "● Installing portainer agent..."
        
        docker run -d -p 9001:9001 --name portainer_agent --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes portainer/agent:2.11.1
        clear
        echo "● Portainer agent installed."
        echo "● Use the server IP with the port 9001 to connect to this agent."
    ;;
esac


# IPTables
sudo iptables -P INPUT ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -F

iptables --flush

sudo /sbin/iptables-save > /etc/iptables/rules.v4

clear

echo "● IPTables records cleared"

